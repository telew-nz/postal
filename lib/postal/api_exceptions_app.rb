# frozen_string_literal: true

require "json"

module Postal
  # Renders errors which never reach one of the management API's controllers
  # using the same JSON envelope that API::V2::BaseController uses.
  #
  # Rails' default exceptions app answers with an HTML page. That is fine for the
  # web UI but not for a JSON API: a path such as
  # `/api/v2/organizations/acme/domains/0.5/dns_records` does not match any route
  # because Rails reads `.5` as a format extension, and the resulting
  # ActionController::RoutingError is rendered as HTML. A client which follows
  # doc/api/openapi.yaml has no way to parse that.
  #
  # Anything which is not beneath the API prefix is passed through to the
  # application's normal error rendering untouched.
  class APIExceptionsApp

    # The prefix which the management API is mounted at. This is deliberately a
    # constant rather than something derived from the router so that it still
    # works when the router is the thing which failed.
    PREFIX = "/api/v2"

    # Matching on PREFIX alone would also claim paths such as "/api/v20/...",
    # so anything below the API has to continue with a separator.
    NESTED_PREFIX = "#{PREFIX}/".freeze

    # The error codes used for the statuses which Rails generates itself. Every
    # other status falls back to one of the two defaults below.
    CODES = {
      404 => "NotFound",
      405 => "MethodNotAllowed",
      406 => "NotAcceptable",
      422 => "InvalidRequest",
      501 => "NotImplemented"
    }.freeze

    DEFAULT_CLIENT_CODE = "RequestFailed"
    DEFAULT_SERVER_CODE = "ServerError"

    def initialize(fallback = nil)
      @fallback = fallback
    end

    # @param [Hash] env the Rack environment for the failed request
    # @return [Array] a Rack response
    def call(env)
      return fallback.call(env) unless api_request?(env)

      # Rendering must never raise, otherwise the client gets a connection reset
      # instead of an explanation. Anything unexpected is left to the fallback.
      respond(env)
    rescue StandardError
      fallback.call(env)
    end

    private

    # The app which handles everything this one declines to. It is built on
    # first use because Rails.public_path is not available while the application
    # is still being configured, which is when this class is instantiated.
    #
    # @return [#call]
    def fallback
      @fallback ||= ActionDispatch::PublicExceptions.new(Rails.public_path)
    end

    # Whether the request was addressed to the management API.
    #
    # ActionDispatch::ShowExceptions rewrites PATH_INFO to "/<status>" before it
    # calls the exceptions app so that the fallback can serve the matching static
    # page, and records the path the client actually asked for in
    # action_dispatch.original_path. That is therefore the header to look at,
    # with PATH_INFO kept as a fallback for callers which set it directly.
    #
    # @param [Hash] env
    # @return [Boolean]
    def api_request?(env)
      path = (env["action_dispatch.original_path"] || env["PATH_INFO"]).to_s
      path == PREFIX || path.start_with?(NESTED_PREFIX)
    end

    # Build the JSON error response for the exception which Rails caught.
    #
    # @param [Hash] env
    # @return [Array] a Rack response
    def respond(env)
      exception = env["action_dispatch.exception"]
      status = status_for(exception)
      body = JSON.generate({ error: { code: code_for(status), message: message_for(exception, status) } })

      [status, { "Content-Type" => "application/json; charset=utf-8", "Content-Length" => body.bytesize.to_s }, [body]]
    end

    # The status code which Rails would have used for the exception.
    #
    # @param [Exception, nil] exception
    # @return [Integer]
    def status_for(exception)
      return 404 if exception.nil?

      ActionDispatch::ExceptionWrapper.status_code_for_exception(exception.class.name)
    end

    # @param [Integer] status
    # @return [String]
    def code_for(status)
      return CODES[status] if CODES.key?(status)

      status >= 500 ? DEFAULT_SERVER_CODE : DEFAULT_CLIENT_CODE
    end

    # @param [Exception, nil] exception
    # @param [Integer] status
    # @return [String]
    def message_for(exception, status)
      message = exception&.message
      return message if message.present?

      Rack::Utils::HTTP_STATUS_CODES[status].to_s
    end

  end
end
