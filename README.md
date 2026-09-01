# DocChat — Chat with your documents

Upload PDFs and ask questions about them in natural language. Answers are
grounded in your documents using Retrieval-Augmented Generation (RAG) and
streamed back in real time with citations pointing to the source pages.

## How it works

1. **Upload** a PDF → text is extracted page-by-page (`pdf-reader`).
2. **Chunk** the text into overlapping windows (`TextChunker`).
3. **Embed** each chunk into a 1536-dim vector and store it in PostgreSQL using
   the `pgvector` extension (`vector(1536)` column).
4. **Ask** a question → the question is embedded, the most similar chunks are
   retrieved via cosine similarity (HNSW index), fed to the LLM as context, and
   the answer is streamed back over Server-Sent Events with citations.

Document processing runs asynchronously in **Sidekiq** so uploads return
immediately.

## Stack

- Ruby on Rails 8.1 (API mode) — Ruby 4.0.5
- PostgreSQL 14 + pgvector 0.8.0
- **Google Gemini** (default) or OpenAI — pluggable via `LLM_PROVIDER`
- Sidekiq + Redis for async processing
- React + Vite frontend
- Server-Sent Events for streaming answers

## LLM provider

DocChat is provider-agnostic. Set `LLM_PROVIDER` to `gemini` (default) or
`openai`. All LLM access goes through `app/services/llm_client.rb`.

- **Chat completions** use each provider's OpenAI-compatible endpoint via the
  `ruby-openai` gem. Gemini's lives at `/v1beta/openai`.
- **Embeddings** use each provider's native embeddings API, both pinned to
  **1536 dimensions** so they fit the `vector(1536)` column. Gemini uses
  `outputDimensionality` (Matryoshka truncation) and the result is normalized
  to unit length so cosine distance stays well-behaved.

> You can't mix embeddings from different providers/models in the same table —
> they live in different vector spaces. If you switch embedding models, re-embed
> your documents.

### Gemini models & quota (important)

Model availability on the Gemini API changes over time:

- `gemini-2.5-pro` and `gemini-2.5-flash` are **retired for new API users**
  (they return 404). Use current models instead.
- **Default chat model:** `gemini-flash-lite-latest` — works well for RAG and
  has a generous free tier.
- Other options: `gemini-flash-latest`, `gemini-pro-latest`
  (`gemini-3.1-pro-preview`). The **Pro** models have a small free-tier
  *per-day* token quota and will return 429 quickly on the free tier.
- **Embeddings:** `gemini-embedding-001`.

### Automatic retry with backoff

Transient upstream failures (HTTP 429 rate-limit, 500/502/503/504) are retried
automatically with exponential backoff + jitter (`LlmClient.with_retry`):

- Up to `MAX_RETRIES` (4) retries after the initial attempt.
- Honors the provider's suggested delay when present (Gemini's `retryDelay`).
- Backoff grows 1s → 2s → 4s → 8s, capped at 30s per wait.
- **Streaming chat** is only retried if the request fails *before any token has
  streamed* — retrying mid-stream would duplicate output, so a partial-then-
  failed stream propagates instead.
- Non-transient errors (e.g. 404 bad model, 401 bad key) propagate immediately.

## Prerequisites

- Ruby 4.0.5 (`rvm use ruby-4.0.5`)
- PostgreSQL 14 running locally with the `vector` extension installed
- Redis (`brew install redis && brew services start redis`)
- Node 18+ for the frontend
- A Gemini API key (https://aistudio.google.com/apikey) — or an OpenAI key

> pgvector is built from source against PostgreSQL 14 (Homebrew's bottle only
> targets pg17/pg18). If you reinstall Postgres, rebuild pgvector for that
> version.

## Setup

```bash
# 1. Backend deps
bundle install

# 2. Environment
cp .env.example .env   # then set GEMINI_API_KEY
```

Load the env and prepare the database:

```bash
export $(grep -vE '^#|^$' .env | xargs)
bin/rails db:prepare   # creates DBs, enables pgvector, runs migrations
```

> **Heads up:** if your shell has an interactive dotenv plugin, it may prompt to
> "Source it?" and can swallow env vars in non-interactive runs. The explicit
> `export $(grep -vE '^#|^$' .env | xargs)` above sidesteps that by exporting
> the vars into the current shell before the process starts.

## Running

Three processes (each needs the env exported first):

```bash
export $(grep -vE '^#|^$' .env | xargs)

# API
bin/rails server -p 3000

# Background worker (document processing)
bundle exec sidekiq

# Frontend (proxies /api -> localhost:3000)
cd frontend && npm install && npm run dev
```

Open http://localhost:5173.

## API

| Method | Path | Description |
|---|---|---|
| GET | `/documents` | List documents + processing status |
| POST | `/documents` | Upload a PDF (multipart `file`) |
| DELETE | `/documents/:id` | Delete a document and its chunks |
| POST | `/conversations` | Start a conversation |
| GET | `/conversations/:id` | Conversation with message history |
| POST | `/conversations/:id/messages` | Ask a question (SSE stream) |

The messages endpoint streams these SSE events: `token`, `citations`, `done`,
`error`.

Sidekiq dashboard is mounted at `/sidekiq` in development.

## Project layout

```
app/
  models/            Document, DocumentChunk (has_neighbors), Conversation, Message
  services/
    llm_client.rb        provider selection + retry-with-backoff
    pdf_extractor.rb     PDF -> per-page text
    text_chunker.rb      text -> overlapping chunks
    embedding_service.rb text -> 1536-dim embeddings (Gemini or OpenAI)
    document_ingestor.rb full ingestion pipeline
    rag_answerer.rb      retrieve + stream a grounded answer
  jobs/
    document_processing_job.rb   async ingestion
  controllers/
    documents_controller.rb
    conversations_controller.rb
    messages_controller.rb       SSE streaming
frontend/              React + Vite UI
```
