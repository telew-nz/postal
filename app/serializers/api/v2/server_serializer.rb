# frozen_string_literal: true

module API
  module V2
    class ServerSerializer < BaseSerializer

      def as_json(*)
        {
          uuid: record.uuid,
          permalink: record.permalink,
          full_permalink: record.full_permalink,
          name: record.name,
          mode: record.mode,
          token: record.token,
          organization_permalink: record.organization.permalink,
          ip_pool_id: record.ip_pool_id,
          suspended: record.suspended?,
          suspension_reason: record.suspension_reason,
          actual_suspension_reason: record.actual_suspension_reason,
          send_limit: record.send_limit,
          send_limit_approaching_at: iso8601(record.send_limit_approaching_at),
          send_limit_exceeded_at: iso8601(record.send_limit_exceeded_at),
          allow_sender: record.allow_sender,
          privacy_mode: record.privacy_mode,
          log_smtp_data: record.log_smtp_data,
          spam_threshold: decimal(record.spam_threshold),
          spam_failure_threshold: decimal(record.spam_failure_threshold),
          outbound_spam_threshold: decimal(record.outbound_spam_threshold),
          postmaster_address: record.postmaster_address,
          message_retention_days: record.message_retention_days,
          raw_message_retention_days: record.raw_message_retention_days,
          raw_message_retention_size: record.raw_message_retention_size,
          domains_not_to_click_track: lines(record.domains_not_to_click_track),
          created_at: iso8601(record.created_at),
          updated_at: iso8601(record.updated_at)
        }
      end

    end
  end
end
