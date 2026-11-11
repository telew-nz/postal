# frozen_string_literal: true

module Postal
  module MessageDB
    module Migrations
      # This is version 21 rather than 20 because 20 is already taken by
      # IncreaseLinksUrlSize. Migrations are skipped by number, so a second
      # version 20 never ran on a message database which was already at 20:
      # that is every mail server which existed before this file did.
      #
      # A mail server created while this file was still numbered 20 ran it then,
      # and reaches it again under its new number with the columns present. Each
      # column is therefore only added when it is missing.
      class AddMatchedSpamRuleToMessages < Postal::MessageDB::Migration

        COLUMNS = {
          "matched_rule_id" => "int(11) DEFAULT NULL",
          "matched_rule_action" => "varchar(255) DEFAULT NULL"
        }.freeze

        def up
          COLUMNS.each do |name, definition|
            next if column_exists?(name)

            @database.query("ALTER TABLE `#{@database.database_name}`.`messages` ADD COLUMN `#{name}` #{definition}")
          end
        end

        private

        def column_exists?(name)
          @database.query(
            "SELECT column_name FROM `information_schema`.`columns` " \
            "WHERE table_schema = '#{@database.database_name}' AND table_name = 'messages' AND column_name = '#{name}'"
          ).any?
        end

      end
    end
  end
end
