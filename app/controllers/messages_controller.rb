class MessagesController < ApplicationController
  include ActionController::Live

  # POST /conversations/:conversation_id/messages
  #
  # Body: { "content": "your question" }
  # Streams the assistant answer back via Server-Sent Events.
  #
  # SSE event types:
  #   token     -> { "text": "..." }        incremental answer tokens
  #   citations -> [ { index, document_id, page_number, snippet }, ... ]
  #   done      -> { "message_id": 123 }
  #   error     -> { "message": "..." }
  def create
    conversation = Conversation.find(params[:conversation_id])
    question = params[:content].to_s.strip

    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    sse = SSE.new(response.stream)

    if question.empty?
      write_event(sse, "error", { message: "content is required" })
      return
    end

    conversation.messages.create!(role: "user", content: question)

    answerer = RagAnswerer.new(question)
    full_answer = answerer.stream do |token|
      write_event(sse, "token", { text: token })
    end

    assistant_message = conversation.messages.create!(
      role: "assistant",
      content: full_answer,
      citations: answerer.citations
    )
    conversation.touch

    write_event(sse, "citations", answerer.citations)
    write_event(sse, "done", { message_id: assistant_message.id })
  rescue LlmClient::MissingApiKey => e
    write_event(sse, "error", { message: e.message })
  rescue => e
    Rails.logger.error("[MessagesController] #{e.class}: #{e.message}")
    write_event(sse, "error", { message: "Something went wrong generating the answer" })
  ensure
    sse&.close
  end

  private

  def write_event(sse, event, data)
    sse.write(data, event: event)
  end
end
