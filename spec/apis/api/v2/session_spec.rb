# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Session", type: :request do
  describe "GET /api/v2/me" do
    it "returns the user who owns the token" do
      token = create_api_token

      get "/api/v2/me", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["user"]).to include(
        "uuid" => token.user.uuid,
        "email_address" => token.user.email_address,
        "admin" => false
      )
    end

    it "returns the token which authenticated the request" do
      token = create_api_token

      get "/api/v2/me", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["token"]).to include("uuid" => token.uuid, "name" => token.name)
    end

    it "returns only the organizations which a non-admin user can access" do
      user = create(:user)
      token = create(:user_api_token, user: user)
      mine = create_organization(user)
      create(:organization)

      get "/api/v2/me", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["organizations"]).to eq([{ "permalink" => mine.permalink, "name" => mine.name }])
    end

    it "returns every organization for an administrator" do
      user = create(:user, :admin)
      token = create(:user_api_token, user: user)
      create_organization(user)
      theirs = create(:organization)

      get "/api/v2/me", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["organizations"].map { |o| o["permalink"] }).to include(theirs.permalink)
    end

    it "does not set a session cookie" do
      token = create_api_token

      get "/api/v2/me", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(response.headers["Set-Cookie"].to_s).not_to include("authie")
    end
  end
end
