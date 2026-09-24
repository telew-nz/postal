# frozen_string_literal: true

module API
  module V2
    class HTTPEndpointsController < BaseController

      include ScopedToServer

      before_action :load_http_endpoint, only: [:show, :update, :destroy]

      def index
        endpoints, pagination = paginate(server.http_endpoints.order(:name, :id))
        render_collection(HTTPEndpointSerializer.collection(endpoints), pagination)
      end

      def show
        render_data(HTTPEndpointSerializer.new(http_endpoint).as_json)
      end

      def create
        new_endpoint = server.http_endpoints.build(endpoint_params)
        if new_endpoint.save
          render_created(HTTPEndpointSerializer.new(new_endpoint).as_json)
        else
          render_validation_error(new_endpoint, "The HTTP endpoint could not be created.")
        end
      end

      def update
        if http_endpoint.update(endpoint_params)
          render_data(HTTPEndpointSerializer.new(http_endpoint).as_json)
        else
          render_validation_error(http_endpoint, "The HTTP endpoint could not be updated.")
        end
      end

      def destroy
        http_endpoint.destroy
        render_no_content
      end

      private

      def http_endpoint
        @http_endpoint ||= server.http_endpoints.find_by_uuid!(params[:uuid])
      end

      def load_http_endpoint
        http_endpoint
      end

      def endpoint_params
        resource_params(:name, :url, :encoding, :format, :strip_replies, :include_attachments, :timeout)
      end

    end
  end
end
