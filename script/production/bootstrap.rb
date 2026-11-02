# frozen_string_literal: true

# Bring a fresh production-shaped installation up to a state where the API can
# be driven, without ever destroying anything which is already there.
#
# This is the opposite of script/smoke/seed.rb, which wipes its dataset on every
# run so that the assertions can rely on exact counts. This stack persists, so
# every step here is find-or-create and re-running the script is safe. That
# matters because bootstrap.ps1 runs it on every invocation and a user may also
# run it by hand after adding a service to the compose file.
#
# It prints one line of JSON prefixed with POSTAL_BOOTSTRAP so that the calling
# script can separate the result from the surrounding Rails output. The API
# token in that JSON is only present the first time it is created: only the
# SHA-256 digest of a token is stored, so it cannot be recovered later.
#
# Configuration is read from the environment:
#
#   POSTAL_ADMIN_EMAIL     e-mail address of the administrator (default admin@localhost)
#   POSTAL_ADMIN_PASSWORD  password, needed to log into the web UI (required)
#   POSTAL_ORG_PERMALINK   permalink of the organization (default production-test)
#   POSTAL_SERVER_PERMALINK permalink of the server (default production-test-server)

require "json"

MARKER = "POSTAL_BOOTSTRAP"

admin_email = ENV.fetch("POSTAL_ADMIN_EMAIL", "admin@localhost")
admin_password = ENV.fetch("POSTAL_ADMIN_PASSWORD") do
  abort "POSTAL_ADMIN_PASSWORD must be set. It is needed to log into the web UI."
end
org_permalink = ENV.fetch("POSTAL_ORG_PERMALINK", "production-test")
server_permalink = ENV.fetch("POSTAL_SERVER_PERMALINK", "production-test-server")

# The user has to be an administrator because the API exposes organization and
# IP pool management, and administrator status is also what lets a domain be
# created without a DNS check -- which is the only way domain creation can work
# on a machine with no real DNS for it.
user = User.find_by(email_address: admin_email)
created_user = user.nil?
if user.nil?
  user = User.create!(
    first_name: "Postal",
    last_name: "Administrator",
    email_address: admin_email,
    password: admin_password,
    email_verified_at: Time.now,
    admin: true
  )
end

organization = Organization.find_by(permalink: org_permalink)
created_organization = organization.nil?
organization ||= Organization.create!(
  name: "Production Test",
  permalink: org_permalink,
  owner: user,
  time_zone: "UTC"
)

# Creating a server provisions its own message database, which is a separate
# MySQL schema. That is why the database user needs rights over postal-server-%
# as well as over the main postal database.
server = Server.find_by(permalink: server_permalink)
created_server = server.nil?
server ||= Server.create!(
  organization: organization,
  name: "Production Test Server",
  permalink: server_permalink,
  mode: "Live"
)

# The bootstrap token is the one every host-side script authenticates with. It
# is deliberately long lived: the token lifecycle test creates and revokes its
# own short lived tokens rather than touching this one, so revoking it would
# lock the whole harness out.
#
# POSTAL_FORCE_NEW_TOKEN is set by bootstrap.ps1 -NewToken. It exists because the
# plain key is only ever available on the run which created it: if
# tmp/production/credentials.json is lost there is no way to read the key back
# out of the database, so the only recovery is to mint another one. The previous
# token is left active rather than being revoked here, because a harness which is
# still running against it would break, and deciding whether it should stop
# working is not this script's call.
force_new_token = ENV["POSTAL_FORCE_NEW_TOKEN"].to_s != ""
token = force_new_token ? nil : user.api_tokens.active.find_by(name: "bootstrap")
plain_key = nil
if token.nil?
  token = user.api_tokens.create!(name: "bootstrap")
  plain_key = token.plain_key
end

# An IP pool has to exist before an IP pool rule can point at one, and the API
# only exposes pools read-only: GET /api/v2/ip_pools is the sole operation, on
# the assumption that a pool corresponds to real IP addresses which an
# administrator provisions out of band. Without a pool here the whole
# ip_pool_rules surface would be unreachable, so create one the first time.
#
# use_ip_pools is false in config/postal.yml, which stops servers being assigned
# to pools but does not stop a pool existing or a rule referencing it.
pool = IPPool.find_by(name: "Default")
created_pool = pool.nil?
pool ||= IPPool.create!(name: "Default", default: false)
organization.ip_pools << pool unless organization.ip_pools.include?(pool)

# The message detail endpoints address a message by its integer id inside the
# server's own message database, and nothing in the API can create one because
# in a real installation messages arrive over SMTP. Without at least one message
# those endpoints are unreachable, so create one the first time only.
#
# Messages are never deleted here. Re-running must not orphan the id which a
# previous run already published.
#
# message_db.messages is not an ActiveRecord relation. It builds its own SQL
# from an options hash, so ordering and limiting happen there rather than by
# chaining, and a count has to be asked for explicitly.
existing_messages = server.message_db.messages(count: true).to_i
message_id = nil
if existing_messages.zero?
  mail = Mail.new
  mail.to = "recipient@example.com"
  mail.from = admin_email
  mail.subject = "Bootstrap message"
  mail.text_part = Mail::Part.new { body "Created by script/production/bootstrap.rb" }
  mail.html_part = Mail::Part.new do
    content_type "text/html; charset=UTF-8"
    body "<html><body><p>Created by bootstrap.rb</p></body></html>"
  end
  mail.attachments["example.txt"] = "Some attached content"

  message = server.message_db.new_message
  message.scope = "outgoing"
  message.rcpt_to = "recipient@example.com"
  message.mail_from = admin_email
  message.timestamp = Time.now.to_f
  message.raw_message = mail.to_s
  # Nothing is queued because the worker is behind the 'mail' profile and is not
  # running by default. A message which was queued but could never be drained
  # would sit in the queue view forever.
  message.save(queue_on_create: false)
  message.create_delivery("Sent", output: "Message sent to recipient.example.com")
  message_id = message.id
else
  message_id = server.message_db.messages(order: "id", limit: 1).first.id
end

puts "#{MARKER} " + JSON.generate({
  admin_email: user.email_address,
  admin_password: created_user ? admin_password : nil,
  token: plain_key,
  token_uuid: token.uuid,
  organization_permalink: organization.permalink,
  server_permalink: server.permalink,
  server_id: server.id,
  message_id: message_id,
  ip_pool_id: pool.id,
  created: {
    user: created_user,
    organization: created_organization,
    server: created_server,
    ip_pool: created_pool,
    token: !plain_key.nil?
  }
})
