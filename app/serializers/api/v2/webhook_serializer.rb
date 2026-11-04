# frozen_string_literal: true

module API
  module V2
    # Webhooks deliver lifecycle event notifications for a mail server to an
    # HTTP endpoint. This serializer renders every field a client needs to
    # manage them.
    class WebhookSerializer < BaseSerializer

      def as_json(*)
        {
          uuid: record.uuid,
          name: record.name,
          url: record.url,
          all_events: record.all_events,
          enabled: record.enabled,
          events: record.events,
          last_used_at: iso8601(record.last_used_at),
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }
      end

    end
  end
end
