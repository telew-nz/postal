# frozen_string_literal: true

module API
  module V2
    class QueuedMessageSerializer < BaseSerializer

      def as_json(*)
        {
          id: record.id,
          message_id: record.message_id,
          domain: record.domain,
          attempts: record.attempts,
          retry_after: iso8601(record.retry_after),
          locked: record.locked?,
          locked_by: record.locked_by,
          locked_at: iso8601(record.locked_at),
          manual: record.manual,
          batch_key: record.batch_key,
          ip_address: ip_address,
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }
      end

      private

      def ip_address
        return nil if record.ip_address.nil?

        {
          ipv4: record.ip_address.ipv4,
          ipv6: record.ip_address.ipv6,
          hostname: record.ip_address.hostname
        }
      end

    end
  end
end
