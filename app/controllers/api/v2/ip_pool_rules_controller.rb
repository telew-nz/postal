# frozen_string_literal: true

module API
  module V2
    # IP pool rules can belong to an organization or to an individual server. Both
    # nestings are handled by this controller which mirrors the behaviour of the
    # web UI's IPPoolRulesController.
    class IPPoolRulesController < BaseController

      include ScopedToOrganization

      before_action :load_server, if: -> { params[:server_permalink].present? }
      before_action :load_ip_pool_rule, only: [:show, :update, :destroy]

      def index
        rules, pagination = paginate(ip_pool_rule_scope.order(:id))
        render_collection(IPPoolRuleSerializer.collection(rules), pagination)
      end

      def show
        render_data(IPPoolRuleSerializer.new(ip_pool_rule).as_json)
      end

      def create
        new_rule = ip_pool_rule_scope.build(rule_params)
        if new_rule.save
          render_created(IPPoolRuleSerializer.new(new_rule).as_json)
        else
          render_validation_error(new_rule, "The IP pool rule could not be created.")
        end
      end

      def update
        if ip_pool_rule.update(rule_params)
          render_data(IPPoolRuleSerializer.new(ip_pool_rule).as_json)
        else
          render_validation_error(ip_pool_rule, "The IP pool rule could not be updated.")
        end
      end

      def destroy
        ip_pool_rule.destroy
        render_no_content
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

      # The scope which rules are resolved within.
      #
      # @return [ActiveRecord::Relation]
      def ip_pool_rule_scope
        server ? server.ip_pool_rules : organization.ip_pool_rules
      end

      def ip_pool_rule
        @ip_pool_rule ||= ip_pool_rule_scope.find_by_uuid!(params[:uuid])
      end

      def load_ip_pool_rule
        ip_pool_rule
      end

      def rule_params
        resource_params(:from_text, :to_text, :ip_pool_id)
      end

    end
  end
end
