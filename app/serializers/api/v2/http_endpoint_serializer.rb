# frozen_string_literal: true

module API
  module V2
    class HTTPEndpointSerializer < BaseSerializer

      def as_json(*)
        {
          uuid: record.uuid,
          name: record.name,
          url: record.url,
          encoding: record.encoding,
          format: record.format,
          strip_replies: record.strip_replies,
          include_attachments: record.include_attachments,
          timeout: record.timeout,
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
