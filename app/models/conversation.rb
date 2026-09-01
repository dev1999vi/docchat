class Conversation < ApplicationRecord
  has_many :messages, -> { order(created_at: :asc) }, dependent: :destroy

  validates :title, presence: true
end
