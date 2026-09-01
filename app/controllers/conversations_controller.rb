class ConversationsController < ApplicationController
  # GET /conversations
  def index
    conversations = Conversation.order(updated_at: :desc)
    render json: conversations.map { |c| serialize(c) }
  end

  # GET /conversations/:id
  def show
    conversation = Conversation.includes(:messages).find(params[:id])
    render json: serialize(conversation, include_messages: true)
  end

  # POST /conversations
  def create
    conversation = Conversation.create!(title: params[:title].presence || "New conversation")
    render json: serialize(conversation), status: :created
  end

  # DELETE /conversations/:id
  def destroy
    Conversation.find(params[:id]).destroy!
    head :no_content
  end

  private

  def serialize(conversation, include_messages: false)
    data = {
      id: conversation.id,
      title: conversation.title,
      created_at: conversation.created_at,
      updated_at: conversation.updated_at
    }
    if include_messages
      data[:messages] = conversation.messages.chronological.map do |m|
        { id: m.id, role: m.role, content: m.content, citations: m.citations, created_at: m.created_at }
      end
    end
    data
  end
end
