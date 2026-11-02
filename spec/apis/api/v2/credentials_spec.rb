# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Credentials", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }
  let(:organization) { create_organization(user) }
  let(:server) { create(:server, organization: organization) }
  let!(:credential) { create(:credential, server: server) }

  def path(suffix = "")
    "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/credentials#{suffix}"
  end

  describe "GET .../credentials" do
    it "returns the credentials for the server without their keys" do
      create(:credential)

      get path, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_data.first).to include("uuid" => credential.uuid, "name" => credential.name, "type" => "API", "usage_type" => "Unused")
      expect(parsed_data.first).not_to have_key("key")
      expect(response.body).not_to include(credential.key)
    end
  end

  describe "GET .../credentials/:uuid" do
    it "returns the credential including its key" do
      get path("/#{credential.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to include("uuid" => credential.uuid, "key" => credential.key)
    end

    it "returns a 404 for a credential on another server" do
      get path("/#{create(:credential).uuid}"), headers: api_headers(token)

      expect(response.status).to eq(404)
    end
  end

  describe "POST .../credentials" do
    it "creates a credential and returns its generated key" do
      post path, headers: api_headers(token), params: { type: "SMTP", name: "SMTP Credential", hold: true }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include("type" => "SMTP", "name" => "SMTP Credential", "hold" => true)
      expect(parsed_data["key"]).to be_present

      created = server.credentials.find_by(name: "SMTP Credential")
      expect(created.key).to eq(parsed_data["key"])
    end

    it "creates an SMTP-IP credential with the key which was provided" do
      post path, headers: api_headers(token), params: { type: "SMTP-IP", name: "IP Credential", key: "10.0.0.1" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include("type" => "SMTP-IP", "key" => "10.0.0.1")
    end

    it "validates the credential" do
      post path, headers: api_headers(token), params: { type: "Nonsense", name: "Bad" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
      expect(parsed_error["details"]).to be_an(Array)
    end

    it "validates the key of an SMTP-IP credential" do
      post path, headers: api_headers(token), params: { type: "SMTP-IP", name: "Bad", key: "not-an-ip" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["details"].join(" ")).to include("valid IPv4 or IPv6 address")
    end
  end

  describe "PATCH .../credentials/:uuid" do
    it "updates the name and the hold state" do
      patch path("/#{credential.uuid}"), headers: api_headers(token), params: { name: "Renamed", hold: true }.to_json

      expect(response.status).to eq(200)
      expect(parsed_data).to include("name" => "Renamed", "hold" => true)
      expect(credential.reload.name).to eq("Renamed")
    end

    it "does not allow the key of an API credential to be changed" do
      patch path("/#{credential.uuid}"), headers: api_headers(token), params: { name: credential.name, key: "somethingelse" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
      expect(credential.reload.key).not_to eq("somethingelse")
    end

    it "allows the key of an SMTP-IP credential to be changed" do
      ip_credential = create(:credential, server: server, type: "SMTP-IP", name: "IP", key: "10.0.0.1")

      patch path("/#{ip_credential.uuid}"), headers: api_headers(token), params: { key: "10.0.0.2" }.to_json

      expect(response.status).to eq(200)
      expect(ip_credential.reload.key).to eq("10.0.0.2")
    end
  end

  describe "DELETE .../credentials/:uuid" do
    it "destroys the credential" do
      delete path("/#{credential.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(204)
      expect(Credential.exists?(credential.id)).to be(false)
    end
  end
end
