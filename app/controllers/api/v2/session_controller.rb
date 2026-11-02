# frozen_string_literal: true

module API
  module V2
    # Provides information about the user who owns the API token which was used
    # to authenticate the request. This allows a client to verify that a token
    # is valid and to discover the organizations which it can address.
    class SessionController < BaseController

      def show
        render_data({
          user: {
            uuid: current_user.uuid,
            name: current_user.name,
            email_address: current_user.email_address,
            admin: current_user.admin?,
            time_zone: current_user.time_zone
          },
          token: {
            uuid: current_api_token.uuid,
            name: current_api_token.name,
            expires_at: current_api_token.expires_at&.utc&.iso8601
          },
          organizations: current_user.organizations_scope.order(:name).map do |organization|
            {
              permalink: organization.permalink,
              name: organization.name
            }
          end
        })
      end

    end
  end
end
