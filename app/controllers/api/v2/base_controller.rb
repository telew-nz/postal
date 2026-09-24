# frozen_string_literal: true

module API
  module V2
    # This is the base controller for the Postal management API. It provides a
    # JSON API which allows almost everything that the web UI allows to be
    # managed over HTTP.
    #
    # Important things to note about this API:
    #
    #   * Authentication is performed using an API token belonging to a user.
    #     The token is provided in the X-Postal-API-Key header. The token is
    #     resolved to a user which means all the existing authorization logic
    #     (admin checks, organization scoping) can be reused as-is.
    #
    #   * There are no sessions or cookies. Requests must be self contained
    #     which means all the Authie session behaviour inherited from
    #     ApplicationController has to be bypassed.
    #
    #   * Responses use standard HTTP status codes. Successful responses have a
    #     'data' key and error responses have an 'error' key. This deliberately
    #     differs from the legacy API which always returns 200 OK and puts the
    #     status of the request in the response body.
    #
    #   * All timestamps are rendered as ISO 8601 strings in UTC regardless of
    #     the time zone configured for the authenticated user.
    class BaseController < ApplicationController

      layout false

      # Rails wraps JSON request bodies into a key named after the controller and
      # only includes attributes which exist on the corresponding database table.
      # That silently discards virtual attributes such as Route#_endpoint so the
      # wrapping is disabled here. Clients may still nest their parameters under
      # the resource name explicitly, which resource_params supports.
      wrap_parameters false

      skip_before_action :verify_authenticity_token
      skip_before_action :set_browser_id
      skip_before_action :login_required
      skip_before_action :set_timezone

      before_action :check_api_enabled
      before_action :authenticate_api_token
      before_action :set_utc_timezone

      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found_error
      rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid_error
      rescue_from ActionController::ParameterMissing, with: :render_parameter_missing_error
      rescue_from Postal::Error, with: :render_postal_error

      # This must be declared after the Postal::Error handler above because it is
      # a subclass of it and rescue_from searches the handlers in reverse order.
      rescue_from Postal::MessageDB::Message::NotFound, with: :render_not_found_error

      # The token which authenticated this request.
      #
      # @return [UserAPIToken, nil]
      attr_reader :current_api_token

      # Override the Authie provided method so that the rest of the application
      # (including the authorization helpers below) sees the user who owns the
      # API token rather than trying to load a session.
      #
      # @return [User, nil]
      def current_user
        @current_api_token&.user
      end

      # Override the Authie provided method so that nothing in the request
      # lifecycle attempts to read or validate a session cookie.
      #
      # @return [Boolean]
      def logged_in?
        @current_api_token.present?
      end

      private

      # The header which carries the API token. This is named after the
      # X-Server-API-Key header used by the legacy API.
      API_TOKEN_HEADER = "X-Postal-API-Key"

      # The number of records returned in a page when the client does not ask
      # for a specific number.
      DEFAULT_PER_PAGE = 50

      # Ensure the management API has been enabled in the configuration. This
      # allows an installation to completely disable this functionality.
      #
      # @return [void]
      def check_api_enabled
        return if Postal::Config.api.enabled?

        render_error(:forbidden, "APIDisabled", "The Postal management API is not enabled on this installation.")
      end

      # Authenticate the request using the API token provided in the request
      # headers. If the token is missing or invalid an error is rendered which
      # halts the filter chain.
      #
      # @return [void]
      def authenticate_api_token
        key = request.headers[API_TOKEN_HEADER]
        if key.blank?
          render_error(:unauthorized, "MissingAPIKey", "An API token must be provided in the #{API_TOKEN_HEADER} header.")
          return
        end

        token = UserAPIToken.authenticate(key)
        if token.nil?
          render_error(:unauthorized, "InvalidAPIKey", "The API token provided was not valid, has expired or has been revoked.")
          return
        end

        token.use
        @current_api_token = token
      end

      # The management API always renders times in UTC so that responses are
      # predictable regardless of who is asking for them.
      #
      # @return [void]
      def set_utc_timezone
        Time.zone = "UTC"
      end

      # Return the parameters which are relevant to the current resource.
      #
      # These are read from the request body rather than from params. params also
      # contains routing defaults and query string parameters, and this API is
      # mounted with a default format of json which would otherwise clobber an
      # attribute such as HTTPEndpoint#format.
      #
      # A client may send a flat JSON body (which is what the API documents) or
      # nest it under the name of the resource. Either way the result is the
      # same.
      #
      # @param [Array<Symbol>] permitted the attributes which may be provided
      # @return [ActionController::Parameters]
      def resource_params(*permitted)
        key = controller_name.singularize
        body = request.request_parameters
        source = body[key].is_a?(Hash) ? body[key] : body
        result = ActionController::Parameters.new(source).permit(*permitted)
        raise ActionController::ParameterMissing, key if result.empty? && permitted.any?

        result
      end

      # Render a JSON error rather than the plain text response which the web
      # UI returns when an administrator is required.
      #
      # @return [void]
      def admin_required
        return if logged_in? && current_user.admin?

        render_error(:forbidden, "NotPermitted", "You must be an administrator to perform this action.")
      end

      # As above, for actions which can only be performed by the owner of an
      # organization.
      #
      # @return [void]
      def require_organization_owner
        return if organization.owner == current_user

        render_error(:forbidden, "NotPermitted", "This action can only be performed by the owner of the organization.")
      end

      # Render a successful response containing a single object.
      #
      # @param [Object] data
      # @param [Symbol, Integer] status
      # @return [void]
      def render_data(data, status: :ok)
        render json: { data: data }, status: status
      end

      # Render a successful response created by a create action.
      #
      # @param [Object] data
      # @return [void]
      def render_created(data)
        render_data(data, status: :created)
      end

      # Render a successful response containing a collection of objects along
      # with the pagination information for that collection.
      #
      # @param [Array<Object>] data
      # @param [Hash, nil] pagination
      # @return [void]
      def render_collection(data, pagination = nil)
        body = { data: data }
        body[:pagination] = pagination if pagination
        render json: body
      end

      # Render an empty successful response for actions which have removed
      # something.
      #
      # @return [void]
      def render_no_content
        head :no_content
      end

      # Render an error response.
      #
      # @param [Symbol, Integer] status the HTTP status code
      # @param [String] code a machine readable error code
      # @param [String] message a human readable description of the error
      # @param [Array<String>, nil] details additional information about the error
      # @return [void]
      def render_error(status, code, message, details = nil)
        error = { code: code, message: message }
        error[:details] = details if details.present?
        render json: { error: error }, status: status
      end

      # Render an error response for a record which failed validation.
      #
      # @param [ActiveRecord::Base] record
      # @param [String] message
      # @return [void]
      def render_validation_error(record, message = "The data provided could not be validated.")
        render_error(:unprocessable_entity, "ValidationError", message, record.errors.map(&:full_message))
      end

      def render_not_found_error(exception)
        render_error(:not_found, "NotFound", exception.message)
      end

      def render_record_invalid_error(exception)
        record = exception.record
        render_validation_error(record, "The data provided could not be saved.")
      end

      def render_parameter_missing_error(exception)
        render_error(:bad_request, "ParameterMissing", exception.message)
      end

      def render_postal_error(exception)
        render_error(:unprocessable_entity, "InvalidRequest", exception.message)
      end

      # The page number which has been requested by the client. Pages start at 1
      # and any value below that is treated as the first page.
      #
      # @return [Integer]
      def pagination_page
        page = params[:page].to_i
        [page, 1].max
      end

      # The number of records per page which has been requested by the client.
      # This is capped using the maximum configured for the installation.
      #
      # @return [Integer]
      def pagination_per_page
        per_page = params[:per_page].to_i
        per_page = DEFAULT_PER_PAGE if per_page < 1

        maximum = Postal::Config.api.max_per_page
        [per_page, maximum].min
      end

      # Paginate an Active Record relation using the pagination parameters
      # provided by the client.
      #
      # @param [ActiveRecord::Relation] scope
      # @return [Array(ActiveRecord::Relation, Hash)] the paginated relation and its metadata
      def paginate(scope)
        relation = scope.page(pagination_page).per(pagination_per_page)
        [relation, pagination_for(relation)]
      end

      # Build the standard pagination object for a Kaminari paginated relation.
      #
      # @param [ActiveRecord::Relation] relation
      # @return [Hash]
      def pagination_for(relation)
        {
          page: relation.current_page,
          per_page: relation.limit_value,
          total: relation.total_count,
          total_pages: relation.total_pages
        }
      end

      # Build the standard pagination object from a result returned by the
      # message database, which uses its own pagination structure.
      #
      # @param [Hash] result
      # @param [Integer] page
      # @return [Hash]
      def message_db_pagination_for(result, page)
        {
          page: page,
          per_page: result[:per_page],
          total: result[:total],
          total_pages: result[:total_pages]
        }
      end

    end
  end
end
