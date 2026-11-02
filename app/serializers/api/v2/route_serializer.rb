# frozen_string_literal: true

module API
  module V2
    class RouteSerializer < BaseSerializer

      def as_json(*)
        {
          uuid: record.uuid,
          name: record.name,
          description: record.description,
          wildcard: record.wildcard?,
          return_path: record.return_path?,
          domain_uuid: record.domain&.uuid,
          spam_mode: record.spam_mode,
          mode: record.mode,
          token: record.token,
          # The endpoint is rendered in the same "ClassName#uuid" format which
          # the model uses internally and which can be sent back when updating
          # a route. For non-endpoint routes this is the mode.
          endpoint: record._endpoint,
          additional_endpoints: record.additional_route_endpoints_array,
          forward_address: record.forward_address,
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }
      end

    end
  end
end
