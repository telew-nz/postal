# frozen_string_literal: true

module API
  module V2
    # Credentials are the SMTP and API keys which allow messages to be sent
    # through a server. The key is required by clients in order to actually send
    # mail so it is returned by the show and create actions. It is omitted from
    # index responses so that listing credentials does not needlessly expose
    # every key.
    class CredentialsController < BaseController

      include ScopedToServer

      before_action :load_credential, only: [:show, :update, :destroy]

      def index
        credentials, pagination = paginate(server.credentials.order(:name, :id))
        render_collection(CredentialSerializer.collection(credentials, redact_key: true), pagination)
      end

      def show
        render_data(CredentialSerializer.new(credential).as_json)
      end

      def create
        new_credential = server.credentials.build(resource_params(:type, :name, :key, :hold))
        if new_credential.save
          render_created(CredentialSerializer.new(new_credential).as_json)
        else
          render_validation_error(new_credential, "The credential could not be created.")
        end
      end

      def update
        if credential.update(resource_params(:name, :key, :hold))
          render_data(CredentialSerializer.new(credential).as_json)
        else
          render_validation_error(credential, "The credential could not be updated.")
        end
      end

      def destroy
        credential.destroy
        render_no_content
      end

      private

      def credential
        @credential ||= server.credentials.find_by_uuid!(params[:uuid])
      end

      def load_credential
        credential
      end

    end
  end
end
