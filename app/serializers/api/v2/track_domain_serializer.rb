# frozen_string_literal: true

module API
  module V2
    class TrackDomainSerializer < BaseSerializer

      def as_json(*)
        {
          uuid: record.uuid,
          name: record.name,
          full_name: record.full_name,
          domain_uuid: record.domain&.uuid,
          server_uuid: record.server&.uuid,
          ssl_enabled: record.ssl_enabled,
          track_clicks: record.track_clicks,
          track_loads: record.track_loads,
          excluded_click_domains: record.excluded_click_domains_array,
          dns_status: record.dns_status,
          dns_error: record.dns_error,
          dns_ok: record.dns_ok?,
          dns_checked_at: iso8601(record.dns_checked_at),
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }
      end

    end
  end
end
