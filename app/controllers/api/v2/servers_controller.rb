# frozen_string_literal: true

module API
  module V2
    class ServersController < BaseController

      include ScopedToServer

      skip_before_action :load_server, only: [:index, :create]

      before_action :admin_required, only: [:suspend, :unsuspend]

      def index
        servers, pagination = paginate(organization.servers.present.order(:name, :id))
        render_collection(ServerSerializer.collection(servers), pagination)
      end

      def show
        render_data(ServerSerializer.new(server).as_json)
      end

      def create
        new_server = organization.servers.build(resource_params(:name, :mode, :ip_pool_id))
        if new_server.save
          render_created(ServerSerializer.new(new_server).as_json)
        else
          render_validation_error(new_server, "The server could not be created.")
        end
      end

      def update
        if server.update(resource_params(*permitted_update_attributes))
          render_data(ServerSerializer.new(server).as_json)
        else
          render_validation_error(server, "The server could not be updated.")
        end
      end

      def destroy
        unless params[:confirm_text].present? && params[:confirm_text].to_s.downcase.strip == server.name.to_s.downcase.strip
          render_error(:unprocessable_entity, "ValidationError", "The server could not be deleted.", ["Confirm text does not match the server name"])
          return
        end

        server.soft_destroy
        render_no_content
      end

      def suspend
        server.suspend(params[:reason])
        render_data(ServerSerializer.new(server).as_json)
      end

      def unsuspend
        server.unsuspend
        render_data(ServerSerializer.new(server).as_json)
      end

      # The messages which are waiting to be delivered. This is the API
      # equivalent of the queue page in the web UI.
      def queue
        messages, pagination = paginate(server.queued_messages.order(id: :desc).includes(:ip_address))
        render_collection(QueuedMessageSerializer.collection(messages), pagination)
      end

      private

      # The attributes which may be updated. Administrators are able to change
      # the limits, retention and advanced settings as well. This mirrors the
      # permitted parameters in the web UI's ServersController.
      #
      # @return [Array<Symbol>]
      def permitted_update_attributes
        attributes = [:name, :mode, :ip_pool_id, :spam_threshold, :spam_failure_threshold, :postmaster_address]
        if current_user.admin?
          attributes += [
            :send_limit,
            :allow_sender,
            :privacy_mode,
            :log_smtp_data,
            :outbound_spam_threshold,
            :message_retention_days,
            :raw_message_retention_days,
            :raw_message_retention_size,
          ]
        end
        attributes
      end

    end
  end
end
