# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_01_093940) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

  create_table "conversations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "title", default: "New conversation", null: false
    t.datetime "updated_at", null: false
  end

  create_table "document_chunks", force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.bigint "document_id", null: false
    t.vector "embedding", limit: 1536
    t.integer "page_number"
    t.integer "position", null: false
    t.integer "token_count"
    t.datetime "updated_at", null: false
    t.index ["document_id", "position"], name: "index_document_chunks_on_document_id_and_position", unique: true
    t.index ["document_id"], name: "index_document_chunks_on_document_id"
    t.index ["embedding"], name: "index_document_chunks_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
  end

  create_table "documents", force: :cascade do |t|
    t.integer "byte_size"
    t.integer "chunks_count", default: 0, null: false
    t.string "content_type"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "filename", null: false
    t.string "status", default: "pending", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["status"], name: "index_documents_on_status"
  end

  create_table "messages", force: :cascade do |t|
    t.jsonb "citations", default: [], null: false
    t.text "content", default: "", null: false
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "created_at"], name: "index_messages_on_conversation_id_and_created_at"
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
  end

  add_foreign_key "document_chunks", "documents"
  add_foreign_key "messages", "conversations"
end
