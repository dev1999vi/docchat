class DocumentsController < ApplicationController
  # GET /documents
  def index
    documents = Document.order(created_at: :desc)
    render json: documents.map { |d| serialize(d) }
  end

  # GET /documents/:id
  def show
    document = Document.find(params[:id])
    render json: serialize(document)
  end

  # POST /documents
  # Expects multipart form-data with a `file` field (PDF).
  def create
    upload = params[:file]
    return render_error("file is required", :bad_request) if upload.blank?

    unless upload.content_type == "application/pdf" || File.extname(upload.original_filename).downcase == ".pdf"
      return render_error("only PDF files are supported", :unsupported_media_type)
    end

    document = Document.create!(
      title: params[:title].presence || File.basename(upload.original_filename, ".*"),
      filename: upload.original_filename,
      content_type: upload.content_type,
      byte_size: upload.size,
      status: "pending"
    )

    tmp_path = write_tmp(upload)
    DocumentProcessingJob.perform_async(document.id, tmp_path)

    render json: serialize(document), status: :created
  end

  # DELETE /documents/:id
  def destroy
    Document.find(params[:id]).destroy!
    head :no_content
  end

  private

  def write_tmp(upload)
    dir = Rails.root.join("tmp", "uploads")
    FileUtils.mkdir_p(dir)
    path = dir.join("#{SecureRandom.uuid}-#{upload.original_filename}").to_s
    File.binwrite(path, upload.read)
    path
  end

  def serialize(document)
    {
      id: document.id,
      title: document.title,
      filename: document.filename,
      status: document.status,
      chunks_count: document.chunks_count,
      error_message: document.error_message,
      created_at: document.created_at
    }
  end

  def render_error(message, status)
    render json: { error: message }, status: status
  end
end
