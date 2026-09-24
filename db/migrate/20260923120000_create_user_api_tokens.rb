# frozen_string_literal: true

class CreateUserAPITokens < ActiveRecord::Migration[7.0]

  def change
    create_table "user_api_tokens", force: :cascade, options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4" do |t|
      t.string   "uuid"
      t.integer  "user_id"
      t.string   "name"
      t.string   "key"
      t.string   "key_prefix"
      t.datetime "last_used_at", precision: nil
      t.datetime "expires_at",   precision: nil
      t.datetime "revoked_at",   precision: nil
      t.datetime "created_at",   precision: nil
      t.datetime "updated_at",   precision: nil
      t.index ["key"], name: "index_user_api_tokens_on_key", length: { key: 8 }, using: :btree
      t.index ["user_id"], name: "index_user_api_tokens_on_user_id", using: :btree
      t.index ["uuid"], name: "index_user_api_tokens_on_uuid", length: { uuid: 8 }, using: :btree
    end
  end

end
