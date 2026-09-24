# frozen_string_literal: true

module API
  module V2
    # This concern provides the organization which the request is scoped to. It
    # is the API equivalent of the WithinOrganization concern used by the web
    # UI but it reads the organization from the :organization_permalink
    # parameter rather than :org_permalink.
    #
    # The organization is always looked up within the current user's
    # organizations scope which means a non-administrator can only ever access
    # organizations they belong to.
    module ScopedToOrganization

      extend ActiveSupport::Concern

      included do
        before_action :load_organization
      end

      private

      # The organization which this request is scoped to.
      #
      # @return [Organization]
      def organization
        @organization ||= current_user.organizations_scope.find_by_permalink!(params[:organization_permalink])
      end

      # Load the organization before the action runs so that requests for an
      # organization which does not exist (or which the user cannot access) fail
      # early with a 404.
      #
      # @return [Organization]
      def load_organization
        organization
      end

    end
  end
end
