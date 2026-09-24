# frozen_string_literal: true

module API
  module V2
    class AddressEndpointsController < BaseController

      include ScopedToServer

      before_action :load_address_endpoint, only: [:show, :update, :destroy]

      def index
        endpoints, pagination = paginate(server.address_endpoints.order(:address, :id))
        render_collection(AddressEndpointSerializer.collection(endpoints), pagination)
      end

      def show
        render_data(AddressEndpointSerializer.new(address_endpoint).as_json)
      end

      def create
        new_endpoint = server.address_endpoints.build(endpoint_params)
        if new_endpoint.save
          render_created(AddressEndpointSerializer.new(new_endpoint).as_json)
        else
          render_validation_error(new_endpoint, "The address endpoint could not be created.")
        end
      end

      def update
        if address_endpoint.update(endpoint_params)
          render_data(AddressEndpointSerializer.new(address_endpoint).as_json)
        else
          render_validation_error(address_endpoint, "The address endpoint could not be updated.")
        end
      end

      def destroy
        address_endpoint.destroy
        render_no_content
      end

      private

      def address_endpoint
        @address_endpoint ||= server.address_endpoints.find_by_uuid!(params[:uuid])
      end

      def load_address_endpoint
        address_endpoint
      end

      def endpoint_params
        resource_params(:address)
      end

    end
  end
end
