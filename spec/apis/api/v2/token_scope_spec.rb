# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API token scoping", type: :request do
  let(:user) { create(:user) }
  let(:organization) { create_organization(user) }
  let(:server) { create(:server, organization: organization) }

  def org_domains_path
    "/api/v2/organizations/#{organization.permalink}/domains"
  end

  def server_domains_path
    "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/domains"
  end

  describe "site tier keys" do
    let(:site_token) { create(:user_api_token, user: user, tier: "site", scope: "all") }

    it "can use server-scoped endpoints and site-only endpoints" do
      get server_domains_path, headers: api_headers(site_token)
      expect(response.status).to eq(200)

      get org_domains_path, headers: api_headers(site_token)
      expect(response.status).to eq(200)
    end
  end

  describe "server tier keys" do
    let(:server_token) { create(:user_api_token, user: user, tier: "server", server_id: server.id, scope: "domains") }

    it "allows the server it is bound to, for a permitted scope" do
      get server_domains_path, headers: api_headers(server_token)
      expect(response.status).to eq(200)
    end

    it "refuses a different server" do
      other = create(:server, organization: organization, name: "Other Server")
      other_path = "/api/v2/organizations/#{organization.permalink}/servers/#{other.permalink}/domains"

      get other_path, headers: api_headers(server_token)
      expect(response.status).to eq(403)
      expect(parsed_error["code"]).to eq("TokenScope")
    end

    it "refuses non-server-scoped (site-only) endpoints" do
      get org_domains_path, headers: api_headers(server_token)
      expect(response.status).to eq(403)
      expect(parsed_error["code"]).to eq("TokenScope")
    end

    it "refuses controllers outside the key's scope" do
      domain = create(:domain, owner: server)
      path = "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/domains/#{domain.uuid}/spam_rules"
      post path,
           headers: api_headers(server_token),
           params: { kind: "blocklist", match_type: "address", value: "a@b.com", action: "reject" }.to_json
      expect(response.status).to eq(403)
      expect(parsed_error["code"]).to eq("TokenScope")
    end
  end

  describe "server keys with spam scope" do
    let(:spam_token) { create(:user_api_token, user: user, tier: "server", server_id: server.id, scope: "spam") }
    let!(:domain) { create(:domain, owner: server) }

    it "allows spam endpoints for its server" do
      path = "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/domains/#{domain.uuid}/spam_rules"
      get path, headers: api_headers(spam_token)
      expect(response.status).to eq(200)
    end

    it "refuses domain endpoints" do
      get server_domains_path, headers: api_headers(spam_token)
      expect(response.status).to eq(403)
    end
  end

  # Reading a server's messages is its own scope. A key which maintains spam
  # rules does not open every message body the server holds.
  describe "the messages scope" do
    let(:messages_path) { "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/messages" }

    it "refuses a key which only has the spam scope" do
      token = create(:user_api_token, user: user, tier: "server", server_id: server.id, scope: "spam")
      get messages_path, headers: api_headers(token)
      expect(response.status).to eq(403)
      expect(parsed_error["code"]).to eq("TokenScope")
    end

    it "allows a key which has the messages scope" do
      token = create(:user_api_token, user: user, tier: "server", server_id: server.id, scope: "spam,messages")
      MessageFactory.outgoing(server)
      get messages_path, headers: api_headers(token)
      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
    end

    it "accepts messages as a scope when a key is minted" do
      admin = create(:user, :admin)
      site_token = create(:user_api_token, user: admin, tier: "site", scope: "all")
      post "/api/v2/tokens",
           headers: api_headers(site_token),
           params: { name: "integration", tier: "server", server_id: server.id, scope: "domains,spam,routes,messages" }.to_json
      expect(response.status).to eq(201)
      expect(parsed_data["scope"]).to eq("domains,spam,routes,messages")
    end
  end

  # In a real installation every server key is minted with the site key, so its
  # owner is an administrator who can see every organization. The organization
  # lookup therefore stops nothing, and a server's permalink is only unique
  # within its organization: the binding has to hold on its own.
  describe "server keys owned by an administrator, with the same server permalink in two organizations" do
    let(:admin) { create(:user, :admin) }
    let(:first_organization) { create_organization(admin) }
    let(:second_organization) { create_organization(admin) }
    let!(:first_server) { create(:server, organization: first_organization, permalink: "mail") }
    let!(:second_server) { create(:server, organization: second_organization, permalink: "mail") }

    def domains_path(organization)
      "/api/v2/organizations/#{organization.permalink}/servers/mail/domains"
    end

    [
      ["the server created first", :first_server, :first_organization, :second_organization],
      ["the server created second", :second_server, :second_organization, :first_organization],
    ].each do |label, bound, own, other|
      context "when the key is bound to #{label}" do
        let(:token) { create(:user_api_token, user: admin, tier: "server", server_id: send(bound).id, scope: "domains") }

        it "allows its own server" do
          get domains_path(send(own)), headers: api_headers(token)
          expect(response.status).to eq(200)
        end

        it "refuses the other organization's server of the same name" do
          get domains_path(send(other)), headers: api_headers(token)
          expect(response.status).to eq(403)
          expect(parsed_error["code"]).to eq("TokenScope")
        end

        it "cannot create a domain on the other organization's server" do
          expect do
            post domains_path(send(other)), headers: api_headers(token), params: { name: "example.com" }.to_json
          end.not_to change(Domain, :count)
          expect(response.status).to eq(403)
        end
      end
    end

    it "refuses an organization which does not exist without saying so" do
      token = create(:user_api_token, user: admin, tier: "server", server_id: first_server.id, scope: "domains")
      get "/api/v2/organizations/nowhere/servers/mail/domains", headers: api_headers(token)
      expect(response.status).to eq(403)
      expect(parsed_error["code"]).to eq("TokenScope")
    end

    it "refuses a server which has been deleted" do
      token = create(:user_api_token, user: admin, tier: "server", server_id: first_server.id, scope: "domains")
      first_server.soft_destroy
      get domains_path(first_organization), headers: api_headers(token)
      expect(response.status).to eq(403)
    end
  end

  # An administrator does not have to prove that they control a domain, and a
  # server key belongs to the administrator who minted it. A server key is
  # handed to one tenant, so it must not inherit that: it proves the domain the
  # way anybody else does.
  describe "domain ownership with a server key owned by an administrator" do
    let(:admin) { create(:user, :admin) }
    let(:admin_organization) { create_organization(admin) }
    let(:admin_server) { create(:server, organization: admin_organization) }
    let(:path) { "/api/v2/organizations/#{admin_organization.permalink}/servers/#{admin_server.permalink}/domains" }

    it "creates the domain unverified, with the record which proves it" do
      token = create(:user_api_token, user: admin, tier: "server", server_id: admin_server.id, scope: "domains")
      post path, headers: api_headers(token), params: { name: "example.com" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data["verified"]).to be false
      expect(parsed_data["verification_method"]).to eq("DNS")
      domain = Domain.find_by!(uuid: parsed_data["uuid"])
      expect(parsed_data["dns_verification_string"]).to eq(domain.dns_verification_string)
    end

    it "still verifies immediately for the administrator's site key" do
      token = create(:user_api_token, user: admin, tier: "site", scope: "all")
      post path, headers: api_headers(token), params: { name: "example.com" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data["verified"]).to be true
      expect(parsed_data["dns_verification_string"]).to be_nil
    end
  end
end
