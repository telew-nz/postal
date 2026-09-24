# frozen_string_literal: true

module API
  module V2
    # Serves the OpenAPI specification for this API. This is not authenticated
    # because clients need to be able to read the specification before they have
    # a token, in the same way that the well known endpoints are public.
    class SpecController < BaseController

      skip_before_action :authenticate_api_token

      SPECIFICATION_PATH = "doc/api/openapi.yaml"

      # The document is written by hand so it may contain YAML timestamps in
      # examples. These classes must be permitted for the document to be parsed
      # without falling back to an unsafe load.
      PERMITTED_CLASSES = [Date, Time].freeze

      def show
        path = Rails.root.join(SPECIFICATION_PATH)
        unless File.exist?(path)
          render_error(:not_found, "NotFound", "The OpenAPI specification is not available on this installation.")
          return
        end

        contents = File.read(path)
        if yaml_requested?
          render plain: contents, content_type: "application/yaml"
        else
          render json: YAML.safe_load(contents, permitted_classes: PERMITTED_CLASSES, aliases: true)
        end
      end

      private

      # The specification is a YAML document but the rest of this API speaks
      # JSON so JSON is the default. Clients which want the document as it is
      # written can ask for it using the .yaml extension or an Accept header.
      #
      # @return [Boolean]
      def yaml_requested?
        return true if params[:format] == "yaml"

        request.headers["Accept"].to_s.include?("yaml")
      end

    end
  end
end
