# DocChat

Upload a PDF, ask questions about it, get answers that cite the exact page they came from.

I built this to have a real, working RAG app rather than just the buzzwords on a resume. It's a fairly standard retrieval-augmented-generation setup, but I tried to keep it honest — real streaming, real citations, and it fails gracefully when the LLM provider throttles you (which, on a free tier, it will).

## The idea

LLMs don't know what's in your PDFs, and if you ask anyway they'll happily make something up. RAG gets around that: before answering, you find the passages in your document that are actually relevant to the question and hand those to the model as context. The answer stays grounded in your source material, and you can point back to where each claim came from.

Two things happen in the app:

- **Ingestion** — a PDF gets split into chunks, each chunk is turned into an embedding (a vector that captures its meaning), and those vectors go into Postgres.
- **Querying** — your question gets embedded too, we find the closest chunks by vector similarity, feed them to the model, and stream the answer back.

## Stack

- Rails 8.1 in API mode (Ruby 4.0.5)
- Postgres 14 with the pgvector extension for vector search
- Gemini for embeddings + chat (swappable to OpenAI, see below)
- Sidekiq + Redis so uploads don't block on processing
- React + Vite on the frontend
- Server-Sent Events for token-by-token streaming

## Running it locally

You'll need Ruby 4.0.5, Postgres 14 with pgvector, Redis, Node 18+, and a Gemini API key ([grab one here](https://aistudio.google.com/apikey)).

```bash
bundle install
cp .env.example .env        # drop your GEMINI_API_KEY in here

export $(grep -vE '^#|^$' .env | xargs)
bin/rails db:prepare        # creates the DBs, enables pgvector, migrates
```

Then start everything:

```bash
./bin/dev-all
```

That boots the API, the Sidekiq worker, and the frontend together and tears them all down on Ctrl-C. Open http://localhost:5173 and you're good.

If you'd rather run them separately (three terminals, each needs the env exported first):

```bash
export $(grep -vE '^#|^$' .env | xargs)
bin/rails server -p 3000
bundle exec sidekiq
cd frontend && npm run dev
```

> Heads up: if your shell has one of those interactive dotenv plugins that asks "Source it? [Y/n]", it can eat your env vars in non-interactive runs. That's why the commands above export `.env` by hand — `bin/dev-all` does the same thing internally.

## A note on pgvector

Homebrew's pgvector bottle only ships for Postgres 17/18, and I'm on 14. So it's built from source against pg14 — if you ever reinstall or bump Postgres, you'll need to rebuild pgvector for the new version or the `vector` extension won't be there.

## Switching LLM providers

Everything LLM-related goes through `app/services/llm_client.rb`. Flip `LLM_PROVIDER` between `gemini` (default) and `openai` and it sorts out the model names, keys, and endpoints.

- Chat goes through each provider's OpenAI-compatible endpoint via the `ruby-openai` gem (Gemini's lives at `/v1beta/openai`).
- Embeddings use each provider's native endpoint, both pinned to **1536 dimensions** so they fit the `vector(1536)` column. Gemini defaults to 3072 but supports truncating to 1536 with barely any quality loss (Matryoshka), and I normalize the result to unit length so cosine distance behaves.

One catch worth knowing: you can't mix embeddings from different models in the same table — different models live in different vector spaces, so the distances become meaningless. If you switch embedding models, re-embed everything.

### Gemini models and quota (learned the hard way)

Google rotates models faster than you'd expect:

- `gemini-2.5-pro` and `gemini-2.5-flash` are already **retired for new API keys** — they 404. Took me a minute to figure out that was the problem and not my code.
- Default here is `gemini-flash-lite-latest`, which works well for RAG and has a decent free tier.
- The Pro models (`gemini-pro-latest` / `gemini-3.1-pro-preview`) do resolve, but the free tier has a tiny *per-day* token quota, so they start returning 429 almost immediately.
- Embeddings use `gemini-embedding-001`.

Also: a Google One / Gemini app subscription is **not** the same as paid API access — they're billed separately. If you want the Pro models without hitting the daily cap, you have to turn on billing for the Gemini API itself.

### Retries

Because the free tier throttles a lot, transient failures (429, and 5xx when the model is overloaded) get retried automatically with exponential backoff + jitter — see `LlmClient.with_retry`. It respects the `retryDelay` the API sends back, caps individual waits at 30s, and gives up after a few tries.

Streaming is the tricky bit: it only retries if the request dies *before* the first token lands. Retrying halfway through a stream would just replay the tokens you already saw, so a mid-stream failure is allowed to bubble up instead.

## API

| Method | Path | What it does |
|---|---|---|
| GET | `/documents` | List documents + processing status |
| POST | `/documents` | Upload a PDF (multipart `file`) |
| DELETE | `/documents/:id` | Delete a document and its chunks |
| POST | `/conversations` | Start a conversation |
| GET | `/conversations/:id` | Conversation + message history |
| POST | `/conversations/:id/messages` | Ask a question (streams over SSE) |

The messages endpoint emits SSE events in this order: `token` (many), then `citations`, then `done` — or `error` if something goes wrong. Sidekiq's dashboard is at `/sidekiq` in dev.

## How the code is laid out

```
app/
  models/            Document, DocumentChunk (has_neighbors), Conversation, Message
  services/
    llm_client.rb        provider selection + retry logic
    pdf_extractor.rb     PDF -> per-page text
    text_chunker.rb      text -> overlapping chunks
    embedding_service.rb text -> 1536-dim embeddings
    document_ingestor.rb ties the ingestion steps together
    rag_answerer.rb      retrieve relevant chunks + stream the answer
  jobs/
    document_processing_job.rb   runs ingestion in the background
  controllers/
    documents_controller.rb
    conversations_controller.rb
    messages_controller.rb       the SSE streaming endpoint
frontend/            React + Vite UI
```

## Things I'd do next

- Tests (there aren't any yet — the retrieval + retry paths are the obvious places to start)
- Auth, so it's not wide open
- Show upload/processing progress in the UI instead of just a status label
- Let you scope a question to a single document instead of searching everything
