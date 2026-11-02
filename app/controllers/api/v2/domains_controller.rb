# frozen_string_literal: true

module API
  module V2
    # Domains can be attached to an organization or to an individual server. Both
    # nestings are handled by this controller which mirrors the behaviour of the
    # web UI's DomainsController.
    class DomainsController < BaseController

      include ScopedToOrganization

      before_action :load_server, if: -> { params[:server_permalink].present? }
      before_action :load_domain, only: [:show, :destroy, :verify, :check, :dns_records]

      def index
        domains, pagination = paginate(domain_scope.order(:name, :id))
        render_collection(DomainSerializer.collection(domains), pagination)
      end

      def show
        render_data(DomainSerializer.new(domain).as_json)
      end

      def create
        new_domain = domain_scope.build(resource_params(:name, :verification_method))

        # Administrators do not need to prove that they control a domain so the
        # verification step is skipped for them, exactly as it is in the web UI.
        if current_user.admin?
          new_domain.verification_method = "DNS"
          new_domain.verified_at = Time.now
        end

        if new_domain.save
          render_created(DomainSerializer.new(new_domain).as_json)
        else
          render_validation_error(new_domain, "The domain could not be created.")
        end
      end

      def destroy
        domain.destroy
        render_no_content
      end

      # Verify a domain using the method which was chosen when it was created.
      def verify
        if domain.verified?
          render_error(:unprocessable_entity, "AlreadyVerified", "The domain #{domain.name} has already been verified.")
          return
        end

        case domain.verification_method
        when "DNS" then verify_with_dns
        when "Email" then verify_with_email
        else
          render_error(:unprocessable_entity, "VerificationFailed", "The domain #{domain.name} cannot be verified using the #{domain.verification_method} method.")
        end
      end

      # Re-run the DNS checks for a domain and return the refreshed statuses.
      def check
        ok = domain.check_dns(:manual)
        render_data({
          ok: ok,
          domain: DomainSerializer.new(domain.reload).as_json
        })
      end

      # The DNS records which need to be created for a domain. This is the API
      # equivalent of the DNS setup page in the web UI.
      def dns_records
        unless domain.verified?
          render_error(:unprocessable_entity, "NotVerified", "The DNS records for #{domain.name} cannot be shown until the domain has been verified.")
          return
        end

        render_data({
          domain: DomainSerializer.new(domain).as_json,
          records: dns_record_list
        })
      end

      private

      # The server which the request is nested under, if there is one.
      #
      # @return [Server, nil]
      def server
        return nil if params[:server_permalink].blank?

        @server ||= organization.servers.present.find_by_permalink!(params[:server_permalink])
      end

      def load_server
        server
      end

      # The scope which domains are resolved within.
      #
      # @return [ActiveRecord::Relation]
      def domain_scope
        server ? server.domains : organization.domains
      end

      def domain
        @domain ||= domain_scope.find_by_uuid!(params[:domain_uuid])
      end

      def load_domain
        domain
      end

      def verify_with_dns
        if domain.verify_with_dns
          render_data(DomainSerializer.new(domain.reload).as_json)
        else
          render_error(:unprocessable_entity, "VerificationFailed", "We couldn't verify #{domain.name}. Please double check that the TXT record has been added correctly.")
        end
      end

      def verify_with_email
        if params[:code].present?
          verify_with_email_code
        elsif params[:email_address].present?
          send_verification_email
        else
          render_error(:bad_request, "ParameterMissing", "Either a code or an e-mail address must be provided to verify a domain by e-mail.")
        end
      end

      def verify_with_email_code
        if domain.verification_token == params[:code].to_s.strip
          domain.mark_as_verified
          render_data(DomainSerializer.new(domain.reload).as_json)
        else
          render_error(:unprocessable_entity, "InvalidVerificationCode", "The verification code provided was not valid.")
        end
      end

      def send_verification_email
        address = params[:email_address].to_s
        unless domain.verification_email_addresses.include?(address)
          message = "A verification e-mail can only be sent to one of the standard administrative addresses for #{domain.name}."
          render_error(:unprocessable_entity, "InvalidEmailAddress", message, domain.verification_email_addresses)
          return
        end

        AppMailer.verify_domain(domain, address, current_user).deliver
        render_data({ sent_to: address }, status: :accepted)
      end

      # The records which need to be created, in the order which the web UI
      # presents them.
      #
      # @return [Array<Hash>]
      def dns_record_list
        spf_notes = "Add this record at the apex of your domain. If you already send mail using another " \
                    "service you may only need to add include:#{Postal::Config.dns.spf_include} to your existing record."

        records = [
          {
            type: "TXT",
            name: "@",
            host: domain.name,
            value: domain.spf_record,
            status: domain.spf_status,
            error: domain.spf_error,
            required: true,
            notes: spf_notes
          },
          {
            type: "TXT",
            name: domain.dkim_record_name,
            host: "#{domain.dkim_record_name}.#{domain.name}",
            value: domain.dkim_record,
            status: domain.dkim_status,
            error: domain.dkim_error,
            required: true,
            notes: nil
          },
          {
            type: "CNAME",
            name: domain.return_path_domain,
            host: domain.return_path_domain,
            value: Postal::Config.dns.return_path_domain,
            status: domain.return_path_status,
            error: domain.return_path_error,
            required: false,
            notes: "This is optional but adding it improves deliverability and achieves DMARC alignment."
          },
        ]

        Postal::Config.dns.mx_records.each do |mx|
          records << {
            type: "MX",
            name: "@",
            host: domain.name,
            value: mx,
            priority: 10,
            status: domain.mx_status,
            error: domain.mx_error,
            required: false,
            notes: "Only needed if you want to receive incoming e-mail for this domain."
          }
        end

        records
      end

    end
  end
end
