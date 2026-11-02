# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Tokens", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }

  describe "GET /api/v2/tokens" do
    it "returns the tokens which belong to the authenticated user" do
      other = create(:user_api_token)

      get "/api/v2/tokens", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_data.first["uuid"]).to eq(token.uuid)
      expect(parsed_data.map { |t| t["uuid"] }).not_to include(other.uuid)
      expect(parsed_pagination).to include("page" => 1, "total" => 1)
    end

    it "never includes a plain text key" do
      get "/api/v2/tokens", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.first).not_to have_key("key")
      expect(response.body).not_to include(token.plain_key)
    end

    it "includes the key prefix so that a token can be identified" do
      get "/api/v2/tokens", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.first["key_prefix"]).to eq(token.key_prefix)
    end
  end

  describe "POST /api/v2/tokens" do
    it "creates a token and returns the plain text key once" do
      post "/api/v2/tokens", headers: api_headers(token), params: { name: "Deploy Key" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data["name"]).to eq("Deploy Key")
      expect(parsed_data["key"]).to start_with("pst_")
      expect(parsed_data["key_prefix"]).to eq(parsed_data["key"][0, 8])

      created = UserAPIToken.find_by(uuid: parsed_data["uuid"])
      expect(created).to be_persisted
      expect(created.user).to eq(user)
      expect(created.key).to eq(UserAPIToken.hash_key(parsed_data["key"]))
    end

    it "creates a token which can immediately be used to authenticate" do
      post "/api/v2/tokens", headers: api_headers(token), params: { name: "Rotation" }.to_json

      expect(response.status).to eq(201)

      get "/api/v2/me", headers: api_headers(parsed_data["key"])

      expect(response.status).to eq(200)
    end

    it "accepts an expiry date" do
      post "/api/v2/tokens", headers: api_headers(token), params: { name: "Temporary", expires_at: "2030-01-01T00:00:00Z" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data["expires_at"]).to eq("2030-01-01T00:00:00Z")
    end

    it "rejects an expiry date which cannot be parsed" do
      post "/api/v2/tokens", headers: api_headers(token), params: { name: "Temporary", expires_at: "not a date" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
      expect(parsed_error["details"]).to be_an(Array)
    end

    it "requires a name" do
      post "/api/v2/tokens", headers: api_headers(token), params: {}.to_json

      expect(response.status).to eq(400)
      expect(parsed_error["code"]).to eq("ParameterMissing")
    end
  end

  describe "DELETE /api/v2/tokens/:id" do
    it "revokes a token rather than destroying it" do
      victim = create(:user_api_token, user: user)

      delete "/api/v2/tokens/#{victim.uuid}", headers: api_headers(token)

      expect(response.status).to eq(204)
      expect(parsed_body).to be_nil
      expect(victim.reload.revoked_at).to be_present
      expect(UserAPIToken.exists?(victim.id)).to be(true)
    end

    it "stops the revoked token from working" do
      victim = create(:user_api_token, user: user)

      delete "/api/v2/tokens/#{victim.uuid}", headers: api_headers(token)
      get "/api/v2/me", headers: api_headers(victim)

      expect(response.status).to eq(401)
    end

    it "does not allow a user to revoke another user's token" do
      other = create(:user_api_token)

      delete "/api/v2/tokens/#{other.uuid}", headers: api_headers(token)

      expect(response.status).to eq(404)
      expect(parsed_error["code"]).to eq("NotFound")
      expect(other.reload.revoked_at).to be_nil
    end
  end
end
