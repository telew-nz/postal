# frozen_string_literal: true

module API
  module V2
    # Messages are not ActiveRecord objects. They are instances of
    # Postal::MessageDB::Message which read their values out of a string keyed
    # hash using method_missing and therefore have no usable #as_json. Every
    # attribute is listed explicitly here.
    class MessageSerializer < BaseSerializer

      def as_json(*)
        json = {
          id: record.id,
          token: record.token,
          scope: record.scope,
          rcpt_to: record.rcpt_to,
          mail_from: record.mail_from,
          subject: record.subject,
          message_id: record.message_id,
          route_id: record.route_id,
          domain_id: record.domain_id,
          credential_id: record.credential_id,
          endpoint_type: record.endpoint_type,
          endpoint_id: record.endpoint_id,
          status: record.status,
          held: boolean(record.held),
          hold_expiry: iso8601(record.hold_expiry),
          size: record.size&.to_i,
          inspected: boolean(record.inspected),
          spam: boolean(record.spam),
          spam_score: decimal(record.spam_score),
          spam_status: record.spam_status,
          threat: boolean(record.threat),
          threat_details: record.threat_details,
          bounce: boolean(record.bounce),
          bounce_for_id: record.bounce_for_id,
          tag: record.tag,
          loaded: iso8601(record.loaded),
          clicked: iso8601(record.clicked),
          read: record.read?,
          received_with_ssl: boolean(record.received_with_ssl),
          parsed: record.parsed?,
          tracked_links: record.tracked_links,
          tracked_images: record.tracked_images,
          timestamp: iso8601(record.timestamp),
          last_delivery_attempt: iso8601(record.last_delivery_attempt),
          raw_table: record.raw_table,
          raw_body_id: record.raw_body_id,
          raw_headers_id: record.raw_headers_id,
          raw_message: record.raw_message?
        }
        options[:detail] ? json.merge(details) : json
      end

      private

      # The raw contents of the message. These are only rendered when a single
      # message has been requested because they are expensive to load.
      def details
        {
          headers: record.headers,
          plain_body: record.plain_body,
          html_body: record.html_body,
          attachments: attachments
        }
      end

      def attachments
        record.attachments.map do |attachment|
          {
            filename: attachment.filename,
            content_type: attachment.mime_type,
            size: attachment.body.to_s.bytesize
          }
        end
      end

    end
  end
end
