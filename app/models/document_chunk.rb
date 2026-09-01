class DocumentChunk < ApplicationRecord
  belongs_to :document

  has_neighbors :embedding

  validates :content, :position, presence: true

  # Find the most relevant chunks to a query embedding using cosine distance.
  # Only searches chunks belonging to processed documents.
  scope :relevant_to, ->(query_embedding, limit: 5) do
    joins(:document)
      .where(documents: { status: "processed" })
      .where.not(embedding: nil)
      .nearest_neighbors(:embedding, query_embedding, distance: "cosine")
      .limit(limit)
  end
end
