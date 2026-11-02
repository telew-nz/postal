# frozen_string_literal: true

module API
  module V2
    # This concern provides the mail server which the request is scoped to. It
    # builds on ScopedToOrganization because servers always live within an
    # organization.
    module ScopedToServer

      extend ActiveSupport::Concern

      include ScopedToOrganization

      included do
        before_action :load_server
      end

      private

      # The mail server which this request is scoped to.
      #
      # @return [Server]
      def server
        @server ||= organization.servers.present.find_by_permalink!(params[:server_permalink])
      end

      # Load the server before the action runs so that requests for a server
      # which does not exist fail early with a 404.
      #
      # @return [Server]
      def load_server
        server
      end

    end
  end
end
