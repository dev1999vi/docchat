# Orchestrates the full ingestion pipeline for a single document:
#   extract text -> chunk -> embed -> persist chunks with vectors.
#
# Designed to be called from a background job. Updates document status as it goes.
class DocumentIngestor
  EMBED_BATCH_SIZE = 100

  def initialize(document, pdf_io)
    @document = document
    @pdf_io = pdf_io
  end

  def call
    @document.mark_processing!

    pages = PdfExtractor.extract(@pdf_io)
    chunks = TextChunker.new.call(pages)
    raise "No extractable text found in document" if chunks.empty?

    persist_chunks(chunks)
    @document.mark_processed!
    @document
  rescue => e
    @document.mark_failed!(e.message)
    raise
  end

  private

  def persist_chunks(chunks)
    chunks.each_slice(EMBED_BATCH_SIZE) do |batch|
      embeddings = EmbeddingService.embed_batch(batch.map(&:content))

      rows = batch.each_with_index.map do |chunk, i|
        {
          document_id: @document.id,
          position: chunk.position,
          content: chunk.content,
          page_number: chunk.page_number,
          token_count: chunk.content.split(/\s+/).length,
          embedding: embeddings[i],
          created_at: Time.current,
          updated_at: Time.current
        }
      end

      DocumentChunk.insert_all!(rows)
    end
  end
end
