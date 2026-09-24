# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API IP Pool Rules", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }
  let(:organization) { create_organization(user) }
  let(:server) { create(:server, organization: organization) }

  # IP pool rules can only reference a pool which the organization has access
  # to so the pool is attached to the organization here.
  let!(:ip_pool) { create(:ip_pool, name: "Test Pool", default: false).tap { |pool| organization.ip_pools << pool } }

  def organization_path(suffix = "")
    "/api/v2/organizations/#{organization.permalink}/ip_pool_rules#{suffix}"
  end

  def server_path(suffix = "")
    "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/ip_pool_rules#{suffix}"
  end

  describe "organization scoped rules" do
    let!(:rule) { create(:ip_pool_rule, owner: organization, ip_pool: ip_pool, from_text: "test@example.com", to_text: "google.com\nexample.org") }

    describe "GET .../ip_pool_rules" do
      it "returns the rules which belong to the organization" do
        create(:ip_pool_rule, owner: create(:organization))

        get organization_path, headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data.size).to eq(1)
        expect(parsed_data.first).to include(
          "uuid" => rule.uuid,
          "owner_type" => "Organization",
          "owner_uuid" => organization.uuid,
          "ip_pool_id" => ip_pool.id,
          "ip_pool_name" => "Test Pool",
          "from_text" => "test@example.com",
          "to_text" => "google.com\nexample.org"
        )
      end

      it "does not return the rules which belong to a server" do
        create(:ip_pool_rule, owner: server, ip_pool: ip_pool)

        get organization_path, headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data.map { |r| r["uuid"] }).to eq([rule.uuid])
      end
    end

    describe "GET .../ip_pool_rules/:uuid" do
      it "returns the rule" do
        get organization_path("/#{rule.uuid}"), headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data).to include("uuid" => rule.uuid)
      end

      it "returns a 404 for a rule in another organization" do
        get organization_path("/#{create(:ip_pool_rule).uuid}"), headers: api_headers(token)

        expect(response.status).to eq(404)
        expect(parsed_error["code"]).to eq("NotFound")
      end
    end

    describe "POST .../ip_pool_rules" do
      it "creates a rule" do
        post organization_path, headers: api_headers(token), params: { from_text: "new@example.com", to_text: "microsoft.com", ip_pool_id: ip_pool.id }.to_json

        expect(response.status).to eq(201)
        expect(parsed_data).to include(
          "owner_type" => "Organization",
          "owner_uuid" => organization.uuid,
          "ip_pool_id" => ip_pool.id,
          "from_text" => "new@example.com",
          "to_text" => "microsoft.com"
        )
        expect(organization.ip_pool_rules.count).to eq(2)
      end

      it "returns a 422 when neither a from nor a to condition is given" do
        post organization_path, headers: api_headers(token), params: { ip_pool_id: ip_pool.id }.to_json

        expect(response.status).to eq(422)
        expect(parsed_error["code"]).to eq("ValidationError")
        expect(parsed_error["details"]).to eq(["At least one rule condition must be specified"])
      end

      it "returns a 422 when the IP pool does not belong to the organization" do
        other_pool = create(:ip_pool, name: "Other Pool", default: false)

        post organization_path, headers: api_headers(token), params: { to_text: "google.com", ip_pool_id: other_pool.id }.to_json

        expect(response.status).to eq(422)
        expect(parsed_error["code"]).to eq("ValidationError")
        expect(parsed_error["details"].join(" ")).to include("must belong to the organization")
      end

      it "returns a 400 when the body contains nothing which can be written" do
        post organization_path, headers: api_headers(token), params: { uuid: "anything" }.to_json

        expect(response.status).to eq(400)
        expect(parsed_error["code"]).to eq("ParameterMissing")
      end
    end

    describe "PATCH .../ip_pool_rules/:uuid" do
      it "updates the rule" do
        patch organization_path("/#{rule.uuid}"), headers: api_headers(token), params: { to_text: "yahoo.com" }.to_json

        expect(response.status).to eq(200)
        expect(parsed_data).to include("to_text" => "yahoo.com", "from_text" => "test@example.com")
      end

      it "returns a 422 when the update removes every condition" do
        patch organization_path("/#{rule.uuid}"), headers: api_headers(token), params: { from_text: "", to_text: "" }.to_json

        expect(response.status).to eq(422)
        expect(parsed_error["details"]).to eq(["At least one rule condition must be specified"])
      end
    end

    describe "DELETE .../ip_pool_rules/:uuid" do
      it "destroys the rule" do
        delete organization_path("/#{rule.uuid}"), headers: api_headers(token)

        expect(response.status).to eq(204)
        expect(parsed_body).to be_nil
        expect(IPPoolRule.exists?(rule.id)).to be(false)
      end
    end
  end

  describe "server scoped rules" do
    let!(:rule) { create(:ip_pool_rule, owner: server, ip_pool: ip_pool, to_text: "example.com") }

    describe "GET .../servers/:server/ip_pool_rules" do
      it "returns the rules which belong to the server" do
        get server_path, headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data.size).to eq(1)
        expect(parsed_data.first).to include("uuid" => rule.uuid, "owner_type" => "Server", "owner_uuid" => server.uuid)
      end

      it "does not return the rules which belong to the organization" do
        create(:ip_pool_rule, owner: organization, ip_pool: ip_pool)

        get server_path, headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data.map { |r| r["uuid"] }).to eq([rule.uuid])
      end

      it "returns a 404 for a server in another organization" do
        other_server = create(:server)

        get "/api/v2/organizations/#{organization.permalink}/servers/#{other_server.permalink}/ip_pool_rules", headers: api_headers(token)

        expect(response.status).to eq(404)
      end
    end

    describe "POST .../servers/:server/ip_pool_rules" do
      it "creates a rule which is owned by the server" do
        post server_path, headers: api_headers(token), params: { to_text: "google.com", ip_pool_id: ip_pool.id }.to_json

        expect(response.status).to eq(201)
        expect(parsed_data).to include("owner_type" => "Server", "owner_uuid" => server.uuid)
        expect(server.ip_pool_rules.count).to eq(2)
      end

      it "returns a 422 when the IP pool does not belong to the server's organization" do
        other_pool = create(:ip_pool, name: "Other Pool", default: false)

        post server_path, headers: api_headers(token), params: { to_text: "google.com", ip_pool_id: other_pool.id }.to_json

        expect(response.status).to eq(422)
        expect(parsed_error["details"].join(" ")).to include("must belong to the organization")
      end
    end

    describe "PATCH .../servers/:server/ip_pool_rules/:uuid" do
      it "updates the rule" do
        patch server_path("/#{rule.uuid}"), headers: api_headers(token), params: { from_text: "test@example.com" }.to_json

        expect(response.status).to eq(200)
        expect(parsed_data).to include("from_text" => "test@example.com")
      end
    end

    describe "DELETE .../servers/:server/ip_pool_rules/:uuid" do
      it "destroys the rule" do
        delete server_path("/#{rule.uuid}"), headers: api_headers(token)

        expect(response.status).to eq(204)
        expect(IPPoolRule.exists?(rule.id)).to be(false)
      end

      it "returns a 404 for a rule which belongs to the organization" do
        org_rule = create(:ip_pool_rule, owner: organization, ip_pool: ip_pool)

        delete server_path("/#{org_rule.uuid}"), headers: api_headers(token)

        expect(response.status).to eq(404)
      end
    end
  end
end
