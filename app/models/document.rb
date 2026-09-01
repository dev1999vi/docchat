class Document < ApplicationRecord
  has_many :document_chunks, dependent: :destroy

  STATUSES = %w[pending processing processed failed].freeze

  validates :title, :filename, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :processed, -> { where(status: "processed") }

  def mark_processing!
    update!(status: "processing", error_message: nil)
  end

  def mark_processed!
    update!(status: "processed", chunks_count: document_chunks.count)
  end

  def mark_failed!(message)
    update!(status: "failed", error_message: message.to_s.truncate(1000))
  end
end
