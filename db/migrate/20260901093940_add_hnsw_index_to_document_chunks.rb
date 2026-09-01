class AddHnswIndexToDocumentChunks < ActiveRecord::Migration[8.1]
  def up
    # HNSW index for approximate nearest-neighbor search using cosine distance.
    execute <<~SQL
      CREATE INDEX index_document_chunks_on_embedding
      ON document_chunks
      USING hnsw (embedding vector_cosine_ops)
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS index_document_chunks_on_embedding"
  end
end
