# frozen_string_literal: true

module API
  module V2
    class SMTPEndpointSerializer < BaseSerializer

      def as_json(*)
        {
          uuid: record.uuid,
          name: record.name,
          hostname: record.hostname,
          port: record.port,
          ssl_mode: record.ssl_mode,
          last_used_at: iso8601(record.last_used_at),
          disabled_until: iso8601(record.disabled_until),
          error: record.error,
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }
      end

    end
  end
end
