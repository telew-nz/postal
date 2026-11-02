# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Organizations", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }
  let(:organization) { create_organization(user) }

  describe "GET /api/v2/organizations" do
    it "returns the organizations which the user is a member of" do
      organization
      create(:organization)

      get "/api/v2/organizations", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.map { |o| o["permalink"] }).to eq([organization.permalink])
      expect(parsed_pagination).to include("page" => 1, "per_page" => 50, "total" => 1, "total_pages" => 1)
    end

    it "returns every organization for an administrator" do
      admin = create(:user, :admin)
      admin_token = create(:user_api_token, user: admin)
      theirs = create(:organization)

      get "/api/v2/organizations", headers: api_headers(admin_token)

      expect(response.status).to eq(200)
      expect(parsed_data.map { |o| o["permalink"] }).to include(theirs.permalink)
    end

    it "does not return soft destroyed organizations" do
      destroyed = create_organization(user)
      destroyed.soft_destroy

      get "/api/v2/organizations", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to eq([])
    end

    it "paginates the collection" do
      3.times { create_organization(user) }

      get "/api/v2/organizations", headers: api_headers(token), params: { page: 2, per_page: 1 }

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_pagination).to include("page" => 2, "per_page" => 1, "total" => 3, "total_pages" => 3)
    end
  end

  describe "GET /api/v2/organizations/:organization_permalink" do
    it "returns the organization" do
      get "/api/v2/organizations/#{organization.permalink}", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to include(
        "uuid" => organization.uuid,
        "permalink" => organization.permalink,
        "name" => organization.name,
        "owner_uuid" => user.uuid,
        "suspended" => false
      )
    end

    it "returns a 404 for an organization which the user cannot access" do
      get "/api/v2/organizations/#{create(:organization).permalink}", headers: api_headers(token)

      expect(response.status).to eq(404)
      expect(parsed_error["code"]).to eq("NotFound")
    end

    it "returns a 404 for an organization which does not exist" do
      get "/api/v2/organizations/nonsense", headers: api_headers(token)

      expect(response.status).to eq(404)
      expect(parsed_error["code"]).to eq("NotFound")
    end
  end

  describe "POST /api/v2/organizations" do
    it "creates an organization when the user is an administrator" do
      admin_token = create_api_token(admin: true)

      post "/api/v2/organizations", headers: api_headers(admin_token), params: { name: "New Org", permalink: "new-org" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include("name" => "New Org", "permalink" => "new-org")

      created = Organization.find_by(permalink: "new-org")
      expect(created.owner).to eq(admin_token.user)
    end

    it "rejects the request when the user is not an administrator" do
      post "/api/v2/organizations", headers: api_headers(token), params: { name: "New Org" }.to_json

      expect(response.status).to eq(403)
      expect(parsed_error["code"]).to eq("NotPermitted")
      expect(Organization.find_by(name: "New Org")).to be_nil
    end

    it "validates the organization" do
      admin_token = create_api_token(admin: true)

      post "/api/v2/organizations", headers: api_headers(admin_token), params: { permalink: "no-name" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
      expect(parsed_error["details"]).to be_an(Array)
      expect(parsed_error["details"].join(" ")).to include("Name")
    end

    it "rejects an empty body" do
      admin_token = create_api_token(admin: true)

      post "/api/v2/organizations", headers: api_headers(admin_token), params: {}.to_json

      expect(response.status).to eq(400)
      expect(parsed_error["code"]).to eq("ParameterMissing")
    end
  end

  describe "PATCH /api/v2/organizations/:organization_permalink" do
    it "updates the organization" do
      patch "/api/v2/organizations/#{organization.permalink}", headers: api_headers(token), params: { name: "Renamed", time_zone: "London" }.to_json

      expect(response.status).to eq(200)
      expect(parsed_data).to include("name" => "Renamed", "time_zone" => "London")
      expect(organization.reload.name).to eq("Renamed")
    end

    it "does not allow the permalink to be changed" do
      patch "/api/v2/organizations/#{organization.permalink}", headers: api_headers(token), params: { name: organization.name, permalink: "hacked" }.to_json

      expect(response.status).to eq(200)
      expect(organization.reload.permalink).not_to eq("hacked")
    end

    it "rejects a body which contains only attributes which cannot be written" do
      patch "/api/v2/organizations/#{organization.permalink}", headers: api_headers(token), params: { permalink: "hacked" }.to_json

      expect(response.status).to eq(400)
      expect(parsed_error["code"]).to eq("ParameterMissing")
    end

    it "validates the organization" do
      patch "/api/v2/organizations/#{organization.permalink}", headers: api_headers(token), params: { name: "" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
    end
  end

  describe "DELETE /api/v2/organizations/:organization_permalink" do
    it "requires the administrator" do
      delete "/api/v2/organizations/#{organization.permalink}", headers: api_headers(token), params: { confirm_text: organization.name }.to_json

      expect(response.status).to eq(403)
      expect(parsed_error["code"]).to eq("NotPermitted")
      expect(organization.reload.deleted_at).to be_nil
    end

    it "requires the confirmation text to match the organization name" do
      admin_token = create_api_token(admin: true)

      delete "/api/v2/organizations/#{organization.permalink}", headers: api_headers(admin_token), params: { confirm_text: "something else" }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
      expect(organization.reload.deleted_at).to be_nil
    end

    it "soft destroys the organization" do
      admin_token = create_api_token(admin: true)

      delete "/api/v2/organizations/#{organization.permalink}", headers: api_headers(admin_token), params: { confirm_text: organization.name }.to_json

      expect(response.status).to eq(204)
      expect(parsed_body).to be_nil
      expect(organization.reload.deleted_at).to be_present
      expect(Organization.present.exists?(organization.id)).to be(false)
    end

    it "ignores surrounding whitespace and case in the confirmation text" do
      admin_token = create_api_token(admin: true)

      delete "/api/v2/organizations/#{organization.permalink}", headers: api_headers(admin_token), params: { confirm_text: "  #{organization.name.upcase}  " }.to_json

      expect(response.status).to eq(204)
    end

    it "rejects a missing confirmation text" do
      admin_token = create_api_token(admin: true)

      delete "/api/v2/organizations/#{organization.permalink}", headers: api_headers(admin_token)

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
    end
  end
end
