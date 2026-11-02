# frozen_string_literal: true

module API
  module V2
    class SMTPEndpointsController < BaseController

      include ScopedToServer

      before_action :load_smtp_endpoint, only: [:show, :update, :destroy]

      def index
        endpoints, pagination = paginate(server.smtp_endpoints.order(:name, :id))
        render_collection(SMTPEndpointSerializer.collection(endpoints), pagination)
      end

      def show
        render_data(SMTPEndpointSerializer.new(smtp_endpoint).as_json)
      end

      def create
        new_endpoint = server.smtp_endpoints.build(endpoint_params)
        if new_endpoint.save
          render_created(SMTPEndpointSerializer.new(new_endpoint).as_json)
        else
          render_validation_error(new_endpoint, "The SMTP endpoint could not be created.")
        end
      end

      def update
        if smtp_endpoint.update(endpoint_params)
          render_data(SMTPEndpointSerializer.new(smtp_endpoint).as_json)
        else
          render_validation_error(smtp_endpoint, "The SMTP endpoint could not be updated.")
        end
      end

      def destroy
        smtp_endpoint.destroy
        render_no_content
      end

      private

      def smtp_endpoint
        @smtp_endpoint ||= server.smtp_endpoints.find_by_uuid!(params[:uuid])
      end

      def load_smtp_endpoint
        smtp_endpoint
      end

      def endpoint_params
        resource_params(:name, :hostname, :port, :ssl_mode)
      end

    end
  end
end
