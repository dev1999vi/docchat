# DocChat — How Everything Works (Deep Dive)

This document explains DocChat from top to bottom: the concepts, the architecture,
and a line-by-line-ish walk through what happens on every request. It's written so
that you can read it once and be able to confidently explain the whole system in an
interview.

If you only remember one sentence: **DocChat finds the passages in your PDF that are
most relevant to your question, hands them to an LLM as context, and streams back an
answer that cites those passages.** That's RAG.

---

## Part 1 — The concepts (read this first)

### What problem does this solve?

A large language model (LLM) like Gemini or GPT only knows what it was trained on. It
has never seen your private PDF. If you ask it a question about that PDF, one of two
things happens:

1. It says "I don't know," or
2. It makes something up that sounds plausible (a "hallucination").

**Retrieval-Augmented Generation (RAG)** fixes this. Instead of asking the model to
answer from memory, we:

1. Find the parts of *your* document that are relevant to the question.
2. Put those parts into the prompt as "context."
3. Ask the model to answer using only that context.

The answer is now grounded in real source material, and because we know exactly which
passages we used, we can show citations.

### What is an embedding?

An **embedding** is a list of numbers (a vector) that represents the *meaning* of a
piece of text. For example, "the sun is hot" and "our star has a high temperature"
would produce vectors that are close together, even though they share almost no words.

DocChat uses a Gemini embedding model that outputs a vector of **1536 numbers** for any
piece of text. Similar meanings → nearby vectors.

### What is vector similarity search?

Once every chunk of your document is stored as a vector, answering a question becomes a
geometry problem:

1. Turn the question into a vector too.
2. Find the stored chunk vectors that are "closest" to the question vector.

"Closest" here means **cosine distance** — it compares the *direction* of two vectors,
not their length. Two vectors pointing the same way (similar meaning) have a small
cosine distance. This is done inside PostgreSQL by the **pgvector** extension, sped up
by an **HNSW index** (a data structure for fast approximate nearest-neighbor search).

### Why these specific tools?

| Tool | Job | Why |
|---|---|---|
| Rails (API mode) | Backend orchestration | Fast to build, great for APIs, familiar |
| PostgreSQL + pgvector | Store chunks + vectors, do similarity search | One database for both regular data and vectors |
| Gemini | Embeddings + chat answers | Free tier available; strong models |
| Sidekiq + Redis | Process PDFs in the background | Uploads return instantly instead of blocking |
| React + Vite | The UI | Standard SPA tooling |
| Server-Sent Events | Stream the answer live | Simple one-way server→client streaming, perfect for tokens |

---

## Part 2 — The big picture

There are two independent flows. Understanding that they are *separate* is key.

```
┌─────────────────────────── FLOW A: INGESTION (happens once per upload) ──────────────────────────┐
│                                                                                                   │
│  Browser        Rails API              Sidekiq worker                        PostgreSQL           │
│    │  upload PDF    │                        │                                    │               │
│    │───────────────▶│  create Document(pending)                                   │               │
│    │                │  save file to tmp                                           │               │
│    │                │  enqueue job ─────────▶│                                     │               │
│    │◀───────────────│  return immediately    │                                     │               │
│    │  (202-ish)     │                        │ extract text (PdfExtractor)         │               │
│    │                │                        │ chunk it   (TextChunker)            │               │
│    │                │                        │ embed each chunk (Gemini) ──┐       │               │
│    │                │                        │◀────────────────────────────┘       │               │
│    │                │                        │ insert chunks + vectors ───────────▶│               │
│    │                │                        │ mark Document(processed)            │               │
│    │  poll status   │                        │                                     │               │
│    │───────────────▶│  read status ──────────────────────────────────────────────▶│               │
└───────────────────────────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────── FLOW B: QUERY (happens on every question) ────────────────────────────┐
│                                                                                                    │
│  Browser        Rails API (SSE)         RagAnswerer                Gemini        PostgreSQL         │
│    │  ask question   │                       │                        │              │             │
│    │────────────────▶│  save user Message    │                        │              │             │
│    │                 │  ─────────────────────▶│ embed question ───────▶│              │             │
│    │                 │                        │◀───────────────────────│              │             │
│    │                 │                        │ similarity search ─────────────────▶ │             │
│    │                 │                        │◀──── top 5 chunks ──────────────────  │             │
│    │                 │                        │ build grounded prompt                 │             │
│    │                 │                        │ stream answer ────────▶│              │             │
│    │◀── token ───────│◀── yield token ────────│◀──── token ────────────│              │             │
│    │◀── token ───────│                        │                                       │             │
│    │◀── citations ───│                        │                                       │             │
│    │◀── done ────────│  save assistant Message│                                       │             │
└────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Part 3 — The data model

Four tables (`app/models/`):

- **Document** — one uploaded PDF. Tracks `status` (`pending` → `processing` →
  `processed`/`failed`), `filename`, and `chunks_count`.
- **DocumentChunk** — one slice of a document plus its `embedding` (a `vector(1536)`
  column). This is the table we search. `belongs_to :document`.
- **Conversation** — a chat session. `has_many :messages`.
- **Message** — one user question or assistant answer. Stores `role`
  (`user`/`assistant`), `content`, and `citations` (JSON).

The important column is `document_chunks.embedding`, typed `vector(1536)`. That type
comes from the pgvector extension, enabled in the first migration
(`enable_extension "vector"`). A second migration adds an **HNSW index** on that column
using `vector_cosine_ops` so similarity search is fast.

---

## Part 4 — Flow A: Ingesting a PDF (step by step)

### Step 1 — Upload hits the controller

`DocumentsController#create`:
- Checks the file is a PDF.
- Creates a `Document` row with `status: "pending"`.
- Writes the uploaded bytes to a temp file under `tmp/uploads/`.
- Calls `DocumentProcessingJob.perform_async(document.id, tmp_path)` — this pushes a
  job onto Redis and returns *immediately*. The user isn't kept waiting.
- Responds with the document JSON (status `pending`).

Why async? Embedding a big PDF can take many seconds and multiple API calls. Doing that
inside the web request would block the browser and risk timeouts. Sidekiq moves it off
the request thread.

### Step 2 — Sidekiq runs the job

`DocumentProcessingJob#perform` (a plain Sidekiq job) opens the temp file and hands it
to `DocumentIngestor`, then deletes the temp file in an `ensure` block.

### Step 3 — The ingestion pipeline

`DocumentIngestor#call` runs four stages and updates status as it goes:

1. `@document.mark_processing!`
2. **Extract** — `PdfExtractor.extract` uses the `pdf-reader` gem to pull text out
   page by page, returning `[{ page_number:, text: }, ...]`.
3. **Chunk** — `TextChunker#call` (see below).
4. **Embed + persist** — `persist_chunks` batches the chunks (100 at a time), calls
   `EmbeddingService.embed_batch` to get their vectors, and bulk-inserts rows with
   `DocumentChunk.insert_all!`.
5. `@document.mark_processed!` — sets status and records `chunks_count`.

If anything raises, `mark_failed!` records the error message on the document and the
exception re-raises so Sidekiq can retry.

### Step 3a — How chunking works (and why overlap matters)

`TextChunker` uses a **sliding window over words**:

- `DEFAULT_CHUNK_SIZE = 200` words per chunk.
- `DEFAULT_OVERLAP = 40` words shared with the previous chunk.

It walks each page's words in steps of `chunk_size - overlap` (200 − 40 = 160). So chunk
1 is words 0–199, chunk 2 is words 160–359, chunk 3 is 320–519, and so on.

**Why overlap?** Imagine a key sentence sits right at the boundary between two chunks.
Without overlap, half the sentence lands in each chunk and neither contains the full
thought — retrieval might miss it. The 40-word overlap ensures boundary-straddling
context appears intact in at least one chunk. The trade-off is slightly more chunks
(and therefore more embeddings) — a deliberate accuracy-vs-cost choice.

Each chunk records its `page_number` (so citations can point to a page) and a global
`position` (its order in the document).

### Step 3b — How embedding works

`EmbeddingService.embed_batch`:
- Wraps the call in `LlmClient.with_retry` (retries on transient errors — Part 6).
- For Gemini: POSTs to the native `batchEmbedContents` endpoint with
  `outputDimensionality: 1536` and `taskType: "RETRIEVAL_DOCUMENT"`, then **normalizes**
  each returned vector to unit length.
- For OpenAI: uses the `dimensions: 1536` parameter.

**Why 1536 and why normalize?** The DB column is fixed at `vector(1536)`. Gemini's model
defaults to 3072 dimensions but supports truncating to 1536 (a technique called
Matryoshka representation) with minimal quality loss. Truncated vectors aren't unit
length, so we normalize them — that keeps cosine distance meaningful and consistent.

---

## Part 5 — Flow B: Answering a question (step by step)

### Step 1 — The frontend opens a stream

In `frontend/src/api.js`, `streamAnswer` does a `fetch` POST to
`/conversations/:id/messages` with the question in the body. Instead of awaiting a JSON
response, it reads `res.body.getReader()` — a stream — and decodes chunks as they
arrive. It splits on the blank line (`\n\n`) that separates SSE events, parses each
`event:`/`data:` block, and dispatches to handlers (`onToken`, `onCitations`, `onDone`,
`onError`).

### Step 2 — The controller streams (SSE)

`MessagesController#create` includes `ActionController::Live`, which lets it hold the
connection open and write to it over time. It:
- Sets `Content-Type: text/event-stream` (this is what makes it SSE).
- Wraps the response stream in `ActionController::Live::SSE`.
- Saves the user's question as a `Message`.
- Creates a `RagAnswerer` and calls `.stream`, writing each yielded token as a `token`
  SSE event.
- After streaming, saves the full answer as an assistant `Message`, then writes a
  `citations` event and a `done` event.
- On `LlmClient::MissingApiKey` or any other error, writes an `error` event instead.
- Always closes the SSE stream in `ensure`.

### Step 3 — RagAnswerer: the heart of RAG

`RagAnswerer#stream` does three things:

**1. Retrieve.** `retrieve_chunks` embeds the question
(`EmbeddingService.embed`) and calls the model scope:

```ruby
DocumentChunk
  .joins(:document)
  .where(documents: { status: "processed" })   # only fully-processed docs
  .where.not(embedding: nil)
  .nearest_neighbors(:embedding, query_embedding, distance: "cosine")  # pgvector
  .limit(5)                                     # top K = 5
```

`nearest_neighbors` comes from the `neighbor` gem (`has_neighbors :embedding` on the
model). Under the hood it generates SQL using pgvector's cosine distance operator,
ordering chunks by how close they are to the question vector, and the HNSW index makes
that fast.

**2. Build the prompt.** `build_messages` formats the retrieved chunks as numbered
context and pairs them with a system prompt that instructs the model to answer *only*
from the context and to cite sources with `[1]`, `[2]`, etc.:

```
CONTEXT:
[1] (page 3) ...chunk text...
[2] (page 7) ...chunk text...

QUESTION: How hot is the core of the Sun?
```

**3. Stream.** `stream_completion` sends this to the chat model with `stream: true`.
The `ruby-openai` gem invokes a callback for each streamed chunk; we pull out
`choices[0].delta.content` (the new token text), append it to the running answer, and
yield it to the controller's block — which forwards it to the browser as an SSE event.

Meanwhile `build_citations` records, for each retrieved chunk, its `index`,
`document_id`, `chunk_id`, `page_number`, and a truncated `snippet` — that's what the
UI renders as citation cards.

### Step 4 — The browser renders it live

Back in `App.jsx`, each `onToken` appends text to the last message bubble (so you see it
"type" in real time), `onCitations` attaches the source cards, and `onDone` finalizes.

---

## Part 6 — Cross-cutting concerns

### The provider abstraction (`LlmClient`)

Everything LLM-related goes through `app/services/llm_client.rb`. `LLM_PROVIDER`
(env var) picks `gemini` (default) or `openai`. The class resolves, per provider:
- the chat model and embedding model names,
- the API key (`GEMINI_API_KEY` or `OPENAI_API_KEY`),
- the base URL (Gemini chat uses its OpenAI-compatible endpoint at `/v1beta/openai`).

This is why swapping providers was a one-env-var change, not a rewrite.

### Retry with backoff (`LlmClient.with_retry`)

Free-tier LLM APIs throttle a lot. The helper retries on transient statuses
(429 rate-limit, 500/502/503/504) with **exponential backoff + jitter**:
- Up to 4 retries after the first attempt.
- Delay grows 1s → 2s → 4s → 8s, capped at 30s.
- If the API returns a suggested delay (Gemini's `retryDelay`), that's honored when
  larger than the computed backoff.
- Non-transient errors (404 bad model, 401 bad key) are *not* retried — they fail fast.

**Streaming caveat:** a chat stream is only retried if it fails *before the first token
is emitted*. Retrying mid-stream would replay tokens the user already saw, so a
partial-then-failed stream is allowed to propagate instead. This is handled in
`RagAnswerer#run_stream` with a `started` flag.

### CORS

`config/initializers/cors.rb` allows the Vite dev origin (`http://localhost:5173`) to
call the API. In production you'd set `FRONTEND_ORIGIN`.

---

## Part 7 — Notable decisions & gotchas (good interview material)

- **pgvector on Postgres 14.** Homebrew's pgvector bottle only targets pg17/18, so it
  was compiled from source against pg14. Lesson: native Postgres extensions are tied to
  a specific major version.
- **Embedding dimension lock-in.** The column is `vector(1536)`. You cannot mix vectors
  from different models in one table — they live in different vector spaces and the
  distances become meaningless. Switching embedding models means re-embedding
  everything.
- **Retired Gemini models.** `gemini-2.5-pro` / `gemini-2.5-flash` are retired for new
  API keys (404). The default is `gemini-flash-lite-latest`. The Pro models have a tiny
  free-tier daily token quota (429 quickly).
- **Google One ≠ Gemini API billing.** A consumer Gemini subscription doesn't lift API
  quotas; the API is billed separately.
- **Why SSE, not WebSockets?** The data only flows one way (server → client) and it's
  short-lived per question. SSE is simpler, works over plain HTTP, and auto-reconnects.

---

## Part 8 — How to explain this in 60 seconds (interview script)

> "DocChat is a RAG app for chatting with PDFs. When you upload a document, a background
> job extracts the text, splits it into overlapping chunks, turns each chunk into a
> 1536-dimension embedding with Gemini, and stores those vectors in Postgres using
> pgvector. When you ask a question, I embed the question the same way, use a cosine
> similarity search over an HNSW index to pull the five most relevant chunks, and feed
> them to the LLM as grounded context. The answer streams back to the React frontend
> token-by-token over Server-Sent Events, along with citations pointing to the source
> pages. The LLM layer is provider-agnostic with automatic retry-and-backoff, since I
> was running on a free tier that throttles."

---

## Part 9 — Where to look in the code

| Concept | File |
|---|---|
| Provider selection + retry | `app/services/llm_client.rb` |
| PDF → text | `app/services/pdf_extractor.rb` |
| Text → chunks | `app/services/text_chunker.rb` |
| Text → embeddings | `app/services/embedding_service.rb` |
| Ingestion orchestration | `app/services/document_ingestor.rb` |
| Retrieve + stream answer | `app/services/rag_answerer.rb` |
| Async processing | `app/jobs/document_processing_job.rb` |
| Similarity search scope | `app/models/document_chunk.rb` (`relevant_to`) |
| Upload endpoint | `app/controllers/documents_controller.rb` |
| SSE streaming endpoint | `app/controllers/messages_controller.rb` |
| Frontend SSE parsing | `frontend/src/api.js` (`streamAnswer`) |
| Frontend UI | `frontend/src/App.jsx` |
