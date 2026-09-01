class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages do |t|
      t.references :conversation, null: false, foreign_key: true
      # user | assistant
      t.string :role, null: false
      t.text :content, null: false, default: ""
      # Array of { document_id, chunk_id, page_number, snippet } used to ground the answer
      t.jsonb :citations, null: false, default: []

      t.timestamps
    end

    add_index :messages, [ :conversation_id, :created_at ]
  end
end
