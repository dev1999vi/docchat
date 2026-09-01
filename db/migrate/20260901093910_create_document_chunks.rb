class CreateDocumentChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :document_chunks do |t|
      t.references :document, null: false, foreign_key: true
      t.integer :position, null: false
      t.text :content, null: false
      t.integer :page_number
      t.integer :token_count
      # OpenAI text-embedding-3-small has 1536 dimensions
      t.column :embedding, "vector(1536)"

      t.timestamps
    end

    add_index :document_chunks, [ :document_id, :position ], unique: true
  end
end
