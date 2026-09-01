# Retrieval-Augmented Generation: given a question, retrieve the most relevant
# document chunks and stream an LLM answer grounded in them.
#
# Usage:
#   answerer = RagAnswerer.new(question)
#   answerer.stream { |token| ... }   # yields text tokens as they arrive
#   answerer.citations                # available after streaming completes
class RagAnswerer
  TOP_K = 5

  SYSTEM_PROMPT = <<~PROMPT.freeze
    You are DocChat, an assistant that answers questions strictly using the
    provided document excerpts. Follow these rules:
    - Answer only from the CONTEXT below. If the answer isn't in the context,
      say you couldn't find it in the documents.
    - Cite sources inline using the bracketed source numbers, e.g. [1], [2].
    - Be concise and factual.
  PROMPT

  attr_reader :citations

  def initialize(question, top_k: TOP_K)
    @question = question.to_s.strip
    @top_k = top_k
    @citations = []
  end

  # Streams the answer, yielding each text token to the given block.
  # Returns the full answer text.
  def stream(&block)
    raise ArgumentError, "question is blank" if @question.empty?

    chunks = retrieve_chunks
    @citations = build_citations(chunks)

    if chunks.empty?
      message = "I couldn't find anything relevant in the uploaded documents."
      block&.call(message)
      return message
    end

    stream_completion(build_messages(chunks), &block)
  end

  private

  def retrieve_chunks
    query_embedding = EmbeddingService.embed(@question)
    DocumentChunk.relevant_to(query_embedding, limit: @top_k).to_a
  end

  def build_citations(chunks)
    chunks.each_with_index.map do |chunk, i|
      {
        index: i + 1,
        document_id: chunk.document_id,
        chunk_id: chunk.id,
        page_number: chunk.page_number,
        snippet: chunk.content.truncate(240)
      }
    end
  end

  def build_messages(chunks)
    context = chunks.each_with_index.map do |chunk, i|
      "[#{i + 1}] (page #{chunk.page_number}) #{chunk.content}"
    end.join("\n\n")

    [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: "CONTEXT:\n#{context}\n\nQUESTION: #{@question}" }
    ]
  end

  def stream_completion(messages, &block)
    LlmClient.with_retry(label: "chat") do
      run_stream(messages, &block)
    end
  end

  # Performs one streaming attempt. Retries only when the request fails before
  # any token was emitted — retrying mid-stream would duplicate output for the
  # user, so a partial-then-failed stream propagates instead.
  def run_stream(messages, &block)
    full = +""
    started = false

    begin
      LlmClient.chat_client.chat(
        parameters: {
          model: LlmClient.chat_model,
          messages: messages,
          temperature: 0.2,
          stream: proc do |chunk, _bytesize|
            token = chunk.dig("choices", 0, "delta", "content")
            next if token.nil?

            started = true
            full << token
            block&.call(token)
          end
        }
      )
      full
    rescue Faraday::Error => e
      status = faraday_status(e)
      # Only convert to a retryable error if nothing has streamed yet and the
      # status is transient. Otherwise re-raise for the controller to handle.
      if !started && LlmClient.retryable_status?(status)
        raise LlmClient::RetryableError.new("Chat transient failure (#{status})", status: status)
      end
      raise
    end
  end

  def faraday_status(error)
    error.response&.dig(:status) || error.response_status
  rescue StandardError
    nil
  end
end
