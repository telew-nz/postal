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

      private

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
