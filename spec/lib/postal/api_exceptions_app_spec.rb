# frozen_string_literal: true

require "rails_helper"

# The management API promises a JSON error envelope for every response it
# documents. Errors which never reach a controller are rendered by
# config.exceptions_app instead, and without this they come back as Rails' HTML
# error page which an API client cannot parse.
#
# These examples call the app directly because the test environment sets
# config.action_dispatch.show_exceptions to false, so exceptions propagate
# through a request spec rather than being rendered.
RSpec.describe Postal::APIExceptionsApp do
  let(:fallback_response) { [404, { "Content-Type" => "text/html" }, ["<html>fallback</html>"]] }
  let(:fallback) { -> (_env) { fallback_response } }
  let(:app) { described_class.new(fallback) }

  # Build the Rack environment which ActionDispatch::ShowExceptions hands to
  # config.exceptions_app. By that point PATH_INFO has already been rewritten to
  # the status code so that the fallback can serve the matching static page, so
  # the path the client actually asked for is only in original_path.
  #
  # @param [String] path the path the client requested
  # @param [Exception, nil] exception
  # @param [Integer] status the status Rails derived from the exception
  # @return [Hash]
  def env_for(path, exception: nil, status: 404)
    {
      "PATH_INFO" => "/#{status}",
      "REQUEST_METHOD" => "GET",
      "action_dispatch.original_path" => path,
      "action_dispatch.exception" => exception
    }
  end

  # Decode the JSON body of a Rack response.
  #
  # @param [Array] response
  # @return [Hash]
  def parsed(response)
    JSON.parse(response[2].first)
  end

  describe "requests which are not addressed to the management API" do
    it "leaves them to the application's normal error rendering" do
      expect(app.call(env_for("/organizations/acme"))).to eq(fallback_response)
    end

    it "does not treat a path which merely starts with the same letters as the API" do
      expect(app.call(env_for("/api/v20/servers"))).to eq(fallback_response)
    end
  end

  describe "requests addressed to the management API" do
    # ShowExceptions rewrites PATH_INFO to "/404" before calling the exceptions
    # app, so matching on that header would miss every request.
    it "recognises the API from the original path rather than the rewritten one" do
      env = env_for("/api/v2/organizations/acme/domains/0.5/dns_records",
                    exception: ActionController::RoutingError.new("No route matches"))

      expect(env["PATH_INFO"]).to eq("/404")
      status, headers, = app.call(env)

      expect(status).to eq(404)
      expect(headers["Content-Type"]).to eq("application/json; charset=utf-8")
    end

    it "renders a routing error using the API's error envelope" do
      exception = ActionController::RoutingError.new('No route matches [GET] "/api/v2/nonsense"')

      status, headers, = app.call(env_for("/api/v2/nonsense", exception: exception))

      expect(status).to eq(404)
      expect(headers["Content-Type"]).to eq("application/json; charset=utf-8")
    end

    it "uses the same error code that the API's controllers use for a missing record" do
      exception = ActionController::RoutingError.new("No route matches")

      body = parsed(app.call(env_for("/api/v2/nonsense", exception: exception)))

      expect(body["error"]["code"]).to eq("NotFound")
      expect(body["error"]["message"]).to eq("No route matches")
    end

    it "sets a Content-Length which matches the body it returns" do
      exception = ActionController::RoutingError.new("No route matches")

      status, headers, body = app.call(env_for("/api/v2/nonsense", exception: exception))

      expect(status).to eq(404)
      expect(headers["Content-Length"]).to eq(body.first.bytesize.to_s)
    end

    it "maps a record which cannot be found to a 404" do
      exception = ActiveRecord::RecordNotFound.new("Couldn't find Domain")

      status, = app.call(env_for("/api/v2/organizations/acme/domains/1", exception: exception))
      body = parsed(app.call(env_for("/api/v2/organizations/acme/domains/1", exception: exception)))

      expect(status).to eq(404)
      expect(body["error"]).to include("code" => "NotFound", "message" => "Couldn't find Domain")
    end

    it "maps an exception which has no registered status to a server error" do
      env = env_for("/api/v2/me", exception: RuntimeError.new("boom"), status: 500)

      status, = app.call(env)
      body = parsed(app.call(env))

      expect(status).to eq(500)
      expect(body["error"]).to include("code" => "ServerError", "message" => "boom")
    end

    it "assumes a 404 when Rails did not record an exception" do
      status, = app.call(env_for("/api/v2/me"))

      expect(status).to eq(404)
      expect(parsed(app.call(env_for("/api/v2/me")))["error"]["code"]).to eq("NotFound")
    end

    it "falls back rather than raising when it cannot render the error" do
      exception = Class.new(StandardError) do
        def message
          raise "cannot describe myself"
        end
      end.new

      expect(app.call(env_for("/api/v2/me", exception: exception))).to eq(fallback_response)
    end
  end

  describe "when no fallback is supplied" do
    # Rails.public_path is not available while the application is being
    # configured, which is when this class is instantiated, so the default
    # fallback has to be built lazily rather than in the constructor.
    it "still renders API errors without touching the public directory" do
      status, headers, = described_class.new.call(env_for("/api/v2/nonsense", exception: ActionController::RoutingError.new("No route")))

      expect(status).to eq(404)
      expect(headers["Content-Type"]).to eq("application/json; charset=utf-8")
    end

    it "builds the default fallback lazily so that a non-API request still works" do
      expect { described_class.new.call(env_for("/organizations/acme")) }.not_to raise_error
    end
  end
end
