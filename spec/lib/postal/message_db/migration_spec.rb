# frozen_string_literal: true

require "rails_helper"

RSpec.describe Postal::MessageDB::Migration do
  let(:migration_files) { Dir[Rails.root.join("lib", "postal", "message_db", "migrations", "*.rb")] }

  # Migrations are recorded and skipped by number alone. Two files which share
  # a number break both ways: a new message database fails to provision on the
  # duplicate primary key, and an existing one at that number never runs the
  # second file.
  it "gives every migration its own version number" do
    versions = migration_files.map { |f| File.basename(f).split("_", 2).first.to_i }
    duplicated = versions.select { |v| versions.count(v) > 1 }.uniq

    expect(duplicated).to eq []
  end

  describe "provisioning a new message database" do
    before { GlobalMessageDB.find_or_create }

    let(:database) { GlobalMessageDB.find_or_create }

    it "runs every migration" do
      latest = migration_files.map { |f| File.basename(f).split("_", 2).first.to_i }.max
      recorded = database.select(:migrations, order: :version).map { |r| r["version"] }

      expect(recorded).to eq (1..latest).to_a
    end

    # A message database which ran AddMatchedSpamRuleToMessages while it was
    # still numbered 20 reaches it again as 21 with the columns in place.
    it "can add the matched spam rule columns when they are already there" do
      require "postal/message_db/migrations/21_add_matched_spam_rule_to_messages"
      migration = Postal::MessageDB::Migrations::AddMatchedSpamRuleToMessages.new(database)

      expect { migration.up }.not_to raise_error
      columns = database.query("SHOW COLUMNS FROM `#{database.database_name}`.`messages` LIKE 'matched_rule%'").map { |r| r["Field"] }
      expect(columns).to contain_exactly("matched_rule_id", "matched_rule_action")
    end
  end
end
