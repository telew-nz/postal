# frozen_string_literal: true

class CreateDomainSpamRules < ActiveRecord::Migration[7.0]

  def change
    create_table "domain_spam_rules", force: :cascade, options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4" do |t|
      t.string   "uuid"
      t.integer  "domain_id"
      t.string   "kind",        null: false      # allowlist | blocklist
      t.string   "match_type",  null: false      # address | domain
      t.string   "value",       null: false      # user@example.com | example.com
      t.string   "action",      null: false      # reject | mark_spam | add_header | none
      t.boolean  "enabled",     default: true
      t.datetime "created_at",  precision: nil
      t.datetime "updated_at",  precision: nil
      t.index ["domain_id"], name: "index_domain_spam_rules_on_domain_id", using: :btree
      t.index ["uuid"], name: "index_domain_spam_rules_on_uuid", length: { uuid: 8 }, using: :btree
    end
  end

end
