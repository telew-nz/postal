# frozen_string_literal: true

module API
  module V2
    # Allows a user to manage their own API tokens. The plaintext token is only
    # ever returned by the create action because only the hash of it is stored.
    class TokensController < BaseController

      def index
        tokens, pagination = paginate(current_user.api_tokens.order(created_at: :desc, id: :desc))
        render_collection(UserAPITokenSerializer.collection(tokens), pagination)
      end

      def create
        token = current_user.api_tokens.build
        token.name = params.require(:name)
        if params[:expires_at].present?
          expires = parse_expires_at
          if expires.nil?
            render_error(:unprocessable_entity, "ValidationError", "The API token could not be created.", ["Expires at is not a valid date/time"])
            return
          end
          token.expires_at = expires
        end

        if token.save
          render_created(UserAPITokenSerializer.new(token, include_plain_key: true).as_json)
        else
          render_validation_error(token, "The API token could not be created.")
        end
      end

      def destroy
        current_user.api_tokens.find_by_uuid!(params[:id]).revoke!
        render_no_content
      end

      private

      # Parse the expiry provided by the client. This accepts any format which
      # Ruby's time parser understands although ISO 8601 is what the API
      # documents.
      #
      # @return [ActiveSupport::TimeWithZone, nil]
      def parse_expires_at
        Time.zone.parse(params[:expires_at].to_s)
      rescue ArgumentError, TypeError
        nil
      end

    end
  end
end
