# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Spam Feedback", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }
  let(:organization) { create_organization(user) }
  let(:server) { create(:server, organization: organization) }
  let!(:domain) { create(:domain, owner: organization, name: "client.com") }
  let(:message) do
    MessageFactory.incoming(server) do |m|
      m.rcpt_to = "user@client.com"
      m.mail_from = "sender@external.net"
    end
  end

  def feedback_path(id = nil)
    id ||= message.id
    "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/messages/#{id}/spam_feedback"
  end

  describe "POST .../messages/:id/spam_feedback" do
    it "creates an allowlist rule from a ham verdict" do
      post feedback_path, params: { verdict: "ham" }.to_json, headers: api_headers(token)
      expect(response.status).to eq(201)

      rule = domain.spam_rules.last
      expect(rule.kind).to eq("allowlist")
      expect(rule.match_type).to eq("address")
      expect(rule.value).to eq("sender@external.net")
      expect(rule.action).to eq("none")
    end

    it "creates a blocklist rule from a spam verdict" do
      post feedback_path, params: { verdict: "spam" }.to_json, headers: api_headers(token)
      expect(response.status).to eq(201)

      rule = domain.spam_rules.last
      expect(rule.kind).to eq("blocklist")
      expect(rule.value).to eq("sender@external.net")
      expect(rule.action).to eq("reject")
    end

    it "attaches to a domain named explicitly with domain_uuid" do
      other = create(:domain, owner: organization, name: "other.net")

      post feedback_path, params: { verdict: "spam", domain_uuid: other.uuid }.to_json, headers: api_headers(token)
      expect(response.status).to eq(201)
      expect(other.spam_rules.count).to eq(1)
      expect(domain.spam_rules.count).to eq(0)
    end

    it "is idempotent and updates the existing rule" do
      create(:domain_spam_rule, domain: domain, kind: "blocklist", match_type: "address", value: "sender@external.net", action: "reject")

      post feedback_path, params: { verdict: "spam", action: "mark_spam" }.to_json, headers: api_headers(token)
      expect(response.status).to eq(201)
      expect(domain.spam_rules.count).to eq(1)
      expect(domain.spam_rules.first.action).to eq("mark_spam")
    end

    it "rejects an unknown verdict" do
      post feedback_path, params: { verdict: "unknown" }.to_json, headers: api_headers(token)
      expect(response.status).to eq(422)
    end

    it "rejects feedback on outgoing messages" do
      outgoing = MessageFactory.outgoing(server) { |m| m.mail_from = "sender@client.com" }

      post feedback_path(outgoing.id), params: { verdict: "ham" }.to_json, headers: api_headers(token)
      expect(response.status).to eq(422)
    end

    it "fails when no domain can be resolved for the message" do
      msg = MessageFactory.incoming(server) { |m| m.rcpt_to = "user@nowhere.invalid" }

      post feedback_path(msg.id), params: { verdict: "ham" }.to_json, headers: api_headers(token)
      expect(response.status).to eq(422)
    end
  end
end
