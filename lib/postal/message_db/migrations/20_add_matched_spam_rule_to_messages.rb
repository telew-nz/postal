# frozen_string_literal: true

module Postal
  module MessageDB
    module Migrations
      class AddMatchedSpamRuleToMessages < Postal::MessageDB::Migration

        def up
          @database.query("ALTER TABLE `#{@database.database_name}`.`messages` ADD COLUMN `matched_rule_id` int(11) DEFAULT NULL")
          @database.query("ALTER TABLE `#{@database.database_name}`.`messages` ADD COLUMN `matched_rule_action` varchar(255) DEFAULT NULL")
        end

      end
    end
  end
end
