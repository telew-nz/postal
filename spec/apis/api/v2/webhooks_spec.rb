# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Webhooks", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }
  let(:organization) { create_organization(user) }
  let(:server) { create(:server, organization: organization) }

  def path(suffix = "")
    "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/webhooks#{suffix}"
  end

  describe "GET .../webhooks" do
    it "returns the webhooks which belong to the server" do
      webhook = create(:webhook, server: server)
      create(:webhook, server: create(:server))

      get path, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.map { |w| w["uuid"] }).to eq([webhook.uuid])
    end
  end

  describe "POST .../webhooks" do
    it "creates a webhook which receives every event" do
      post path, headers: api_headers(token), params: { name: "events", url: "https://example.com/hook", all_events: true }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include("name" => "events", "url" => "https://example.com/hook", "all_events" => true, "events" => [])
      expect(server.webhooks.count).to eq(1)
    end

    it "creates a webhook which receives the events it names" do
      post path, headers: api_headers(token), params: { name: "bounces", url: "https://example.com/hook", events: %w[MessageBounced MessageHeld] }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data["all_events"]).to be false
      expect(parsed_data["events"]).to contain_exactly("MessageBounced", "MessageHeld")
    end

    it "validates the webhook" do
      post path, headers: api_headers(token), params: { name: "broken", url: "not a url" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
    end
  end

  describe "GET .../webhooks/:uuid" do
    it "returns the webhook" do
      webhook = create(:webhook, server: server)

      get path("/#{webhook.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["uuid"]).to eq(webhook.uuid)
    end

    it "returns a 404 for a webhook which belongs to another server" do
      other = create(:webhook, server: create(:server))

      get path("/#{other.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(404)
    end
  end

  describe "PATCH .../webhooks/:uuid" do
    it "changes the events a webhook receives" do
      webhook = create(:webhook, server: server, all_events: false)

      patch path("/#{webhook.uuid}"), headers: api_headers(token), params: { events: %w[MessageSent] }.to_json

      expect(response.status).to eq(200)
      expect(parsed_data["events"]).to eq(%w[MessageSent])
    end
  end

  describe "DELETE .../webhooks/:uuid" do
    it "destroys the webhook" do
      webhook = create(:webhook, server: server)

      delete path("/#{webhook.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(204)
      expect(server.webhooks.count).to eq(0)
    end
  end
end
