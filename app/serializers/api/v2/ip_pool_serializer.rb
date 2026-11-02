# frozen_string_literal: true

module API
  module V2
    class IPPoolSerializer < BaseSerializer

      def as_json(*)
        {
          # The integer ID is exposed because creating or updating a server and
          # creating an IP pool rule both take an `ip_pool_id` and there is
          # otherwise no way for a client to discover a valid one. Nothing else
          # in this API addresses a pool by ID.
          id: record.id,
          uuid: record.uuid,
          name: record.name,
          default: record.default,
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }
      end

    end
  end
end
