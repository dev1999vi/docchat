# Provider-agnostic LLM client for DocChat.
#
# Supports two providers, selected via the LLM_PROVIDER env var:
#   - "gemini" (default) — Google Gemini
#   - "openai"           — OpenAI
#
# Chat completions go through each provider's OpenAI-compatible endpoint using
# the ruby-openai gem (Gemini exposes one at /v1beta/openai). Embeddings use
# each provider's native path so we can pin Gemini's output to 1536 dimensions
# (via Matryoshka truncation) and keep the existing vector(1536) schema.
class LlmClient
  EMBEDDING_DIMENSIONS = 1536

  # Retry tuning for transient upstream errors (429 rate limit, 503 overloaded).
  MAX_RETRIES = 4
  BASE_DELAY = 1.0   # seconds; grows exponentially: 1, 2, 4, 8...
  MAX_DELAY = 30.0   # cap any single backoff wait

  class MissingApiKey < StandardError; end

  # Raised when a request keeps failing with a retryable status after all
  # attempts are exhausted. Carries the HTTP status for callers to message on.
  class RetryableError < StandardError
    attr_reader :status

    def initialize(message, status: nil)
      @status = status
      super(message)
    end
  end

  # Runs the given block, retrying on transient 429/503 responses (and common
  # network errors) with exponential backoff + jitter. If the upstream returns
  # a suggested retry delay (Gemini's RetryInfo / Retry-After), that is honored
  # when it is larger than the computed backoff.
  #
  # The block should raise LlmClient::RetryableError (with a status) for
  # retryable failures. Non-retryable errors propagate immediately.
  def self.with_retry(label: "llm")
    attempt = 0
    begin
      attempt += 1
      yield
    rescue RetryableError => e
      raise e if attempt > MAX_RETRIES

      delay = backoff_delay(attempt, e.message)
      Rails.logger.warn(
        "[LlmClient] #{label} transient #{e.status} (attempt #{attempt}/#{MAX_RETRIES}); retrying in #{delay.round(2)}s"
      )
      sleep(delay)
      retry
    end
  end

  # Status codes we treat as transient/retryable.
  def self.retryable_status?(status)
    [ 429, 500, 502, 503, 504 ].include?(status.to_i)
  end

  def self.backoff_delay(attempt, message = nil)
    suggested = extract_retry_delay(message)
    exponential = [ BASE_DELAY * (2**(attempt - 1)), MAX_DELAY ].min
    jitter = rand * 0.5
    [ suggested.to_f, exponential ].max + jitter
  end

  # Pulls a retry hint out of an error body if present (Gemini returns
  # "retryDelay": "34s"; some APIs use a Retry-After header value).
  def self.extract_retry_delay(message)
    return 0 if message.blank?

    if (m = message.match(/retryDelay["\s:]+(\d+(?:\.\d+)?)s/i))
      [ m[1].to_f, MAX_DELAY ].min
    else
      0
    end
  end

  def self.provider
    ENV.fetch("LLM_PROVIDER", "gemini").downcase
  end

  def self.gemini?
    provider == "gemini"
  end

  def self.chat_model
    if gemini?
      ENV.fetch("GEMINI_CHAT_MODEL", "gemini-flash-latest")
    else
      ENV.fetch("OPENAI_CHAT_MODEL", "gpt-4o-mini")
    end
  end

  def self.embedding_model
    if gemini?
      ENV.fetch("GEMINI_EMBEDDING_MODEL", "gemini-embedding-001")
    else
      ENV.fetch("OPENAI_EMBEDDING_MODEL", "text-embedding-3-small")
    end
  end

  def self.api_key
    key = gemini? ? ENV["GEMINI_API_KEY"] : ENV["OPENAI_API_KEY"]
    raise MissingApiKey, "#{gemini? ? 'GEMINI_API_KEY' : 'OPENAI_API_KEY'} is not set" if key.blank?
    key
  end

  # ruby-openai client used for chat completions (streaming).
  def self.chat_client
    @chat_client ||= OpenAI::Client.new(
      access_token: api_key,
      uri_base: gemini? ? "https://generativelanguage.googleapis.com/v1beta/openai" : nil,
      request_timeout: 120
    )
  end

  def self.reset!
    @chat_client = nil
  end
end
