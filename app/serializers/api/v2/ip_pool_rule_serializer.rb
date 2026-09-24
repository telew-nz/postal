# frozen_string_literal: true

module API
  module V2
    class IPPoolRuleSerializer < BaseSerializer

      def as_json(*)
        {
          uuid: record.uuid,
          owner_type: record.owner_type,
          owner_uuid: record.owner&.uuid,
          ip_pool_id: record.ip_pool_id,
          ip_pool_name: record.ip_pool&.name,
          from_text: record.from_text,
          to_text: record.to_text,
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }
      end

    end
  end
end
