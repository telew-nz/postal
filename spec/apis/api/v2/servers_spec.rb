# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Servers", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }
  let(:organization) { create_organization(user) }
  let(:server) { create(:server, organization: organization) }

  def path(suffix = "")
    "/api/v2/organizations/#{organization.permalink}/servers#{suffix}"
  end

  # Servers provision a message database of their own when they are created.
  # The suite shares a single message database so provisioning is disabled here
  # to stop a server created through the API from dropping the tables which
  # other examples rely on.
  before do
    GlobalMessageDB.find_or_create
    allow_any_instance_of(Postal::MessageDB::Provisioner).to receive(:provision)
    allow_any_instance_of(Postal::MessageDB::Provisioner).to receive(:drop)
  end

  describe "GET /api/v2/organizations/:organization_permalink/servers" do
    it "returns the servers in the organization" do
      server

      get path, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.map { |s| s["permalink"] }).to eq([server.permalink])
      expect(parsed_pagination).to include("page" => 1, "total" => 1)
    end

    it "does not return soft destroyed servers" do
      destroyed = create(:server, organization: organization)
      destroyed.soft_destroy

      get path, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to eq([])
    end

    it "returns a 404 when the organization cannot be accessed" do
      get "/api/v2/organizations/#{create(:organization).permalink}/servers", headers: api_headers(token)

      expect(response.status).to eq(404)
    end
  end

  describe "GET /api/v2/organizations/:organization_permalink/servers/:server_permalink" do
    it "returns the server" do
      get path("/#{server.permalink}"), headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to include(
        "uuid" => server.uuid,
        "permalink" => server.permalink,
        "full_permalink" => "#{organization.permalink}/#{server.permalink}",
        "name" => server.name,
        "mode" => "Live",
        "token" => server.token,
        "organization_permalink" => organization.permalink,
        "suspended" => false
      )
    end

    it "returns a 404 for a server which is not in the organization" do
      get path("/#{create(:server).permalink}"), headers: api_headers(token)

      expect(response.status).to eq(404)
    end
  end

  describe "POST /api/v2/organizations/:organization_permalink/servers" do
    it "creates a server" do
      post path, headers: api_headers(token), params: { name: "My Server", mode: "Live" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include("name" => "My Server", "mode" => "Live", "organization_permalink" => organization.permalink)

      created = organization.servers.find_by(name: "My Server")
      expect(created).to be_present
      expect(created.permalink).to be_present
      expect(created.token).to be_present
    end

    it "validates the server" do
      post path, headers: api_headers(token), params: { name: "My Server", mode: "Nonsense" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
      expect(parsed_error["details"]).to be_an(Array)
    end
  end

  describe "PATCH /api/v2/organizations/:organization_permalink/servers/:server_permalink" do
    it "updates the attributes which any member may change" do
      patch path("/#{server.permalink}"), headers: api_headers(token), params: { name: "Renamed", mode: "Development", spam_threshold: 10, postmaster_address: "postmaster@example.com" }.to_json

      expect(response.status).to eq(200)
      expect(parsed_data).to include("name" => "Renamed", "mode" => "Development", "spam_threshold" => 10.0)
      expect(server.reload.name).to eq("Renamed")
    end

    it "ignores the administrative attributes when the user is not an administrator" do
      patch path("/#{server.permalink}"), headers: api_headers(token), params: { name: "Renamed", send_limit: 100, privacy_mode: true, log_smtp_data: true }.to_json

      expect(response.status).to eq(200)
      expect(server.reload.send_limit).to be_nil
      expect(server.privacy_mode).to be(false)
      expect(server.log_smtp_data).to be(false)
    end

    it "allows an administrator to change the administrative attributes" do
      admin_token = create_api_token(admin: true)

      attributes = {
        send_limit: 100,
        privacy_mode: true,
        log_smtp_data: true,
        message_retention_days: 7,
        raw_message_retention_days: 3,
        raw_message_retention_size: 1024
      }

      patch path("/#{server.permalink}"), headers: api_headers(admin_token), params: attributes.to_json

      expect(response.status).to eq(200)
      expect(server.reload.send_limit).to eq(100)
      expect(server.privacy_mode).to be(true)
      expect(server.log_smtp_data).to be(true)
      expect(server.message_retention_days).to eq(7)
      expect(server.raw_message_retention_days).to eq(3)
      expect(server.raw_message_retention_size).to eq(1024)
    end

    it "validates the server" do
      patch path("/#{server.permalink}"), headers: api_headers(token), params: { mode: "Nonsense" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
    end
  end

  describe "DELETE /api/v2/organizations/:organization_permalink/servers/:server_permalink" do
    it "requires the confirmation text to match the server name" do
      delete path("/#{server.permalink}"), headers: api_headers(token), params: { confirm_text: "wrong" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
      expect(server.reload.deleted_at).to be_nil
    end

    it "soft destroys the server" do
      delete path("/#{server.permalink}"), headers: api_headers(token), params: { confirm_text: server.name }.to_json

      expect(response.status).to eq(204)
      expect(parsed_body).to be_nil
      expect(server.reload.deleted_at).to be_present
    end
  end

  describe "POST /api/v2/organizations/:organization_permalink/servers/:server_permalink/suspend" do
    it "suspends the server when the user is an administrator" do
      admin_token = create_api_token(admin: true)

      post path("/#{server.permalink}/suspend"), headers: api_headers(admin_token), params: { reason: "Spam" }.to_json

      expect(response.status).to eq(200)
      expect(parsed_data).to include("suspended" => true, "suspension_reason" => "Spam")
      expect(server.reload.suspended_at).to be_present
    end

    it "rejects the request when the user is not an administrator" do
      post path("/#{server.permalink}/suspend"), headers: api_headers(token), params: { reason: "Spam" }.to_json

      expect(response.status).to eq(403)
      expect(parsed_error["code"]).to eq("NotPermitted")
      expect(server.reload.suspended_at).to be_nil
    end
  end

  describe "POST /api/v2/organizations/:organization_permalink/servers/:server_permalink/unsuspend" do
    it "unsuspends the server when the user is an administrator" do
      suspended = create(:server, :suspended, organization: organization)
      admin_token = create_api_token(admin: true)

      post path("/#{suspended.permalink}/unsuspend"), headers: api_headers(admin_token)

      expect(response.status).to eq(200)
      expect(parsed_data).to include("suspended" => false, "suspension_reason" => nil)
      expect(suspended.reload.suspended_at).to be_nil
    end

    it "rejects the request when the user is not an administrator" do
      post path("/#{server.permalink}/unsuspend"), headers: api_headers(token)

      expect(response.status).to eq(403)
      expect(parsed_error["code"]).to eq("NotPermitted")
    end
  end

  describe "GET /api/v2/organizations/:organization_permalink/servers/:server_permalink/queue" do
    it "returns the messages which are waiting to be delivered" do
      create(:queued_message, server: server, domain: "example.com")
      create(:queued_message, server: server, domain: "example.org")
      create(:queued_message)

      get path("/#{server.permalink}/queue"), headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(2)
      expect(parsed_data.map { |m| m["domain"] }).to contain_exactly("example.com", "example.org")
      expect(parsed_pagination).to include("page" => 1, "total" => 2)
    end

    it "includes the lock state of a message" do
      create(:queued_message, :locked, server: server)

      get path("/#{server.permalink}/queue"), headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.first).to include("locked" => true, "locked_by" => "worker1")
    end

    it "paginates the queue" do
      3.times { create(:queued_message, server: server) }

      get path("/#{server.permalink}/queue"), headers: api_headers(token), params: { page: 2, per_page: 2 }

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_pagination).to include("page" => 2, "per_page" => 2, "total" => 3, "total_pages" => 2)
    end
  end
end
