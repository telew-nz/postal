# frozen_string_literal: true

module API
  module V2
    # Per-domain spam rules: allowlist / blocklist entries for addresses or
    # domains. These are the data source for the rspamd integration: rules are
    # created through this API and consumed (rendered into rspamd maps) by the
    # deploy/rspamd integration.
    #
    # Domains can be attached to an organization or to an individual server; both
    # nestings are handled here, mirroring DomainsController.
    class SpamRulesController < BaseController

      include ScopedToOrganization

      before_action :load_server, if: -> { params[:server_permalink].present? }
      before_action :load_domain

      def index
        rules, pagination = paginate(domain.spam_rules.order(:kind, :match_type, :value))
        render_collection(SpamRuleSerializer.collection(rules), pagination)
      end

      def show
        render_data(SpamRuleSerializer.new(spam_rule).as_json)
      end

      def create
        new_rule = domain.spam_rules.build(resource_params(:kind, :match_type, :value, :action, :enabled))
        if new_rule.save
          render_created(SpamRuleSerializer.new(new_rule).as_json)
        else
          render_validation_error(new_rule, "The spam rule could not be created.")
        end
      end

      def update
        if spam_rule.update(resource_params(:kind, :match_type, :value, :action, :enabled))
          render_data(SpamRuleSerializer.new(spam_rule).as_json)
        else
          render_validation_error(spam_rule, "The spam rule could not be updated.")
        end
      end

      def destroy
        spam_rule.destroy
        render_no_content
      end

      # Per-rule statistics. For each enabled rule, report how many messages
      # matched it and the breakdown by the action that was applied. Counts come
      # from the server's message database where the matched rule is recorded on
      # each message.
      def statistics
        rules = domain.spam_rules.where(enabled: true).order(:kind, :match_type, :value)
        stats = rules.map do |rule|
          matched = message_db_count(rule.id)
          {
            uuid: rule.uuid,
            kind: rule.kind,
            match_type: rule.match_type,
            value: rule.value,
            action: rule.action,
            matched_count: matched[:total],
            by_action: matched[:by_action]
          }
        end
        render_data(stats)
      end

      private

      def message_db_count(rule_id)
        total = 0
        by_action = Hash.new(0)
        message_dbs.each do |message_db|
          rows = message_db.query(
            "SELECT matched_rule_action, COUNT(*) AS n FROM `#{message_db.database_name}`.`messages` " \
            "WHERE matched_rule_id = #{rule_id.to_i} GROUP BY matched_rule_action"
          )
          rows.each do |row|
            total += row["n"].to_i
            by_action[row["matched_rule_action"]] += row["n"].to_i
          end
        end
        { total: total, by_action: by_action }
      end

      # The message database(s) whose messages belong to this domain's scope: a
      # single server when the domain is server-scoped, otherwise all of the
      # organization's servers.
      def message_dbs
        @message_dbs ||= server ? [server.message_db] : organization.servers.map(&:message_db)
      end

      def domain
        @domain ||= domain_scope.find_by_uuid!(params[:domain_uuid])
      end

      def load_domain
        domain
      end

      def domain_scope
        server ? server.domains : organization.domains
      end

      def server
        return nil if params[:server_permalink].blank?

        @server ||= organization.servers.present.find_by_permalink!(params[:server_permalink])
      end

      def load_server
        server
      end

      def spam_rule
        @spam_rule ||= domain.spam_rules.find_by_uuid!(params[:uuid])
      end

    end
  end
end
