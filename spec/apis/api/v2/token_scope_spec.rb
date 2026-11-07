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
      other = create(:server, organization: organization)
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
end
