# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Domains", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }
  let(:organization) { create_organization(user) }
  let(:server) { create(:server, organization: organization) }

  def org_path(suffix = "")
    "/api/v2/organizations/#{organization.permalink}/domains#{suffix}"
  end

  def server_path(suffix = "")
    "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/domains#{suffix}"
  end

  # A resolver which returns the records that Postal expects to find for the
  # given domain. This makes both the verification and the DNS check succeed
  # without touching the network.
  def successful_resolver(domain)
    double("DNSResolver").tap do |resolver|
      allow(resolver).to receive(:txt) do |name|
        case name
        when domain.name then [domain.spf_record, domain.dns_verification_string]
        when "#{domain.dkim_record_name}.#{domain.name}" then [domain.dkim_record]
        else []
        end
      end
      allow(resolver).to receive(:mx).and_return(Postal::Config.dns.mx_records.map { |mx| [10, mx] })
      allow(resolver).to receive(:cname).and_return([Postal::Config.dns.return_path_domain])
    end
  end

  # A resolver which finds nothing at all for any query.
  def empty_resolver
    double("DNSResolver", txt: [], mx: [], cname: [])
  end

  describe "organization scoped domains" do
    let!(:domain) { create(:domain, owner: organization) }

    describe "GET /api/v2/organizations/:organization_permalink/domains" do
      it "returns the domains which belong to the organization" do
        create(:domain)

        get org_path, headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data.map { |d| d["uuid"] }).to eq([domain.uuid])
        expect(parsed_data.first).to include("owner_type" => "Organization", "owner_uuid" => organization.uuid, "verified" => true)
      end

      # Creating a route and creating a track domain both identify their parent
      # domain with the integer `domain_id` rather than with the UUID, so this is
      # the only place a client can discover a value to send.
      it "exposes the integer ID which domain_id refers to" do
        get org_path, headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data.first).to include("id" => domain.id)
      end
    end

    describe "POST /api/v2/organizations/:organization_permalink/domains" do
      it "creates a domain which still needs to be verified" do
        post org_path, headers: api_headers(token), params: { name: "newdomain.com", verification_method: "DNS" }.to_json

        expect(response.status).to eq(201)
        expect(parsed_data).to include("name" => "newdomain.com", "verified" => false, "verification_method" => "DNS")
        expect(parsed_data["verification_token"]).to be_present
        expect(organization.domains.find_by(name: "newdomain.com")).to be_present
      end

      it "verifies the domain immediately when the user is an administrator" do
        admin_token = create_api_token(admin: true)

        post org_path, headers: api_headers(admin_token), params: { name: "admin.com", verification_method: "Email" }.to_json

        expect(response.status).to eq(201)
        expect(parsed_data).to include("verified" => true, "verification_method" => "DNS")
      end

      it "validates the domain" do
        post org_path, headers: api_headers(token), params: { name: "NOT VALID!", verification_method: "DNS" }.to_json

        expect(response.status).to eq(422)
        expect(parsed_error["code"]).to eq("ValidationError")
        expect(parsed_error["details"]).to be_an(Array)
      end

      it "rejects a domain which has already been added" do
        post org_path, headers: api_headers(token), params: { name: domain.name, verification_method: "DNS" }.to_json

        expect(response.status).to eq(422)
        expect(parsed_error["details"].join(" ")).to include("already added")
      end
    end

    describe "GET /api/v2/organizations/:organization_permalink/domains/:domain_uuid" do
      it "returns the domain" do
        get org_path("/#{domain.uuid}"), headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data).to include("uuid" => domain.uuid, "name" => domain.name)
      end

      it "never exposes the DKIM private key" do
        get org_path("/#{domain.uuid}"), headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data).not_to have_key("dkim_private_key")
        expect(response.body).not_to include(domain.dkim_private_key)
      end

      it "returns a 404 for a domain which belongs to somebody else" do
        get org_path("/#{create(:domain).uuid}"), headers: api_headers(token)

        expect(response.status).to eq(404)
      end
    end

    describe "DELETE /api/v2/organizations/:organization_permalink/domains/:domain_uuid" do
      it "destroys the domain" do
        delete org_path("/#{domain.uuid}"), headers: api_headers(token)

        expect(response.status).to eq(204)
        expect(Domain.exists?(domain.id)).to be(false)
      end
    end

    describe "POST .../domains/:domain_uuid/verify" do
      it "returns a 422 when the domain has already been verified" do
        post org_path("/#{domain.uuid}/verify"), headers: api_headers(token)

        expect(response.status).to eq(422)
        expect(parsed_error["code"]).to eq("AlreadyVerified")
      end

      describe "using DNS" do
        let!(:unverified) { create(:domain, :unverified, owner: organization, name: "dns-verify.com") }

        it "verifies the domain when the TXT record is present" do
          allow_any_instance_of(Domain).to receive(:resolver).and_return(successful_resolver(unverified))

          post org_path("/#{unverified.uuid}/verify"), headers: api_headers(token)

          expect(response.status).to eq(200)
          expect(parsed_data).to include("verified" => true)
          expect(unverified.reload.verified_at).to be_present
        end

        it "returns a 422 when the TXT record is missing" do
          allow_any_instance_of(Domain).to receive(:resolver).and_return(empty_resolver)

          post org_path("/#{unverified.uuid}/verify"), headers: api_headers(token)

          expect(response.status).to eq(422)
          expect(parsed_error["code"]).to eq("VerificationFailed")
          expect(unverified.reload.verified_at).to be_nil
        end
      end

      describe "using e-mail" do
        let!(:unverified) { create(:domain, :unverified, owner: organization, name: "email-verify.com", verification_method: "Email") }

        it "verifies the domain when the correct code is provided" do
          post org_path("/#{unverified.uuid}/verify"), headers: api_headers(token), params: { code: unverified.verification_token }.to_json

          expect(response.status).to eq(200)
          expect(parsed_data).to include("verified" => true)
        end

        it "returns a 422 when the code is wrong" do
          post org_path("/#{unverified.uuid}/verify"), headers: api_headers(token), params: { code: "000000wrong" }.to_json

          expect(response.status).to eq(422)
          expect(parsed_error["code"]).to eq("InvalidVerificationCode")
        end

        it "sends a verification e-mail to an administrative address" do
          expect do
            post org_path("/#{unverified.uuid}/verify"), headers: api_headers(token), params: { email_address: "postmaster@email-verify.com" }.to_json
          end.to change { ActionMailer::Base.deliveries.size }.by(1)

          expect(response.status).to eq(202)
          expect(parsed_data).to include("sent_to" => "postmaster@email-verify.com")
          expect(ActionMailer::Base.deliveries.last).to have_attributes(subject: /verify your ownership/i)
        end

        it "returns a 422 when the address is not an administrative address" do
          post org_path("/#{unverified.uuid}/verify"), headers: api_headers(token), params: { email_address: "someone@email-verify.com" }.to_json

          expect(response.status).to eq(422)
          expect(parsed_error["code"]).to eq("InvalidEmailAddress")
          expect(parsed_error["details"]).to include("postmaster@email-verify.com")
        end

        it "returns a 400 when neither a code nor an address is provided" do
          post org_path("/#{unverified.uuid}/verify"), headers: api_headers(token)

          expect(response.status).to eq(400)
          expect(parsed_error["code"]).to eq("ParameterMissing")
        end
      end
    end

    describe "POST .../domains/:domain_uuid/check" do
      it "returns the refreshed DNS statuses" do
        allow_any_instance_of(Domain).to receive(:resolver).and_return(successful_resolver(domain))

        post org_path("/#{domain.uuid}/check"), headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data["ok"]).to be(true)
        expect(parsed_data["domain"]).to include("spf_status" => "OK", "dkim_status" => "OK", "mx_status" => "OK", "return_path_status" => "OK", "dns_ok" => true)
        expect(domain.reload.dns_checked_at).to be_present
      end

      it "reports a failure when the records are missing" do
        allow_any_instance_of(Domain).to receive(:resolver).and_return(empty_resolver)

        post org_path("/#{domain.uuid}/check"), headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data["ok"]).to be(false)
        expect(parsed_data["domain"]).to include("spf_status" => "Missing", "dkim_status" => "Missing")
      end
    end

    describe "GET .../domains/:domain_uuid/dns_records" do
      it "returns the records which need to be created" do
        get org_path("/#{domain.uuid}/dns_records"), headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data["domain"]["uuid"]).to eq(domain.uuid)

        records = parsed_data["records"]
        expect(records.map { |r| r["type"] }).to include("TXT", "CNAME", "MX")
        expect(records.first).to include("type" => "TXT", "name" => "@", "value" => domain.spf_record)
        expect(records.map { |r| r["value"] }).to include(domain.dkim_record, Postal::Config.dns.return_path_domain)
        expect(records.count { |r| r["type"] == "MX" }).to eq(Postal::Config.dns.mx_records.size)
      end

      it "returns a 422 when the domain has not been verified" do
        unverified = create(:domain, :unverified, owner: organization)

        get org_path("/#{unverified.uuid}/dns_records"), headers: api_headers(token)

        expect(response.status).to eq(422)
        expect(parsed_error["code"]).to eq("NotVerified")
      end
    end
  end

  describe "server scoped domains" do
    let!(:domain) { create(:domain, owner: server) }

    it "returns the domains which belong to the server" do
      create(:domain, owner: organization)

      get server_path, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.map { |d| d["uuid"] }).to eq([domain.uuid])
      expect(parsed_data.first).to include("owner_type" => "Server", "server_uuid" => server.uuid)
    end

    it "creates a domain which belongs to the server" do
      post server_path, headers: api_headers(token), params: { name: "serverdomain.com", verification_method: "DNS" }.to_json

      expect(response.status).to eq(201)
      expect(parsed_data).to include("name" => "serverdomain.com", "owner_type" => "Server", "server_uuid" => server.uuid)
      expect(server.domains.find_by(name: "serverdomain.com")).to be_present
    end

    it "returns a 404 when the domain belongs to the organization rather than the server" do
      organization_domain = create(:domain, owner: organization)

      get server_path("/#{organization_domain.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(404)
    end

    it "destroys a domain which belongs to the server" do
      delete server_path("/#{domain.uuid}"), headers: api_headers(token)

      expect(response.status).to eq(204)
      expect(Domain.exists?(domain.id)).to be(false)
    end

    it "returns a 404 for a server which is not in the organization" do
      other = create(:server)

      get "/api/v2/organizations/#{organization.permalink}/servers/#{other.permalink}/domains", headers: api_headers(token)

      expect(response.status).to eq(404)
    end
  end
end
