# frozen_string_literal: true

module API
  module V2
    class CredentialSerializer < BaseSerializer

      def as_json(*)
        json = {
          uuid: record.uuid,
          name: record.name,
          type: record.type,
          hold: record.hold,
          last_used_at: iso8601(record.last_used_at),
          usage_type: record.usage_type,
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }

        # The key is omitted from collection responses so that listing
        # credentials cannot be used to harvest the keys for a server.
        json[:key] = record.key unless options[:redact_key]
        json
      end

    end
  end
end
