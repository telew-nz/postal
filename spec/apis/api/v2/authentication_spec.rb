# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Authentication", type: :request do
  describe "when no API key is provided" do
    it "rejects the request" do
      get "/api/v2/me"

      expect(response.status).to eq(401)
      expect(parsed_error["code"]).to eq("MissingAPIKey")
      expect(parsed_error["message"]).to include("X-Postal-API-Key")
    end
  end

  describe "when an empty API key is provided" do
    it "rejects the request" do
      get "/api/v2/me", headers: api_headers("")

      expect(response.status).to eq(401)
      expect(parsed_error["code"]).to eq("MissingAPIKey")
    end
  end

  describe "when an unknown API key is provided" do
    it "rejects the request" do
      get "/api/v2/me", headers: api_headers("pst_notarealtoken")

      expect(response.status).to eq(401)
      expect(parsed_error["code"]).to eq("InvalidAPIKey")
    end
  end

  describe "when a revoked API key is provided" do
    it "rejects the request" do
      token = create_api_token(:revoked)

      get "/api/v2/me", headers: api_headers(token)

      expect(response.status).to eq(401)
      expect(parsed_error["code"]).to eq("InvalidAPIKey")
    end
  end

  describe "when an expired API key is provided" do
    it "rejects the request" do
      token = create_api_token(:expired)

      get "/api/v2/me", headers: api_headers(token)

      expect(response.status).to eq(401)
      expect(parsed_error["code"]).to eq("InvalidAPIKey")
    end
  end

  describe "when a valid API key is provided" do
    it "authenticates the request and records that the token has been used" do
      token = create_api_token
      expect(token.last_used_at).to be_nil

      get "/api/v2/me", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["user"]["uuid"]).to eq(token.user.uuid)
      expect(token.reload.last_used_at).to be_within(1.minute).of(Time.now)
    end

    it "works when the token is provided as a plain string" do
      token = create_api_token

      get "/api/v2/me", headers: { "X-Postal-API-Key" => token.plain_key }

      expect(response.status).to eq(200)
    end
  end

  describe "when the key is stored in the database" do
    it "never stores the plain text key" do
      token = create_api_token

      expect(token.key).to eq(UserAPIToken.hash_key(token.plain_key))
      expect(token.key).not_to eq(token.plain_key)
      expect(token.key_prefix).to eq(token.plain_key[0, 8])
    end
  end

  describe "when a token is used after it has been revoked" do
    it "stops working immediately" do
      token = create_api_token

      get "/api/v2/me", headers: api_headers(token)
      expect(response.status).to eq(200)

      token.revoke!

      get "/api/v2/me", headers: api_headers(token)
      expect(response.status).to eq(401)
    end
  end
end
