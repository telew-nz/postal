# frozen_string_literal: true

module API
  module V2
    class OrganizationSerializer < BaseSerializer

      def as_json(*)
        {
          uuid: record.uuid,
          permalink: record.permalink,
          name: record.name,
          time_zone: record.time_zone,
          ip_pool_id: record.ip_pool_id,
          owner_uuid: record.owner&.uuid,
          suspended: record.suspended?,
          suspension_reason: record.suspension_reason,
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }
      end

    end
  end
end
