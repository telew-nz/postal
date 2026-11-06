# frozen_string_literal: true

Rails.application.routes.draw do
  # Legacy API Routes
  match "/api/v1/send/message" => "legacy_api/send#message", via: [:get, :post, :patch, :put]
  match "/api/v1/send/raw" => "legacy_api/send#raw", via: [:get, :post, :patch, :put]
  match "/api/v1/messages/message" => "legacy_api/messages#message", via: [:get, :post, :patch, :put]
  match "/api/v1/messages/deliveries" => "legacy_api/messages#deliveries", via: [:get, :post, :patch, :put]

  # The management API. This is a JSON API which allows almost everything that
  # the web UI allows to be managed over HTTP. It is authenticated using an API
  # token rather than a session. The legacy API above retains the /api/v1 prefix
  # so this API is mounted at /api/v2.
  namespace :api, defaults: { format: :json } do
    namespace :v2 do
      # The OpenAPI specification for this API. This is not authenticated.
      get "spec" => "spec#show"

      # Details of the user who owns the API token used for the request.
      get "me" => "session#show"

      # API tokens belonging to the authenticated user.
      resources :tokens, only: [:index, :create, :destroy]

      # IP pools are read-only. They are needed because servers and IP pool
      # rules both reference an IP pool by ID.
      resources :ip_pools, only: [:index]

      resources :organizations, only: [:index, :create]

      scope "organizations/:organization_permalink", as: :organization do
        get "" => "organizations#show"
        patch "" => "organizations#update"
        delete "" => "organizations#destroy"

        resources :domains, only: [:index, :create]
        scope "domains/:domain_uuid" do
          get "" => "domains#show"
          delete "" => "domains#destroy"
          post "verify" => "domains#verify"
          post "check" => "domains#check"
          get "dns_records" => "domains#dns_records"
          resources :spam_rules, only: [:index, :create] do
            get "statistics", on: :collection
          end
          scope "spam_rules/:uuid" do
            get "" => "spam_rules#show"
            patch "" => "spam_rules#update"
            put "" => "spam_rules#update"
            delete "" => "spam_rules#destroy"
          end
        end

        resources :ip_pool_rules, only: [:index, :create]
        scope "ip_pool_rules/:uuid" do
          get "" => "ip_pool_rules#show"
          patch "" => "ip_pool_rules#update"
          put "" => "ip_pool_rules#update"
          delete "" => "ip_pool_rules#destroy"
        end

        resources :servers, only: [:index, :create]

        scope "servers/:server_permalink", as: :server do
          get "" => "servers#show"
          patch "" => "servers#update"
          put "" => "servers#update"
          delete "" => "servers#destroy"
          post "suspend" => "servers#suspend"
          post "unsuspend" => "servers#unsuspend"
          get "queue" => "servers#queue"

          resources :domains, only: [:index, :create]
          scope "domains/:domain_uuid" do
            get "" => "domains#show"
            delete "" => "domains#destroy"
            post "verify" => "domains#verify"
            post "check" => "domains#check"
            get "dns_records" => "domains#dns_records"
            resources :spam_rules, only: [:index, :create] do
              get "statistics", on: :collection
            end
            scope "spam_rules/:uuid" do
              get "" => "spam_rules#show"
              patch "" => "spam_rules#update"
              put "" => "spam_rules#update"
              delete "" => "spam_rules#destroy"
            end
          end

          resources :track_domains, only: [:index, :create]
          scope "track_domains/:uuid" do
            get "" => "track_domains#show"
            patch "" => "track_domains#update"
            put "" => "track_domains#update"
            delete "" => "track_domains#destroy"
            post "toggle_ssl" => "track_domains#toggle_ssl"
            post "check" => "track_domains#check"
          end

          resources :credentials, only: [:index, :create]
          scope "credentials/:uuid" do
            get "" => "credentials#show"
            patch "" => "credentials#update"
            put "" => "credentials#update"
            delete "" => "credentials#destroy"
          end

          resources :routes, only: [:index, :create]
          scope "routes/:uuid" do
            get "" => "routes#show"
            patch "" => "routes#update"
            put "" => "routes#update"
            delete "" => "routes#destroy"
          end

          resources :http_endpoints, only: [:index, :create]
          scope "http_endpoints/:uuid" do
            get "" => "http_endpoints#show"
            patch "" => "http_endpoints#update"
            put "" => "http_endpoints#update"
            delete "" => "http_endpoints#destroy"
          end

          resources :smtp_endpoints, only: [:index, :create]
          scope "smtp_endpoints/:uuid" do
            get "" => "smtp_endpoints#show"
            patch "" => "smtp_endpoints#update"
            put "" => "smtp_endpoints#update"
            delete "" => "smtp_endpoints#destroy"
          end

          resources :address_endpoints, only: [:index, :create]
          scope "address_endpoints/:uuid" do
            get "" => "address_endpoints#show"
            patch "" => "address_endpoints#update"
            put "" => "address_endpoints#update"
            delete "" => "address_endpoints#destroy"
          end

          resources :webhooks, only: [:index, :create]
          scope "webhooks/:uuid" do
            get "" => "webhooks#show"
            patch "" => "webhooks#update"
            put "" => "webhooks#update"
            delete "" => "webhooks#destroy"
          end

          resources :ip_pool_rules, only: [:index, :create]
          scope "ip_pool_rules/:uuid" do
            get "" => "ip_pool_rules#show"
            patch "" => "ip_pool_rules#update"
            put "" => "ip_pool_rules#update"
            delete "" => "ip_pool_rules#destroy"
          end

          resources :messages, only: [:index]
          scope "messages" do
            get "held" => "messages#held"
            get "suppressions" => "messages#suppressions"
            post "suppressions" => "messages#create_suppression"
            # The suppression address is an e-mail address so it must be able to
            # contain dots. Dynamic segments do not match dots by default
            # because the dot is normally the format separator.
            delete "suppressions/:suppression_type/:suppression_address" => "messages#destroy_suppression", constraints: { suppression_address: /[^\/]+/ }

            scope ":id" do
              get "" => "messages#show"
              get "deliveries" => "messages#deliveries"
              get "activity" => "messages#activity"
              get "spam_checks" => "messages#spam_checks"
              get "plain" => "messages#plain"
              get "html" => "messages#html"
              get "headers" => "messages#raw_headers"
              get "attachments" => "messages#attachments"
              get "attachment" => "messages#attachment"
              get "download" => "messages#download"
              post "retry" => "messages#retry"
              post "cancel_hold" => "messages#cancel_hold"
              delete "remove_from_queue" => "messages#remove_from_queue"
              post "spam_feedback" => "spam_feedback#create"
            end
          end
        end
      end
    end
  end

  scope "org/:org_permalink", as: "organization" do
    resources :domains, only: [:index, :new, :create, :destroy] do
      match :verify, on: :member, via: [:get, :post]
      get :setup, on: :member
      post :check, on: :member
      post :regenerate_dkim, on: :member
      post :cancel_dkim_regeneration, on: :member
    end
    resources :servers, except: [:index] do
      resources :domains, only: [:index, :new, :create, :destroy] do
        match :verify, on: :member, via: [:get, :post]
        get :setup, on: :member
        post :check, on: :member
        post :regenerate_dkim, on: :member
        post :cancel_dkim_regeneration, on: :member
      end
      resources :track_domains do
        post :toggle_ssl, on: :member
        post :check, on: :member
      end
      resources :credentials
      resources :routes
      resources :http_endpoints
      resources :smtp_endpoints
      resources :address_endpoints
      resources :ip_pool_rules
      resources :messages do
        get :incoming, on: :collection
        get :outgoing, on: :collection
        get :held, on: :collection
        get :activity, on: :member
        get :plain, on: :member
        get :html, on: :member
        get :html_raw, on: :member
        get :attachments, on: :member
        get :headers, on: :member
        get :attachment, on: :member
        get :download, on: :member
        get :spam_checks, on: :member
        post :retry, on: :member
        post :cancel_hold, on: :member
        get :suppressions, on: :collection
        delete :remove_from_queue, on: :member
        get :deliveries, on: :member
      end
      resources :webhooks do
        get :history, on: :collection
        get "history/:uuid", on: :collection, action: "history_request", as: "history_request"
      end
      get :limits, on: :member
      get :retention, on: :member
      get :queue, on: :member
      get :spam, on: :member
      get :delete, on: :member
      get "help/outgoing" => "help#outgoing"
      get "help/incoming" => "help#incoming"
      get :advanced, on: :member
      post :suspend, on: :member
      post :unsuspend, on: :member
    end

    resources :ip_pool_rules
    resources :ip_pools, controller: "organization_ip_pools" do
      put :assignments, on: :collection
    end
    root "servers#index"
    get "settings" => "organizations#edit"
    patch "settings" => "organizations#update"
    get "delete" => "organizations#delete"
    delete "delete" => "organizations#destroy"
  end

  resources :organizations, except: [:index]
  resources :users
  resources :ip_pools do
    resources :ip_addresses
  end

  get "settings" => "user#edit"
  patch "settings" => "user#update"
  post "persist" => "sessions#persist"

  get "login" => "sessions#new"
  post "login" => "sessions#create"
  delete "logout" => "sessions#destroy"
  match "login/reset" => "sessions#begin_password_reset", :via => [:get, :post]
  match "login/reset/:token" => "sessions#finish_password_reset", :via => [:get, :post]

  if Postal::Config.oidc.enabled?
    get "auth/oidc/callback", to: "sessions#create_from_oidc"
  end

  get ".well-known/jwks.json" => "well_known#jwks"

  get "ip" => "sessions#ip"

  root "organizations#index"
end
