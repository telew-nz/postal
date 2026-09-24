# frozen_string_literal: true

module API
  module V2
    class AddressEndpointSerializer < BaseSerializer

      def as_json(*)
        {
          uuid: record.uuid,
          address: record.address,
          last_used_at: iso8601(record.last_used_at),
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }
      end

    end
  end
end
