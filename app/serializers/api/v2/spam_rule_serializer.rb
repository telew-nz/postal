# frozen_string_literal: true

module API
  module V2
    class SpamRuleSerializer < BaseSerializer

      def as_json(*)
        {
          uuid: record.uuid,
          domain_id: record.domain_id,
          kind: record.kind,
          match_type: record.match_type,
          value: record.value,
          action: record.action,
          enabled: boolean(record.enabled),
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }
      end

    end
  end
end
