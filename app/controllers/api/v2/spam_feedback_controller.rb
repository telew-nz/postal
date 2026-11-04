# frozen_string_literal: true

module API
  module V2
    # Spam feedback for a message.
    #
    # A client tells the API that a received message was either spam or ham. That
    # verdict is converted into a per-domain DomainSpamRule keyed on the sender
    # address, so the rspamd maps rendered by `./deploy.sh rspamd` learn from the
    # outcome: a "ham" verdict allowlists the sender, a "spam" verdict blocklists
    # it. The rule is attached to the domain the message was received for, which
    # is resolved from the message's recipients unless the client names a domain
    # explicitly with domain_uuid.
    class SpamFeedbackController < BaseController

      include ScopedToServer

      VERDICTS = %w[spam ham].freeze

      def create
        unless VERDICTS.include?(params[:verdict].to_s)
          render_error(:unprocessable_entity, "ValidationError", "verdict must be 'spam' or 'ham'.")
          return
        end

        if message.scope != "incoming"
          render_error(:unprocessable_entity, "NotIncoming", "Spam feedback only applies to incoming messages.")
          return
        end

        sender = normalize_sender(message.mail_from)
        if sender.blank?
          render_error(:unprocessable_entity, "ValidationError", "This message has no sender address to learn from.")
          return
        end

        domain = resolve_domain
        if domain.nil?
          render_error(:unprocessable_entity, "DomainUndetermined", "Could not determine the domain this message was received for. Pass domain_uuid.")
          return
        end

        kind = params[:verdict] == "spam" ? "blocklist" : "allowlist"
        action = params[:action].presence || (kind == "blocklist" ? "reject" : "none")

        rule = domain.spam_rules.find_or_initialize_by(kind: kind, match_type: "address", value: sender)
        rule.action = action
        rule.enabled = true

        if rule.save
          render_created(SpamRuleSerializer.new(rule).as_json)
        else
          render_validation_error(rule, "The spam rule could not be saved.")
        end
      end

      private

      # The message the feedback is about, looked up in the server's message
      # database exactly as MessagesController does.
      #
      # @return [Postal::MessageDB::Message]
      def message
        @message ||= server.message_db.message(params[:id].to_i)
      end

      # The domain the rule should be attached to. An explicit domain_uuid wins;
      # otherwise the first of the message's recipient domains which belongs to
      # the server or its organization.
      #
      # @return [Domain, nil]
      def resolve_domain
        return @resolve_domain if defined?(@resolve_domain)

        pool = Domain.where(id: organization.domain_ids + server.domain_ids)
        @resolve_domain = if params[:domain_uuid].present?
                            pool.find_by_uuid!(params[:domain_uuid])
                          else
                            resolved = nil
                            Array(message.rcpt_to).each do |rcpt|
                              name = rcpt.to_s.split("@").last.to_s.downcase
                              next if name.empty?

                              candidate = pool.find_by(name: name)
                              if candidate
                                resolved = candidate
                                break
                              end
                            end
                            resolved
                          end
      end

      def normalize_sender(address)
        address.to_s.strip.downcase
      end

    end
  end
end
