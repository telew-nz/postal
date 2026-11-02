# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Routes", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }
  let(:organization) { create_organization(user) }
  let(:server) { create(:server, organization: organization) }
  let(:domain) { create(:domain, owner: server) }

  def path(suffix = "")
    "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/routes#{suffix}"
  end

  describe "GET .../routes" do
    it "returns the routes for the server" do
      route = create(:route, server: server, domain: domain)
      create(:route, name: "other")

      get path, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_data.first).to include(
        "uuid" => route.uuid,
        "name" => "test",
        "description" => "test@#{domain.name}",
        "spam_mode" => "Mark",
        "endpoint" => "Accept",
        "domain_uuid" => domain.uuid
      )
    end
  end

  describe "GET .../routes/:uuid" do
    it "returns the route" do
      route = create(:route, server: server, domain: domain)

      get path("/#{route.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to include("uuid" => route.uuid, "token" => route.token)
      expect(parsed_data["forward_address"]).to eq("#{route.token}@#{Postal::Config.dns.route_domain}")
    end

    it "returns a 404 for a route on another server" do
      get path("/#{create(:route).uuid}"), headers: api_headers(token)

      expect(response.status).to eq(404)
    end
  end

  describe "POST .../routes" do
    it "creates a route which uses one of the built in modes" do
      post path, headers: api_headers(token), params: { name: "hello", domain_id: domain.id, spam_mode: "Mark", _endpoint: "Accept" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include("name" => "hello", "mode" => "Accept", "endpoint" => "Accept", "domain_uuid" => domain.uuid)
      expect(server.routes.find_by(name: "hello")).to be_present
    end

    it "creates a route which points at an endpoint using the string form" do
      endpoint = create(:http_endpoint, server: server)

      post path, headers: api_headers(token), params: { name: "hello", domain_id: domain.id, spam_mode: "Mark", _endpoint: "HTTPEndpoint##{endpoint.uuid}" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include("mode" => "Endpoint", "endpoint" => "HTTPEndpoint##{endpoint.uuid}")
    end

    it "creates a route which points at an endpoint using separate parameters" do
      endpoint = create(:smtp_endpoint, server: server)

      post path, headers: api_headers(token), params: { name: "hello", domain_id: domain.id, spam_mode: "Mark", endpoint_type: "SMTPEndpoint", endpoint_uuid: endpoint.uuid }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include("mode" => "Endpoint", "endpoint" => "SMTPEndpoint##{endpoint.uuid}")
    end

    it "creates a route with additional endpoints" do
      primary = create(:http_endpoint, server: server)
      additional = create(:smtp_endpoint, server: server)

      attributes = {
        name: "hello",
        domain_id: domain.id,
        spam_mode: "Mark",
        _endpoint: "HTTPEndpoint##{primary.uuid}",
        additional_route_endpoints_array: ["SMTPEndpoint##{additional.uuid}"]
      }

      post path, headers: api_headers(token), params: attributes.to_json

      expect(response.status).to eq(201)
      expect(parsed_data["additional_endpoints"]).to eq(["SMTPEndpoint##{additional.uuid}"])
    end

    it "returns a 422 when the endpoint class name is not valid" do
      post path, headers: api_headers(token), params: { name: "hello", domain_id: domain.id, spam_mode: "Mark", _endpoint: "Nonsense#1234" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("InvalidRequest")
    end

    it "validates the route" do
      post path, headers: api_headers(token), params: { name: "hello", domain_id: domain.id, spam_mode: "Nonsense", _endpoint: "Accept" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
      expect(parsed_error["details"]).to be_an(Array)
    end

    it "validates that a domain has been provided" do
      post path, headers: api_headers(token), params: { name: "hello", spam_mode: "Mark", _endpoint: "Accept" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
    end
  end

  describe "PATCH .../routes/:uuid" do
    let!(:route) { create(:route, server: server, domain: domain) }

    it "updates the route" do
      patch path("/#{route.uuid}"), headers: api_headers(token), params: { name: "changed", spam_mode: "Fail", _endpoint: "Hold" }.to_json

      expect(response.status).to eq(200)
      expect(parsed_data).to include("name" => "changed", "spam_mode" => "Fail", "mode" => "Hold")
      expect(route.reload.name).to eq("changed")
    end

    it "does not allow the route to be moved to another server" do
      other = create(:server)

      patch path("/#{route.uuid}"), headers: api_headers(token), params: { name: "changed", server_id: other.id }.to_json

      expect(response.status).to eq(200)
      expect(route.reload.server).to eq(server)
    end

    it "rejects a body which contains only attributes which cannot be written" do
      patch path("/#{route.uuid}"), headers: api_headers(token), params: { server_id: create(:server).id }.to_json

      expect(response.status).to eq(400)
      expect(parsed_error["code"]).to eq("ParameterMissing")
    end
  end

  describe "DELETE .../routes/:uuid" do
    it "destroys the route" do
      route = create(:route, server: server, domain: domain)

      delete path("/#{route.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(204)
      expect(Route.exists?(route.id)).to be(false)
    end
  end
end
