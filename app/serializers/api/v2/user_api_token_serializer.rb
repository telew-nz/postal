# frozen_string_literal: true

module API
  module V2
    class UserAPITokenSerializer < BaseSerializer

      def as_json(*)
        json = {
          uuid: record.uuid,
          name: record.name,
          tier: record.tier,
          scope: record.scope,
          server_id: record.server_id,
          key_prefix: record.key_prefix,
          last_used_at: iso8601(record.last_used_at),
          expires_at: iso8601(record.expires_at),
          revoked_at: iso8601(record.revoked_at),
          created_at: iso8601(record.created_at)
        }

        # The plain text key is only ever included in the response which creates
        # the token. It is not persisted so it cannot be rendered again.
        json[:key] = record.plain_key if options[:include_plain_key] && record.plain_key.present?
        json
      end

    end
  end
end
