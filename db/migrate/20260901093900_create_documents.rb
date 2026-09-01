class CreateDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :documents do |t|
      t.string :title, null: false
      t.string :filename, null: false
      t.string :content_type
      t.integer :byte_size
      # pending -> processing -> processed / failed
      t.string :status, null: false, default: "pending"
      t.integer :chunks_count, null: false, default: 0
      t.text :error_message

      t.timestamps
    end

    add_index :documents, :status
  end
end
