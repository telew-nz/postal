# frozen_string_literal: true

module API
  module V2
    # Deliveries live in the message database and are instances of
    # Postal::MessageDB::Delivery which, like messages, have no usable #as_json.
    class DeliverySerializer < BaseSerializer

      def as_json(*)
        {
          id: record.id,
          message_id: record.message_id,
          status: record.status,
          code: record.code,
          details: text(record.details),
          output: text(record.output),
          sent_with_ssl: boolean(record.sent_with_ssl),
          log_id: record.log_id,
          time: decimal(record.time),
          timestamp: iso8601(record.timestamp)
        }
      end

    end
  end
end
