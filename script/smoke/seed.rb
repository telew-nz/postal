# frozen_string_literal: true

# Seed a minimal, deterministic dataset for the smoke test.
#
# This runs inside the smoke container with `rails runner` so it writes to the
# same database the web server is reading from. The credentials the test runner
# needs are printed as a single line of JSON prefixed with a marker so the
# calling shell script can extract it from the surrounding Rails output.

require "json"

MARKER = "SMOKE_SEED"

# Build a multipart raw message with an attachment so that the plain, html and
# attachment endpoints of the API each have something real to return.
#
# @param [String] to
# @param [String] from
# @param [String] subject
# @return [Mail::Message]
def smoke_mail(to, from, subject)
  mail = Mail.new
  mail.to = to
  mail.from = from
  mail.subject = subject
  mail.text_part = Mail::Part.new { body "Hello world!" }
  mail.html_part = Mail::Part.new do
    content_type "text/html; charset=UTF-8"
    body "<html><body><p>Hello world!</p></body></html>"
  end
  mail.attachments["example.txt"] = "Some attached content"
  mail
end

# Save a message into the server's own message database. Every message the smoke
# test needs is outgoing and sent by the seeded user, so those are the defaults.
#
# @param [Server] server
# @param [String] to the recipient
# @param [String] subject
# @param [String] scope
# @return [Postal::MessageDB::Message]
def smoke_message(server, to:, subject:, scope: "outgoing", from: "smoke@example.com")
  message = server.message_db.new_message
  message.scope = scope
  message.rcpt_to = to
  message.mail_from = from
  message.timestamp = Time.now.to_f
  message.raw_message = smoke_mail(to, from, subject).to_s
  # The queue is written to explicitly below for the one message which needs an
  # entry in it, and there is no message router running in this stack to do the
  # work that queueing on create would otherwise trigger.
  message.save(queue_on_create: false)
  message
end

# Wipe any previous run so the script is idempotent. Order matters because of
# the foreign keys and the per-server message databases. An IP pool cannot be
# destroyed while a server still points at it, so it goes last.
Server.where(permalink: "smoke-server").each do |server|
  # The message database is a separate schema and may already have been dropped
  # by hand or by an interrupted previous run. Either way the row has to go.
  begin
    server.message_db.provisioner.drop
  rescue StandardError => e
    puts "#{MARKER}_WARN could not drop the message database for #{server.permalink}: #{e.class}"
  end
  server.destroy
end
Organization.where(permalink: "smoke").each(&:destroy)
User.where(email_address: "smoke@example.com").each(&:destroy)
IPPool.where(name: "Smoke Pool").each(&:destroy)
IPPool.where(name: "Smoke Second Pool").each(&:destroy)

user = User.create!(
  first_name: "Smoke",
  last_name: "Test",
  email_address: "smoke@example.com",
  password: "smoke-test-password",
  email_verified_at: Time.now,
  admin: true
)

organization = Organization.create!(
  name: "Smoke Test Org",
  permalink: "smoke",
  owner: user,
  time_zone: "UTC"
)

server = Server.create!(
  organization: organization,
  name: "Smoke Server",
  permalink: "smoke-server",
  mode: "Live"
)

token = user.api_tokens.create!(name: "Smoke Test")

# IP pool rules and servers both reference a pool by its integer ID. The test
# discovers that ID through GET /api/v2/ip_pools rather than being told it here,
# which is the point: the collection is the only place a client can find one.
# IPPoolRule validates that the pool belongs to the rule's organization, so the
# first pool is attached to the seeded one and the second is left unattached for
# the negative case.
pool = IPPool.create!(name: "Smoke Pool", default: false)
IPPool.create!(name: "Smoke Second Pool", default: false)
organization.ip_pools << pool

# Messages live in the server's own message database rather than the main one,
# and no operation in the API creates one because in a real installation they
# arrive over SMTP. Without seeding them here the whole message detail surface
# of the API would be unreachable from the smoke test.
#
# One message is in each of the states the API treats specially: sent, held and
# waiting in the queue.
sent_message = smoke_message(server, to: "recipient@example.com", subject: "Smoke test sent message")
# Writing a delivery attempt is what sets the status, and it is also what makes
# the deliveries and activity collections non-empty.
sent_message.create_delivery("Sent", output: "Message sent to recipient.example.com")
sent_message.update(inspected: true, spam_score: 0.1)
sent_message.database.insert_multi(:spam_checks, [:message_id, :code, :score, :description],
                                   [[sent_message.id, "SPAMASSASSIN", 0.1, "The message does not look like spam"]])

held_message = smoke_message(server, to: "held@example.com", subject: "Smoke test held message")
held_message.create_delivery("Held", details: "The message was held by the smoke test seed")

queued_message = smoke_message(server, to: "queued@example.com", subject: "Smoke test queued message")
queued_message.add_to_message_queue

puts "#{MARKER} " + JSON.generate({
  token: token.plain_key,
  organization_permalink: organization.permalink,
  server_permalink: server.permalink,
  user_email: user.email_address,
  server_id: server.id,
  sent_message_id: sent_message.id,
  held_message_id: held_message.id,
  queued_message_id: queued_message.id
})
