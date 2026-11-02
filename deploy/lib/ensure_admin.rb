# frozen_string_literal: true

# Create the administrator user and the first API token. Run by `./deploy.sh admin`.
#
# Find-or-create throughout, so re-running is safe and never destroys an
# installation which is already serving mail. A token which already exists is
# left alone and its key is not printed, because only the SHA-256 digest of a key
# is stored: UserAPIToken.hash_key digests the plain value and the plain value is
# held in an attr_reader which is never persisted. There is no way to read it
# back later, which is why POSTAL_FORCE_NEW_TOKEN exists.
#
# This is deliberately narrower than script/production/bootstrap.rb, which also
# creates an organization, a server, an IP pool and a synthetic message so that
# the verification harness has something to address. None of that belongs in a
# production installation: organizations and servers are the operator's to name,
# and a fabricated message would appear in the queue of a server that is really
# delivering mail.
#
# Configuration:
#
#   POSTAL_ADMIN_EMAIL       required
#   POSTAL_ADMIN_PASSWORD    required; needed to log into the web UI
#   POSTAL_ADMIN_FIRST_NAME  default "Postal"
#   POSTAL_ADMIN_LAST_NAME   default "Administrator"
#   POSTAL_TOKEN_NAME        default "deploy"
#   POSTAL_FORCE_NEW_TOKEN   any non-empty value mints a new token

require "json"

MARKER = "POSTAL_ADMIN"

admin_email = ENV.fetch("POSTAL_ADMIN_EMAIL") do
  abort "POSTAL_ADMIN_EMAIL must be set."
end

admin_password = ENV.fetch("POSTAL_ADMIN_PASSWORD") do
  abort "POSTAL_ADMIN_PASSWORD must be set. It is needed to log into the web UI."
end

token_name = ENV.fetch("POSTAL_TOKEN_NAME", "deploy")
force_new_token = !ENV["POSTAL_FORCE_NEW_TOKEN"].to_s.empty?

# admin: true is not optional here. The management API is authenticated by token
# and a token resolves to the user who owns it, inheriting everything that user
# can do -- there is no separate permission model. An organization's domains and
# servers can only be managed by a user with rights over that organization, and
# administrator status is also what allows a domain to be created without a DNS
# check. The first user therefore has to be an administrator; later ones do not.
user = User.find_by(email_address: admin_email)
created_user = user.nil?

if user.nil?
  user = User.create!(
    first_name: ENV.fetch("POSTAL_ADMIN_FIRST_NAME", "Postal"),
    last_name: ENV.fetch("POSTAL_ADMIN_LAST_NAME", "Administrator"),
    email_address: admin_email,
    password: admin_password,
    email_verified_at: Time.now,
    admin: true
  )
end

# Only active tokens are considered, so a revoked token of the same name does not
# satisfy this and a new one is minted. The active scope excludes revoked_at and
# anything past expires_at.
token = force_new_token ? nil : user.api_tokens.active.find_by(name: token_name)
plain_key = nil

if token.nil?
  token = user.api_tokens.create!(name: token_name)
  plain_key = token.plain_key
end

# Flat keys throughout. The caller extracts these with sed rather than a JSON
# parser, because jq is not something a mail server should have to have installed,
# and a nested object would make "token" ambiguous between the key and the
# created.token flag.
puts "#{MARKER} " + JSON.generate({
  admin_email: user.email_address,
  admin_id: user.id,
  # Only printed when this run created the user. Re-running does not repeat a
  # password that may since have been changed through the web UI.
  admin_password: created_user ? admin_password : nil,
  token_name: token.name,
  token_uuid: token.uuid,
  token_key_prefix: token.key_prefix,
  token: plain_key,
  organizations: user.organizations.count,
  created_user: created_user,
  created_token: !plain_key.nil?
})
