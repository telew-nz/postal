# frozen_string_literal: true

module API
  module V2
    # The DKIM private key is deliberately never rendered by this serializer.
    class DomainSerializer < BaseSerializer

      def as_json(*)
        {
          # The integer ID is exposed because creating a route and creating a
          # track domain both take the parent domain's `domain_id` rather than
          # its UUID. Without this a client has no way to discover a valid one.
          id: record.id,
          uuid: record.uuid,
          name: record.name,
          owner_type: record.owner_type,
          owner_uuid: record.owner&.uuid,
          server_uuid: server_uuid,
          outgoing: record.outgoing,
          incoming: record.incoming,
          use_for_any: record.use_for_any,
          verified: record.verified?,
          verification_method: record.verification_method,
          verification_token: record.verification_token,
          verified_at: iso8601(record.verified_at),
          dns_checked: record.dns_checked?,
          dns_ok: record.dns_ok?,
          dns_checked_at: iso8601(record.dns_checked_at),
          dkim_identifier_string: record.dkim_identifier_string,
          spf_status: record.spf_status,
          spf_error: record.spf_error,
          dkim_status: record.dkim_status,
          dkim_error: record.dkim_error,
          mx_status: record.mx_status,
          mx_error: record.mx_error,
          return_path_status: record.return_path_status,
          return_path_error: record.return_path_error,
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }
      end

      private

      # A domain can be attached to a server either through the legacy
      # server_id column or through the polymorphic owner association which is
      # what the web UI actually uses. Both are handled here so that clients can
      # always work out which server a domain belongs to.
      #
      # @return [String, nil]
      def server_uuid
        return record.server.uuid if record.server

        record.owner.uuid if record.owner_type == "Server"
      end

    end
  end
end
