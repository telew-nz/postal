# frozen_string_literal: true

module API
  module V2
    # Routes determine what happens to incoming messages. The endpoint for a route
    # is stored internally as a string in the form "HTTPEndpoint#<uuid>" or as
    # one of the built in modes (Accept, Hold, Bounce, Reject). Clients can
    # provide that string directly or as separate endpoint_type and
    # endpoint_uuid parameters.
    class RoutesController < BaseController

      include ScopedToServer

      before_action :load_route, only: [:show, :update, :destroy]

      def index
        routes, pagination = paginate(server.routes.order(:name, :id).includes(:domain, :endpoint, :additional_route_endpoints))
        render_collection(RouteSerializer.collection(routes), pagination)
      end

      def show
        render_data(RouteSerializer.new(route).as_json)
      end

      def create
        new_route = server.routes.build(route_attributes)
        if new_route.save
          render_created(RouteSerializer.new(new_route).as_json)
        else
          render_validation_error(new_route, "The route could not be created.")
        end
      end

      def update
        if route.update(route_attributes)
          render_data(RouteSerializer.new(route).as_json)
        else
          render_validation_error(route, "The route could not be updated.")
        end
      end

      def destroy
        route.destroy
        render_no_content
      end

      private

      def route
        @route ||= server.routes.find_by_uuid!(params[:uuid])
      end

      def load_route
        route
      end

      # The attributes which should be assigned to a route. This mirrors the
      # permitted parameters in the web UI's RoutesController but also accepts
      # the endpoint as a pair of separate parameters.
      #
      # The keys here are strings because ActionController::Parameters#to_h always
      # returns string keys.
      #
      # @return [Hash]
      def route_attributes
        attributes = resource_params(
          :name, :domain_id, :spam_mode, :_endpoint, :endpoint_type, :endpoint_uuid,
          { additional_route_endpoints: [], additional_route_endpoints_array: [] }
        ).to_h

        # Route#additional_route_endpoints_array= cannot be given nil so the
        # attribute is only assigned when the client actually provided one.
        additional = attributes.delete("additional_route_endpoints_array") || attributes.delete("additional_route_endpoints")
        attributes["additional_route_endpoints_array"] = additional if additional.present?

        endpoint_type = attributes.delete("endpoint_type")
        endpoint_uuid = attributes.delete("endpoint_uuid")
        attributes["_endpoint"] = "#{endpoint_type}##{endpoint_uuid}" if attributes["_endpoint"].blank? && endpoint_type.present?

        attributes
      end

    end
  end
end
