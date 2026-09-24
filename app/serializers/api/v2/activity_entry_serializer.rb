# frozen_string_literal: true

module API
  module V2
    # Activity entries are a mixture of deliveries, clicks and loads. Each of
    # them is a different class with a different set of attributes so the
    # serializer renders the type alongside the attributes it has.
    class ActivityEntrySerializer < BaseSerializer

      def as_json(*)
        case record
        when Postal::MessageDB::Delivery then delivery
        when Postal::MessageDB::Click then click
        when Postal::MessageDB::Load then load_entry
        else { type: record.class.name.demodulize, timestamp: iso8601(record.timestamp) }
        end
      end

      private

      def delivery
        {
          type: "Delivery",
          status: record.status,
          details: text(record.details),
          output: text(record.output),
          code: record.code,
          log_id: record.log_id,
          sent_with_ssl: boolean(record.sent_with_ssl),
          time: decimal(record.time),
          timestamp: iso8601(record.timestamp)
        }
      end

      def click
        {
          type: "Click",
          url: record.url,
          ip_address: record.ip_address,
          user_agent: text(record.user_agent),
          timestamp: iso8601(record.timestamp)
        }
      end

      def load_entry
        {
          type: "Load",
          ip_address: record.ip_address,
          user_agent: text(record.user_agent),
          timestamp: iso8601(record.timestamp)
        }
      end

    end
  end
end
