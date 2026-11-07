# frozen_string_literal: true

class AddScopingToUserAPITokens < ActiveRecord::Migration[7.0]

  def change
    # tier: "site" (the instance-level key) or "server" (a per-integration,
    # server-bound key). Defaults to "site" for backward compatibility with
    # existing tokens, which act as the site key.
    add_column :user_api_tokens, :tier, :string, default: "site", null: false

    # For tier "server" keys, the server this key is bound to. A server key is
    # refused for any request outside this server. nil for site keys.
    add_column :user_api_tokens, :server_id, :integer, default: nil

    # The endpoint scope of the key. "all" for site keys; for server keys one
    # of domains | spam | routes | send (or a comma-separated combination).
    add_column :user_api_tokens, :scope, :string, default: "all", null: false
  end

end
