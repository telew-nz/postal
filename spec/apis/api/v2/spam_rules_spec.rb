# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Spam Rules", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }
  let(:organization) { create_organization(user) }
  let(:server) { create(:server, organization: organization) }

  def org_path(suffix = "")
    "/api/v2/organizations/#{organization.permalink}/domains/#{domain.uuid}/spam_rules#{suffix}"
  end

  def server_path(suffix = "")
    "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/domains/#{server_domain.uuid}/spam_rules#{suffix}"
  end

  let(:domain) { create(:domain, owner: organization) }
  let(:server_domain) { create(:domain, owner: server) }

  describe "model matching" do
    it "matches address rules exactly and domain rules by the domain part" do
      address_rule = create(:domain_spam_rule, domain: domain, kind: "blocklist", match_type: "address", value: "bad@example.com")
      domain_rule = create(:domain_spam_rule, domain: domain, kind: "allowlist", match_type: "domain", value: "trusted.com")

      expect(address_rule.matches?("bad@example.com")).to be true
      expect(address_rule.matches?("BAD@Example.com")).to be true
      expect(address_rule.matches?("other@example.com")).to be false

      expect(domain_rule.matches?("nice@trusted.com")).to be true
      expect(domain_rule.matches?("nice@trusted.com")).to be true
      expect(domain_rule.matches?("nice@other.com")).to be false
    end

    it "validates the value according to the match type" do
      expect(build(:domain_spam_rule, match_type: "address", value: "not-an-email")).to_not be_valid
      expect(build(:domain_spam_rule, match_type: "domain", value: "maybe a domain")).to_not be_valid
      expect(build(:domain_spam_rule, match_type: "domain", value: "trusted.com")).to be_valid
      expect(build(:domain_spam_rule, match_type: "subject", value: "*invoice*")).to be_valid
    end

    it "matches subject wildcard patterns case-insensitively" do
      rule = create(:domain_spam_rule, domain: domain, kind: "blocklist", match_type: "subject", value: "*invoice*")
      expect(rule.matches_subject?("Your INVOICE is ready")).to be true
      expect(rule.matches_subject?("no match here")).to be false

      wildcard = create(:domain_spam_rule, domain: domain, kind: "blocklist", match_type: "subject", value: "f?x")
      expect(wildcard.matches_subject?("the fox jumps")).to be true
      expect(wildcard.matches_subject?("the fix")).to be true
    end

    it "builds a combined regex for subject rules" do
      create(:domain_spam_rule, domain: domain, kind: "blocklist", match_type: "subject", value: "*invoice*")
      create(:domain_spam_rule, domain: domain, kind: "blocklist", match_type: "subject", value: "*promo*")
      rules = domain.spam_rules.where(kind: "blocklist", match_type: "subject")
      combined = DomainSpamRule.combined_subject_regex(rules)
      expect(combined).to be_a(Regexp)
      expect(combined.match?("big invoice")).to be true
      expect(combined.match?("promo code")).to be true
      expect(combined.match?("nothing")).to be false
    end
  end

  describe "organization scoped spam rules" do
    before { create(:domain_spam_rule, domain: domain, kind: "blocklist", value: "a@example.com") }

    describe "GET /api/v2/organizations/:org/domains/:domain/spam_rules" do
      it "lists the rules for the domain" do
        get org_path, headers: api_headers(token)
        expect(response.status).to eq(200)
        expect(parsed_data.length).to eq(1)
        expect(parsed_data.first).to include("kind" => "blocklist", "value" => "a@example.com")
      end
    end

    describe "POST /api/v2/organizations/:org/domains/:domain/spam_rules" do
      it "creates a rule" do
        post org_path, params: { kind: "blocklist", match_type: "domain", value: "spam.com", action: "mark_spam" }.to_json, headers: api_headers(token)
        expect(response.status).to eq(201)
        expect(parsed_data).to include("kind" => "blocklist", "match_type" => "domain", "value" => "spam.com", "action" => "mark_spam")
        expect(domain.spam_rules.count).to eq(2)
      end

      it "rejects invalid rules" do
        post org_path, params: { kind: "blocklist", match_type: "address", value: "not-an-email", action: "reject" }.to_json, headers: api_headers(token)
        expect(response.status).to eq(422)
      end
    end

    describe "PATCH /api/v2/organizations/:org/domains/:domain/spam_rules/:uuid" do
      it "updates a rule" do
        rule = domain.spam_rules.first
        patch org_path("/#{rule.uuid}"), params: { enabled: false }.to_json, headers: api_headers(token)
        expect(response.status).to eq(200)
        expect(parsed_data["enabled"]).to be false
      end
    end

    describe "DELETE /api/v2/organizations/:org/domains/:domain/spam_rules/:uuid" do
      it "deletes a rule" do
        rule = domain.spam_rules.first
        delete org_path("/#{rule.uuid}"), headers: api_headers(token)
        expect(response.status).to eq(204)
        expect(domain.spam_rules.count).to eq(0)
      end
    end
  end

  describe "server scoped spam rules" do
    let!(:rule) { create(:domain_spam_rule, domain: server_domain, kind: "blocklist", value: "bad@server.com") }

    it "lists and creates server-domain rules" do
      get server_path, headers: api_headers(token)
      expect(response.status).to eq(200)
      expect(parsed_data.map { |r| r["value"] }).to include("bad@server.com")

      post server_path, params: { kind: "allowlist", match_type: "domain", value: "trusted.net", action: "none" }.to_json, headers: api_headers(token)
      expect(response.status).to eq(201)
      expect(server_domain.spam_rules.count).to eq(2)
    end
  end
end
