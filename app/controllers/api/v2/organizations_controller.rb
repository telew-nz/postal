# frozen_string_literal: true

module API
  module V2
    class OrganizationsController < BaseController

      include ScopedToOrganization

      skip_before_action :load_organization, only: [:index, :create]

      before_action :admin_required, only: [:create, :destroy]

      def index
        organizations, pagination = paginate(current_user.organizations_scope.order(:name, :id))
        render_collection(OrganizationSerializer.collection(organizations), pagination)
      end

      def show
        render_data(OrganizationSerializer.new(organization).as_json)
      end

      def create
        organization = Organization.new(resource_params(:name, :permalink))
        organization.owner = current_user
        if organization.save
          render_created(OrganizationSerializer.new(organization).as_json)
        else
          render_validation_error(organization, "The organization could not be created.")
        end
      end

      def update
        if organization.update(resource_params(:name, :time_zone))
          render_data(OrganizationSerializer.new(organization).as_json)
        else
          render_validation_error(organization, "The organization could not be updated.")
        end
      end

      def destroy
        unless confirmation_matches?(organization.name)
          render_error(:unprocessable_entity, "ValidationError", "The organization could not be deleted.", ["Confirm text does not match the organization name"])
          return
        end

        organization.soft_destroy
        render_no_content
      end

      private

      # Deleting an organization is destructive so the client must confirm that
      # it knows what it is deleting by echoing the name back to us. This mirrors
      # the confirmation required by the web UI.
      #
      # @param [String] name
      # @return [Boolean]
      def confirmation_matches?(name)
        params[:confirm_text].present? && params[:confirm_text].to_s.downcase.strip == name.to_s.downcase.strip
      end

    end
  end
end
