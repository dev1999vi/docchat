class CreateConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :conversations do |t|
      t.string :title, null: false, default: "New conversation"

      t.timestamps
    end
  end
end
