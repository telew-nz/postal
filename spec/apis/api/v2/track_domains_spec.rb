# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Track Domains", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }
  let(:organization) { create_organization(user) }
  let(:server) { create(:server, organization: organization) }
  let(:domain) { create(:domain, owner: server) }
  let!(:track_domain) { create(:track_domain, server: server, domain: domain) }

  def path(suffix = "")
    "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/track_domains#{suffix}"
  end

  # Tracking domains perform a DNS lookup when they are created and when they
  # are checked. Both are stubbed here so that the examples do not depend on the
  # network.
  def stub_dns(records)
    resolver = double("DNSResolver", cname: records, txt: [], mx: [])
    allow_any_instance_of(Domain).to receive(:resolver).and_return(resolver)
  end

  describe "GET .../track_domains" do
    it "returns the tracking domains for the server" do
      create(:track_domain)

      get path, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_data.first).to include(
        "uuid" => track_domain.uuid,
        "name" => "click",
        "full_name" => "click.#{domain.name}",
        "domain_uuid" => domain.uuid,
        "server_uuid" => server.uuid,
        "ssl_enabled" => true,
        "track_clicks" => true,
        "track_loads" => true,
        "dns_ok" => true
      )
    end
  end

  describe "GET .../track_domains/:uuid" do
    it "returns the tracking domain" do
      get path("/#{track_domain.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to include("uuid" => track_domain.uuid)
    end

    it "returns a 404 for a tracking domain on another server" do
      get path("/#{create(:track_domain).uuid}"), headers: api_headers(token)

      expect(response.status).to eq(404)
    end
  end

  describe "POST .../track_domains" do
    let(:another_domain) { create(:domain, owner: server) }

    it "creates a tracking domain" do
      stub_dns([Postal::Config.dns.track_domain])

      post path, headers: api_headers(token), params: { name: "track", domain_id: another_domain.id, track_clicks: false, track_loads: false, ssl_enabled: false }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include(
        "name" => "track",
        "full_name" => "track.#{another_domain.name}",
        "domain_uuid" => another_domain.uuid,
        "track_clicks" => false,
        "track_loads" => false,
        "ssl_enabled" => false,
        "dns_status" => "OK"
      )
    end

    it "records the excluded click domains as an array" do
      stub_dns([])

      post path, headers: api_headers(token), params: { name: "track", domain_id: another_domain.id, excluded_click_domains: "example.com\nexample.org" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data["excluded_click_domains"]).to eq(["example.com", "example.org"])
    end

    it "records a DNS failure when the record is missing" do
      stub_dns([])

      post path, headers: api_headers(token), params: { name: "track", domain_id: another_domain.id }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include("dns_status" => "Missing", "dns_ok" => false)
    end

    it "validates the tracking domain" do
      stub_dns([])

      post path, headers: api_headers(token), params: { name: "Not Valid", domain_id: another_domain.id }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("ValidationError")
      expect(parsed_error["details"]).to be_an(Array)
    end

    it "rejects a second tracking domain for the same domain" do
      stub_dns([])

      post path, headers: api_headers(token), params: { name: "other", domain_id: domain.id }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["details"].join(" ")).to include("already has a track domain")
    end

    it "rejects a domain which does not belong to the server or its organization" do
      stub_dns([])

      post path, headers: api_headers(token), params: { name: "other", domain_id: create(:domain).id }.to_json

      expect(response.status).to eq(422)
      expect(parsed_error["details"].join(" ")).to include("does not belong to the server")
    end
  end

  describe "PATCH .../track_domains/:uuid" do
    it "updates the tracking options" do
      patch path("/#{track_domain.uuid}"), headers: api_headers(token), params: { track_clicks: false, track_loads: false, ssl_enabled: false, excluded_click_domains: "example.com" }.to_json

      expect(response.status).to eq(200)
      expect(parsed_data).to include("track_clicks" => false, "track_loads" => false, "ssl_enabled" => false, "excluded_click_domains" => ["example.com"])
    end

    it "does not allow the name or the domain to be changed" do
      other = create(:domain, owner: server)

      patch path("/#{track_domain.uuid}"), headers: api_headers(token), params: { track_clicks: true, name: "renamed", domain_id: other.id }.to_json

      expect(response.status).to eq(200)
      expect(track_domain.reload.name).to eq("click")
      expect(track_domain.domain).to eq(domain)
    end
  end

  describe "POST .../track_domains/:uuid/toggle_ssl" do
    it "disables SSL when it is currently enabled" do
      post path("/#{track_domain.uuid}/toggle_ssl"), headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to include("ssl_enabled" => false)
      expect(track_domain.reload.ssl_enabled).to be(false)
    end

    it "enables SSL when it is currently disabled" do
      track_domain.update!(ssl_enabled: false)

      post path("/#{track_domain.uuid}/toggle_ssl"), headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to include("ssl_enabled" => true)
    end
  end

  describe "POST .../track_domains/:uuid/check" do
    it "returns the refreshed DNS status when the record is correct" do
      stub_dns([Postal::Config.dns.track_domain])

      post path("/#{track_domain.uuid}/check"), headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["ok"]).to be(true)
      expect(parsed_data["track_domain"]).to include("dns_status" => "OK", "dns_ok" => true)
      expect(track_domain.reload.dns_checked_at).to be_present
    end

    it "returns the refreshed DNS status when the record is wrong" do
      stub_dns(["somewhere.else"])

      post path("/#{track_domain.uuid}/check"), headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["ok"]).to be(false)
      expect(parsed_data["track_domain"]).to include("dns_status" => "Invalid")
    end
  end

  describe "DELETE .../track_domains/:uuid" do
    it "destroys the tracking domain" do
      delete path("/#{track_domain.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(204)
      expect(TrackDomain.exists?(track_domain.id)).to be(false)
    end
  end
end
