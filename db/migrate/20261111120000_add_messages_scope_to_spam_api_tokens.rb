# frozen_string_literal: true

# Reading and acting on a server's messages used to come with the "spam" scope.
# It is now a scope of its own, "messages". A server key which was minted with
# "spam" keeps what it could already do: it gains "messages" here. A key minted
# from now on gets "messages" only when it is asked for.
class AddMessagesScopeToSpamAPITokens < ActiveRecord::Migration[7.0]

  class Token < ActiveRecord::Base

    self.table_name = "user_api_tokens"

  end

  def up
    Token.where(tier: "server").find_each do |token|
      scopes = token.scope.to_s.split(",").map(&:strip)
      next unless scopes.include?("spam")
      next if scopes.include?("messages") || scopes.include?("all")

      token.update_columns(scope: (scopes + ["messages"]).join(","))
    end
  end

  def down
    Token.where(tier: "server").find_each do |token|
      scopes = token.scope.to_s.split(",").map(&:strip)
      next unless scopes.include?("messages")

      token.update_columns(scope: (scopes - ["messages"]).join(","))
    end
  end

end
