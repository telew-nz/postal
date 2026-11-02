# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Endpoints", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }
  let(:organization) { create_organization(user) }
  let(:server) { create(:server, organization: organization) }

  def base
    "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}"
  end

  describe "HTTP endpoints" do
    let!(:endpoint) { create(:http_endpoint, server: server) }

    def path(suffix = "")
      "#{base}/http_endpoints#{suffix}"
    end

    it "lists the endpoints for the server" do
      create(:http_endpoint)

      get path, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_data.first).to include("uuid" => endpoint.uuid, "url" => endpoint.url, "encoding" => "BodyAsJSON", "format" => "Hash")
    end

    it "shows a single endpoint" do
      get path("/#{endpoint.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to include("uuid" => endpoint.uuid, "timeout" => endpoint.timeout)
    end

    it "creates an endpoint" do
      attributes = {
        name: "My Hook",
        url: "https://example.com/hook",
        encoding: "FormData",
        format: "RawMessage",
        strip_replies: true,
        include_attachments: false,
        timeout: 30
      }

      post path, headers: api_headers(token), params: attributes.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include(
        "name" => "My Hook",
        "url" => "https://example.com/hook",
        "encoding" => "FormData",
        "format" => "RawMessage",
        "strip_replies" => true,
        "include_attachments" => false,
        "timeout" => 30
      )
      expect(server.http_endpoints.find_by(name: "My Hook")).to be_present
    end

    it "validates the endpoint" do
      post path, headers: api_headers(token), params: { name: "My Hook", url: "ftp://example.com", encoding: "BodyAsJSON", format: "Hash" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
      expect(parsed_error["details"]).to be_an(Array)
    end

    it "updates an endpoint" do
      patch path("/#{endpoint.uuid}"), headers: api_headers(token), params: { name: "Renamed", timeout: 20 }.to_json

      expect(response.status).to eq(200)
      expect(parsed_data).to include("name" => "Renamed", "timeout" => 20)
      expect(endpoint.reload.name).to eq("Renamed")
    end

    it "destroys an endpoint" do
      delete path("/#{endpoint.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(204)
      expect(HTTPEndpoint.exists?(endpoint.id)).to be(false)
    end

    it "returns a 404 for an endpoint on another server" do
      get path("/#{create(:http_endpoint).uuid}"), headers: api_headers(token)

      expect(response.status).to eq(404)
    end
  end

  describe "SMTP endpoints" do
    let!(:endpoint) { create(:smtp_endpoint, server: server) }

    def path(suffix = "")
      "#{base}/smtp_endpoints#{suffix}"
    end

    it "lists the endpoints for the server" do
      get path, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.first).to include("uuid" => endpoint.uuid, "hostname" => "example.com", "port" => 25, "ssl_mode" => "None")
    end

    it "creates an endpoint" do
      post path, headers: api_headers(token), params: { name: "Remote", hostname: "mx.example.com", port: 587, ssl_mode: "STARTTLS" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include("name" => "Remote", "hostname" => "mx.example.com", "port" => 587, "ssl_mode" => "STARTTLS")
    end

    it "validates the endpoint" do
      post path, headers: api_headers(token), params: { name: "Remote", hostname: "mx.example.com", port: 25, ssl_mode: "Nonsense" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["details"].join(" ")).to include("SSL mode")
    end

    it "updates an endpoint" do
      patch path("/#{endpoint.uuid}"), headers: api_headers(token), params: { ssl_mode: "TLS" }.to_json

      expect(response.status).to eq(200)
      expect(endpoint.reload.ssl_mode).to eq("TLS")
    end

    it "destroys an endpoint" do
      delete path("/#{endpoint.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(204)
      expect(SMTPEndpoint.exists?(endpoint.id)).to be(false)
    end
  end

  describe "address endpoints" do
    let!(:endpoint) { create(:address_endpoint, server: server) }

    def path(suffix = "")
      "#{base}/address_endpoints#{suffix}"
    end

    it "lists the endpoints for the server" do
      get path, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.first).to include("uuid" => endpoint.uuid, "address" => endpoint.address)
    end

    it "creates an endpoint" do
      post path, headers: api_headers(token), params: { address: "someone@example.com" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include("address" => "someone@example.com")
    end

    it "validates the endpoint" do
      post path, headers: api_headers(token), params: { address: "not-an-address" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
    end

    it "rejects a duplicate address on the same server" do
      post path, headers: api_headers(token), params: { address: endpoint.address }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["details"].join(" ")).to include("has already been added")
    end

    it "updates an endpoint" do
      patch path("/#{endpoint.uuid}"), headers: api_headers(token), params: { address: "changed@example.com" }.to_json

      expect(response.status).to eq(200)
      expect(endpoint.reload.address).to eq("changed@example.com")
    end

    it "destroys an endpoint" do
      delete path("/#{endpoint.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(204)
      expect(AddressEndpoint.exists?(endpoint.id)).to be(false)
    end
  end
end
