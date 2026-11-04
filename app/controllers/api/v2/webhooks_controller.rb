# frozen_string_literal: true

module API
  module V2
    # Webhooks notify a web application when events occur in the lifecycle of a
    # mail server (message delivered, bounced, held, and so on). They are scoped
    # to a server, like routes and endpoints.
    class WebhooksController < BaseController

      include ScopedToServer

      before_action :load_webhook, only: [:show, :update, :destroy]

      def index
        webhooks, pagination = paginate(server.webhooks.order(:url, :id))
        render_collection(WebhookSerializer.collection(webhooks), pagination)
      end

      def show
        render_data(WebhookSerializer.new(webhook).as_json)
      end

      def create
        new_webhook = server.webhooks.build(resource_params(:name, :url, :all_events, :enabled, :events))
        if new_webhook.save
          render_created(WebhookSerializer.new(new_webhook).as_json)
        else
          render_validation_error(new_webhook, "The webhook could not be created.")
        end
      end

      def update
        if webhook.update(resource_params(:name, :url, :all_events, :enabled, :events))
          render_data(WebhookSerializer.new(webhook).as_json)
        else
          render_validation_error(webhook, "The webhook could not be updated.")
        end
      end

      def destroy
        webhook.destroy
        render_no_content
      end

      private

      def webhook
        @webhook ||= server.webhooks.find_by_uuid!(params[:uuid])
      end

      def load_webhook
        webhook
      end

    end
  end
end
