require "net/http"
require "json"

# Converts text into embedding vectors.
#
# Uses the configured provider (Gemini or OpenAI). Both are pinned to 1536
# dimensions so they fit the vector(1536) column. For Gemini this uses
# outputDimensionality (Matryoshka truncation); for OpenAI the `dimensions`
# param on text-embedding-3-*.
class EmbeddingService
  GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta"

  class EmbeddingError < StandardError; end

  # Embed a single string, returns an Array<Float> of length 1536.
  def self.embed(text)
    embed_batch([ text ]).first
  end

  # Embed multiple strings. Returns Array<Array<Float>>.
  # Retries automatically on transient upstream errors (429/503).
  def self.embed_batch(texts)
    texts = Array(texts).map { |t| t.to_s.strip }.reject(&:empty?)
    return [] if texts.empty?

    LlmClient.with_retry(label: "embeddings") do
      LlmClient.gemini? ? gemini_embed(texts) : openai_embed(texts)
    end
  end

  # --- Gemini ---------------------------------------------------------------

  def self.gemini_embed(texts)
    model = LlmClient.embedding_model
    uri = URI("#{GEMINI_BASE}/models/#{model}:batchEmbedContents?key=#{LlmClient.api_key}")

    requests = texts.map do |text|
      {
        model: "models/#{model}",
        content: { parts: [ { text: text } ] },
        taskType: "RETRIEVAL_DOCUMENT",
        outputDimensionality: LlmClient::EMBEDDING_DIMENSIONS
      }
    end

    body = post_json(uri, { requests: requests })
    embeddings = body.fetch("embeddings") { raise EmbeddingError, "Gemini: no embeddings in response" }
    embeddings.map { |e| normalize(e.fetch("values")) }
  end

  # --- OpenAI ---------------------------------------------------------------

  def self.openai_embed(texts)
    response = LlmClient.chat_client.embeddings(
      parameters: {
        model: LlmClient.embedding_model,
        input: texts,
        dimensions: LlmClient::EMBEDDING_DIMENSIONS
      }
    )
    response.fetch("data").sort_by { |d| d["index"] }.map { |d| d.fetch("embedding") }
  end

  # --- helpers --------------------------------------------------------------

  # Gemini's outputDimensionality truncation returns unnormalized vectors for
  # sizes other than 3072; normalizing to unit length keeps cosine distance
  # well-behaved. (No-op if already unit length.)
  def self.normalize(vec)
    magnitude = Math.sqrt(vec.sum { |v| v * v })
    return vec if magnitude.zero?
    vec.map { |v| v / magnitude }
  end

  def self.post_json(uri, payload)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 120

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = payload.to_json

    response = http.request(request)

    if LlmClient.retryable_status?(response.code)
      raise LlmClient::RetryableError.new(
        "Embedding request transient failure (#{response.code}): #{response.body}",
        status: response.code.to_i
      )
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise EmbeddingError, "Embedding request failed (#{response.code}): #{response.body}"
    end

    JSON.parse(response.body)
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, EOFError => e
    # Treat network hiccups as retryable too.
    raise LlmClient::RetryableError.new("Embedding network error: #{e.message}", status: 503)
  end
end
