# frozen_string_literal: true

module API
  module V2
    class TrackDomainsController < BaseController

      include ScopedToServer

      before_action :load_track_domain, only: [:show, :update, :destroy, :toggle_ssl, :check]

      def index
        track_domains, pagination = paginate(server.track_domains.order(:name, :id))
        render_collection(TrackDomainSerializer.collection(track_domains), pagination)
      end

      def show
        render_data(TrackDomainSerializer.new(track_domain).as_json)
      end

      def create
        new_track_domain = server.track_domains.build(resource_params(:name, :domain_id, :track_loads, :track_clicks, :excluded_click_domains, :ssl_enabled))
        if new_track_domain.save
          render_created(TrackDomainSerializer.new(new_track_domain).as_json)
        else
          render_validation_error(new_track_domain, "The tracking domain could not be created.")
        end
      end

      # The name of a tracking domain and the domain it belongs to cannot be
      # changed once it has been created, which matches the web UI.
      def update
        if track_domain.update(resource_params(:track_loads, :track_clicks, :excluded_click_domains, :ssl_enabled))
          render_data(TrackDomainSerializer.new(track_domain).as_json)
        else
          render_validation_error(track_domain, "The tracking domain could not be updated.")
        end
      end

      def destroy
        track_domain.destroy
        render_no_content
      end

      def toggle_ssl
        track_domain.update!(ssl_enabled: !track_domain.ssl_enabled)
        render_data(TrackDomainSerializer.new(track_domain).as_json)
      end

      def check
        ok = track_domain.check_dns
        render_data({
          ok: ok,
          track_domain: TrackDomainSerializer.new(track_domain.reload).as_json
        })
      end

      private

      def track_domain
        @track_domain ||= server.track_domains.find_by_uuid!(params[:uuid])
      end

      def load_track_domain
        track_domain
      end

    end
  end
end
