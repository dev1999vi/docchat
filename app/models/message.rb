class Message < ApplicationRecord
  belongs_to :conversation

  ROLES = %w[user assistant].freeze

  validates :role, inclusion: { in: ROLES }

  scope :chronological, -> { order(created_at: :asc) }
end
