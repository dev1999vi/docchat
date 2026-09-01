require "sidekiq"

# Async processing of an uploaded PDF. Reads the temp file written by the
# controller, runs the ingestion pipeline, then removes the temp file.
class DocumentProcessingJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  def perform(document_id, tmp_path)
    document = Document.find(document_id)

    File.open(tmp_path, "rb") do |io|
      DocumentIngestor.new(document, io).call
    end
  ensure
    File.delete(tmp_path) if tmp_path && File.exist?(tmp_path)
  end
end
