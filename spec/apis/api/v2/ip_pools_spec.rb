# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API IP Pools", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }

  describe "GET /api/v2/ip_pools" do
    it "returns every IP pool" do
      alpha = create(:ip_pool, name: "Alpha", default: false)
      beta = create(:ip_pool, name: "Beta", default: true)

      get "/api/v2/ip_pools", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.map { |p| p["name"] }).to eq(%w[Alpha Beta])
      expect(parsed_data.first).to include("uuid" => alpha.uuid, "default" => false)
      expect(parsed_data.last).to include("uuid" => beta.uuid, "default" => true)
    end

    # Creating or updating a server and creating an IP pool rule all take an
    # integer `ip_pool_id`, so the collection is the only place a client can
    # discover a valid one.
    it "exposes the integer ID which ip_pool_id refers to" do
      pool = create(:ip_pool, name: "Alpha", default: false)

      get "/api/v2/ip_pools", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.first).to include("id" => pool.id)
    end

    it "is available to users who are not administrators" do
      get "/api/v2/ip_pools", headers: api_headers(token)

      expect(response.status).to eq(200)
    end

    it "paginates the pools" do
      3.times { |i| create(:ip_pool, name: "Pool #{i}", default: false) }

      get "/api/v2/ip_pools", headers: api_headers(token), params: { page: 2, per_page: 2 }

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_pagination).to include("page" => 2, "per_page" => 2, "total" => 3, "total_pages" => 2)
    end

    it "requires authentication" do
      get "/api/v2/ip_pools"

      expect(response.status).to eq(401)
      expect(parsed_error["code"]).to eq("MissingAPIKey")
    end
  end

  describe "write actions" do
    # The test environment does not render exceptions so an unmatched route
    # raises rather than returning a 404.
    it "does not expose a route to create an IP pool" do
      expect do
        post "/api/v2/ip_pools", headers: api_headers(token), params: { name: "New Pool" }.to_json
      end.to raise_error(ActionController::RoutingError)
    end
  end
end
