#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end smoke test for the Postal management API.
#
# Unlike the RSpec request specs, which drive the Rails application in-process
# through Rack::Test, this script talks to a real Puma server over a real TCP
# socket from a separate container. It exists to catch the class of problem
# which only appears once the application is actually deployed: it will not boot
# in production mode, the migrations were never applied, the router behaves
# differently behind a real server, and so on.
#
# Every response is also recorded to a JSONL file so that the contract checker
# (script/smoke/validate_contract.py) can verify each one against the schema
# which doc/api/openapi.yaml declares for it.
#
# Configuration is read from the environment:
#
#   POSTAL_URL         base URL of the running server (e.g. http://postal:5000)
#   POSTAL_TOKEN       API token to authenticate with
#   ORG_PERMALINK      permalink of the seeded organization
#   SERVER_PERMALINK   permalink of the seeded server
#   SENT_MESSAGE_ID    id of the seeded message which has been sent
#   HELD_MESSAGE_ID    id of the seeded message which is being held
#   QUEUED_MESSAGE_ID  id of the seeded message which is waiting in the queue
#   SMOKE_RECORDINGS   path to write the response recordings to

require "json"
require "net/http"
require "uri"

BASE_URL = ENV.fetch("POSTAL_URL")
TOKEN = ENV.fetch("POSTAL_TOKEN")
ORG = ENV.fetch("ORG_PERMALINK")
SERVER = ENV.fetch("SERVER_PERMALINK")
RECORDINGS = ENV.fetch("SMOKE_RECORDINGS", "/tmp/smoke-recordings.jsonl")

# The messages which script/smoke/seed.rb put into the server's message
# database. Messages cannot be created through the API because in a real
# installation they arrive over SMTP, so these ids come from the seed rather
# than from an earlier response.
SENT_MESSAGE_ID = ENV.fetch("SENT_MESSAGE_ID")
HELD_MESSAGE_ID = ENV.fetch("HELD_MESSAGE_ID")
QUEUED_MESSAGE_ID = ENV.fetch("QUEUED_MESSAGE_ID")

# How long to wait for the web server to start answering requests.
BOOT_TIMEOUT = Integer(ENV.fetch("SMOKE_BOOT_TIMEOUT", "180"))

# The header which carries the API token. This must match
# API::V2::BaseController::API_TOKEN_HEADER and the ApiKeyAuth security scheme
# declared in doc/api/openapi.yaml.
API_TOKEN_HEADER = "X-Postal-API-Key"

$passed = 0
$failures = []
$recording = File.open(RECORDINGS, "w")

# Perform a request against the API and check the outcome.
#
# The path is given as an OpenAPI style template so that the recording can be
# matched back up with the operation which produced it. Values for the path
# parameters are substituted in to build the real URL.
#
# @param [Symbol] method the HTTP verb to use
# @param [String] template the path template, e.g. "/api/v2/organizations/{organization_permalink}"
# @param [Hash] params values for the path parameters in the template
# @param [Hash, nil] query values for the query string
# @param [Hash, nil] body a JSON request body
# @param [Integer, Array<Integer>] expect the status code(s) which count as a pass
# @param [String, nil] description what is being verified, used in the output
# @param [String, nil] token the API token to send, or nil for no authentication
# @yieldparam [Hash] the decoded response body
# @return [Integer] the status code which was returned
def api(method, template, params: {}, query: nil, body: nil, expect: 200, description: nil, token: TOKEN)
  path = template.dup
  params.each { |key, value| path.gsub!("{#{key}}", value.to_s) }
  path = "#{path}?#{URI.encode_www_form(query)}" if query

  description ||= "#{method.to_s.upcase} #{template}"
  expected = Array(expect)

  uri = URI.join(BASE_URL, path)
  response = send_request(method, uri, body, token)
  parsed = parse_body(response)

  record(template: template, method: method, path: path, request_body: body,
         response: response, parsed: parsed)

  if expected.include?(response.code.to_i)
    $passed += 1
    puts "  \e[32mPASS\e[0m #{description} (#{response.code})"
    # Only inspect the body when the request behaved as expected. A block which
    # runs after an unexpected status pulls values out of an error envelope and
    # then fails again in confusing ways further down the script.
    yield parsed if block_given? && parsed
  else
    $failures << "#{description}: expected #{expected.join(' or ')}, got #{response.code} #{truncate(response.body)}"
    puts "  \e[31mFAIL\e[0m #{description}: expected #{expected.join(' or ')}, got #{response.code}"
    puts "       #{truncate(response.body, 400)}"
  end

  response.code.to_i
end

# Assert that a condition holds.
#
# @param [String] description what is being verified
# @param [Boolean] condition whether the assertion passed
# @return [void]
def assert(description, condition)
  if condition
    $passed += 1
    puts "  \e[32mPASS\e[0m #{description}"
  else
    $failures << description
    puts "  \e[31mFAIL\e[0m #{description}"
  end
end

# Wait for the web server to start responding.
#
# @return [void]
def wait_for_server
  print "Waiting for #{BASE_URL}"
  deadline = Time.now + BOOT_TIMEOUT
  loop do
    begin
      response = send_request(:get, URI.join(BASE_URL, "/api/v2/spec"), nil, nil)
      if response.code.to_i == 200
        puts " up!"
        return
      end
    rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout
      # not listening yet. EOFError is not listed because it is already an
      # IOError, and Net::*Timeout are not subclasses of either.
    end

    if Time.now > deadline
      puts " FAIL"
      abort "ERROR: #{BASE_URL} did not become ready within #{BOOT_TIMEOUT}s"
    end

    print "."
    sleep 1
  end
end

# Send a single HTTP request.
#
# Net::HTTP ships a request class for every verb the API uses, including Patch,
# so those are used directly rather than building a generic request.
def send_request(method, uri, body, token)
  klass = Net::HTTP.const_get(method.to_s.capitalize)
  request = klass.new(uri.request_uri)
  request["Accept"] = "application/json"
  request[API_TOKEN_HEADER] = token if token
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end

  http = Net::HTTP.new(uri.hostname, uri.port)
  http.open_timeout = 10
  http.read_timeout = 60
  http.start { |connection| connection.request(request) }
end

def parse_body(response)
  return nil if response.body.nil? || response.body.empty?

  JSON.parse(response.body)
rescue JSON::ParserError
  nil
end

# Write one response to the recording file which the contract checker reads.
# Keyword arguments are used so that the call site names each value; there are
# too many of them for a positional list to be readable.
def record(template:, method:, path:, request_body:, response:, parsed:)
  $recording.puts JSON.generate({
    method: method.to_s.upcase,
    path_template: template,
    path: path,
    request_body: request_body,
    status: response.code.to_i,
    content_type: response["Content-Type"].to_s,
    body: parsed,
    body_text: text_body(response, parsed)
  })
  $recording.flush
end

# The body of a response which was not JSON, so that the contract checker can
# still validate the two endpoints which answer with the raw message and with
# attachment content. Only recorded when it decodes as UTF-8, because a
# genuinely binary attachment would otherwise corrupt the recording file.
#
# @param [Net::HTTPResponse] response
# @param [Hash, nil] parsed the decoded JSON body, when there was one
# @return [String, nil]
def text_body(response, parsed)
  return nil unless parsed.nil? && response.body

  text = response.body.dup.force_encoding("UTF-8")
  text.valid_encoding? ? text : nil
end

def truncate(value, length = 200)
  text = value.to_s.gsub(/\s+/, " ")
  text.length > length ? "#{text[0, length]}..." : text
end

# ---------------------------------------------------------------------------

wait_for_server

ORG_BASE = "/api/v2/organizations/{organization_permalink}"
SERVER_BASE = "#{ORG_BASE}/servers/{server_permalink}".freeze
ORG_PARAMS = { organization_permalink: ORG }.freeze
SERVER_PARAMS = { organization_permalink: ORG, server_permalink: SERVER }.freeze

puts
puts "== Unauthenticated access =="

# The specification is public so that clients can discover the API without
# already holding a token.
api :get, "/api/v2/spec", token: nil, expect: 200, description: "GET /spec is public" do |body|
  assert "  the document declares OpenAPI 3", body.is_a?(Hash) && body["openapi"].to_s.start_with?("3.")
end

api :get, "/api/v2/me", token: nil, expect: 401, description: "GET /me without a token is rejected"
api :get, "/api/v2/me", token: "pst_not_a_real_token", expect: 401, description: "GET /me with a bad token is rejected"

puts
puts "== Session and tokens =="

api :get, "/api/v2/me", expect: 200 do |body|
  assert "  /me returns the owner of the token", body.dig("data", "user", "email_address") == "smoke@example.com"
  organizations = body.dig("data", "organizations")
  assert("  /me lists the organizations the token can address",
         organizations.is_a?(Array) && organizations.any? { |o| o["permalink"] == ORG })
end

api :get, "/api/v2/tokens", expect: 200 do |body|
  assert "  /tokens lists the seeded token", body["data"].is_a?(Array) && !body["data"].empty?
end

new_token_id = nil
api :post, "/api/v2/tokens", body: { name: "Smoke Created Token" }, expect: 201,
                             description: "POST /tokens creates a token" do |body|
  # UserAPITokenSerializer exposes `uuid` and TokensController#destroy looks the
  # record up with find_by_uuid!, so there is no numeric id to delete by.
  new_token_id = body.dig("data", "uuid")
  assert "  the plain key is revealed once", body.dig("data", "key").to_s.start_with?("pst_")
end

api :delete, "/api/v2/tokens/{id}", params: { id: new_token_id }, expect: 204,
                                    description: "DELETE /tokens/:id revokes the token it just made"

# Servers and IP pool rules both take an integer `ip_pool_id`, and this
# collection is the only place a client can discover one. Reading the IDs back
# out of the response is therefore part of the test rather than a set up step.
ip_pool_id = nil
foreign_ip_pool_id = nil
api :get, "/api/v2/ip_pools", expect: 200 do |body|
  pools = body["data"]
  ip_pool_id = pools.find { |pool| pool["name"] == "Smoke Pool" }&.fetch("id", nil)
  foreign_ip_pool_id = pools.find { |pool| pool["name"] == "Smoke Second Pool" }&.fetch("id", nil)
  assert "  /ip_pools exposes the integer id which ip_pool_id refers to", ip_pool_id.is_a?(Integer)
end

assert "  a second pool was found for the negative case", foreign_ip_pool_id.is_a?(Integer)

puts
puts "== Organizations =="

api :get, "/api/v2/organizations", expect: 200 do |body|
  assert("  /organizations includes the seeded org", body["data"].any? { |o| o["permalink"] == ORG })
end

api :get, ORG_BASE, params: ORG_PARAMS, expect: 200

api :get, ORG_BASE, params: { organization_permalink: "does-not-exist" }, expect: 404,
                    description: "GET an unknown organization returns 404"

api :patch, ORG_BASE, params: ORG_PARAMS, body: { name: "Smoke Test Org Renamed" }, expect: 200,
                      description: "PATCH /organizations/:permalink renames it" do |body|
  assert "  the new name is returned", body.dig("data", "name") == "Smoke Test Org Renamed"
end

created_org = nil
api :post, "/api/v2/organizations",
    body: { name: "Smoke Second Org", permalink: "smoke-second" },
    expect: 201, description: "POST /organizations creates an organization" do |body|
  created_org = body.dig("data", "permalink")
end

# Deleting is destructive so the client has to echo the name back.
api :delete, ORG_BASE, params: { organization_permalink: created_org }, expect: 422,
                       description: "DELETE without confirm_text is refused"

api :delete, ORG_BASE, params: { organization_permalink: created_org },
                       query: { confirm_text: "Smoke Second Org" }, expect: 204,
                       description: "DELETE /organizations/:permalink removes the one it just made"

api :post, "/api/v2/organizations", body: { permalink: "no-name" }, expect: 422,
                                    description: "POST /organizations without a name returns 422"

api :get, "#{ORG_BASE}/domains", params: ORG_PARAMS, expect: 200
api :get, "#{ORG_BASE}/ip_pool_rules", params: ORG_PARAMS, expect: 200

puts
puts "== IP pool rule lifecycle =="

IP_RULE_BASE = "#{ORG_BASE}/ip_pool_rules".freeze
SERVER_IP_RULE_BASE = "#{SERVER_BASE}/ip_pool_rules".freeze
ip_rule_uuid = nil
server_ip_rule_uuid = nil

api :post, IP_RULE_BASE, params: ORG_PARAMS,
                         body: { from_text: "sender@example.com", to_text: "recipient@example.com",
                                 ip_pool_id: ip_pool_id },
                         expect: 201, description: "POST /organizations/:permalink/ip_pool_rules creates a rule" do |body|
  ip_rule_uuid = body.dig("data", "uuid")
  assert "  the pool was attached", body.dig("data", "ip_pool_id") == ip_pool_id
  assert "  the pool name is rendered next to its id", body.dig("data", "ip_pool_name") == "Smoke Pool"
  assert "  the owner is the organization", body.dig("data", "owner_type") == "Organization"
end

api :get, "#{IP_RULE_BASE}/{uuid}", params: ORG_PARAMS.merge(uuid: ip_rule_uuid), expect: 200

api :patch, "#{IP_RULE_BASE}/{uuid}", params: ORG_PARAMS.merge(uuid: ip_rule_uuid),
                                      body: { from_text: "other@example.com" }, expect: 200,
                                      description: "PATCH /ip_pool_rules/:uuid updates it" do |body|
  assert "  from_text changed", body.dig("data", "from_text") == "other@example.com"
end

api :put, "#{IP_RULE_BASE}/{uuid}", params: ORG_PARAMS.merge(uuid: ip_rule_uuid),
                                    body: { to_text: "changed@example.com" }, expect: 200,
                                    description: "PUT /ip_pool_rules/:uuid updates it" do |body|
  assert "  to_text changed", body.dig("data", "to_text") == "changed@example.com"
end

# IPPoolRule#validate_ip_pool_belongs_to_organization rejects a pool which the
# organization has not been given access to.
api :post, IP_RULE_BASE, params: ORG_PARAMS,
                         body: { from_text: "x@example.com", ip_pool_id: foreign_ip_pool_id },
                         expect: 422, description: "a pool which is not the organization's returns 422"

api :post, IP_RULE_BASE, params: ORG_PARAMS, body: { ip_pool_id: ip_pool_id },
                         expect: 422, description: "a rule with no conditions returns 422"

api :post, SERVER_IP_RULE_BASE, params: SERVER_PARAMS,
                                body: { from_text: "server@example.com", ip_pool_id: ip_pool_id },
                                expect: 201, description: "POST /servers/:permalink/ip_pool_rules creates a rule" do |body|
  server_ip_rule_uuid = body.dig("data", "uuid")
  assert "  the owner is the server", body.dig("data", "owner_type") == "Server"
end

api :get, "#{SERVER_BASE}/ip_pool_rules", params: SERVER_PARAMS, expect: 200 do |body|
  assert("  the server scoped collection contains the new rule",
         body["data"].any? { |rule| rule["uuid"] == server_ip_rule_uuid })
end

api :get, "#{SERVER_IP_RULE_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: server_ip_rule_uuid), expect: 200

# Only to_text is sent here and only from_text below. A partial update has to
# leave the other condition alone: from_text and to_text are independently
# nullable but at least one of them must survive or the rule stops matching.
api :patch, "#{SERVER_IP_RULE_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: server_ip_rule_uuid),
                                             body: { to_text: "server-recipient@example.com" }, expect: 200,
                                             description: "PATCH /servers/:permalink/ip_pool_rules/:uuid updates it" do |body|
  assert "  to_text was set", body.dig("data", "to_text") == "server-recipient@example.com"
  assert "  from_text was left alone", body.dig("data", "from_text") == "server@example.com"
end

api :put, "#{SERVER_IP_RULE_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: server_ip_rule_uuid),
                                           body: { from_text: "server-sender@example.com" }, expect: 200,
                                           description: "PUT /servers/:permalink/ip_pool_rules/:uuid updates it" do |body|
  assert "  from_text changed", body.dig("data", "from_text") == "server-sender@example.com"
end

api :delete, "#{SERVER_IP_RULE_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: server_ip_rule_uuid), expect: 204
api :delete, "#{IP_RULE_BASE}/{uuid}", params: ORG_PARAMS.merge(uuid: ip_rule_uuid), expect: 204

api :get, "#{ORG_BASE}/servers", params: ORG_PARAMS, expect: 200 do |body|
  assert("  /servers includes the seeded server", body["data"].any? { |s| s["permalink"] == SERVER })
  assert "  the collection carries pagination", body.key?("pagination")
end

puts
puts "== Domains =="

# Routes and track domains both identify their parent domain by its integer ID
# rather than by UUID, so the domain has to be created first and its id read
# back out of the response. This is also what proves that the id is exposed at
# all: without it neither resource can be created through the API.
DOMAIN_BASE = "#{ORG_BASE}/domains".freeze
DOMAIN_PATH = "#{ORG_BASE}/domains/{domain_uuid}".freeze
domain_id = nil
domain_uuid = nil

api :post, DOMAIN_BASE, params: ORG_PARAMS, body: { name: "smoke.example.com" },
                        expect: 201, description: "POST /organizations/:permalink/domains creates a domain" do |body|
  domain_id = body.dig("data", "id")
  domain_uuid = body.dig("data", "uuid")
  assert "  the integer domain_id is exposed for routes and track domains", domain_id.is_a?(Integer)
  assert "  an administrator's domain is verified without a DNS check",
         body.dig("data", "verified") == true
end

api :get, DOMAIN_PATH, params: ORG_PARAMS.merge(domain_uuid: domain_uuid), expect: 200 do |body|
  assert "  GET returns the same domain", body.dig("data", "name") == "smoke.example.com"
end

api :get, "#{DOMAIN_PATH}/dns_records", params: ORG_PARAMS.merge(domain_uuid: domain_uuid), expect: 200

api :post, "#{DOMAIN_PATH}/check", params: ORG_PARAMS.merge(domain_uuid: domain_uuid),
                                   expect: [200, 422],
                                   description: "POST /domains/:uuid/check runs a DNS check"

# An administrator's domain is verified on creation, so asking to verify it
# again is refused rather than being silently accepted.
api :post, "#{DOMAIN_PATH}/verify", params: ORG_PARAMS.merge(domain_uuid: domain_uuid),
                                    expect: 422,
                                    description: "POST /domains/:uuid/verify on a verified domain returns 422"

assert "  a domain_id was discovered for the rest of the run", domain_id.is_a?(Integer)

puts
puts "== Servers =="

api :get, SERVER_BASE, params: SERVER_PARAMS, expect: 200

created_server = nil
api :post, "#{ORG_BASE}/servers", params: ORG_PARAMS,
                                  body: { name: "Smoke Second Server", mode: "Live" },
                                  expect: 201, description: "POST /servers creates a server" do |body|
  # The permalink is derived from the name rather than being supplied.
  created_server = body.dig("data", "permalink")
  assert "  the permalink was derived from the name", created_server == "smoke-second-server"
end

second = { organization_permalink: ORG, server_permalink: created_server }
api :get, SERVER_BASE, params: second, expect: 200
api :post, "#{SERVER_BASE}/suspend", params: second, body: { reason: "smoke test" }, expect: 200
api :post, "#{SERVER_BASE}/unsuspend", params: second, expect: 200
api :delete, SERVER_BASE, params: second, query: { confirm_text: "Smoke Second Server" }, expect: 204,
                          description: "DELETE /servers/:permalink removes the one it just made"

api :patch, SERVER_BASE, params: SERVER_PARAMS, body: { name: "Smoke Server Renamed" },
                         expect: 200, description: "PATCH /servers/:permalink renames it" do |body|
  assert "  the new name is returned", body.dig("data", "name") == "Smoke Server Renamed"
end

api :put, SERVER_BASE, params: SERVER_PARAMS, body: { name: "Smoke Server" },
                       expect: 200, description: "PUT /servers/:permalink updates it" do |body|
  assert "  PUT behaves like PATCH", body.dig("data", "name") == "Smoke Server"
  assert "  the permalink did not change", body.dig("data", "permalink") == SERVER
end

api :get, "#{SERVER_BASE}/queue", params: SERVER_PARAMS, expect: 200,
                                  description: "GET /queue lists the messages waiting to be sent" do |body|
  assert("  the message the seed queued is listed",
         body["data"].any? { |entry| entry["message_id"] == QUEUED_MESSAGE_ID.to_i })
end

puts
puts "== Server sub-resources =="

%w[domains track_domains credentials routes http_endpoints smtp_endpoints
   address_endpoints ip_pool_rules messages].each do |resource|
  api :get, "#{SERVER_BASE}/#{resource}", params: SERVER_PARAMS, expect: 200,
                                          description: "GET /servers/:permalink/#{resource}"
end

api :get, "#{SERVER_BASE}/messages/held", params: SERVER_PARAMS, expect: 200,
                                          description: "GET /messages/held lists the messages being held" do |body|
  assert("  the message the seed held is listed",
         body["data"].any? { |message| message["id"] == HELD_MESSAGE_ID.to_i })
end
api :get, "#{SERVER_BASE}/messages/suppressions", params: SERVER_PARAMS, expect: 200

puts
puts "== Credential lifecycle =="

CREDENTIAL_BASE = "#{SERVER_BASE}/credentials".freeze
credential_uuid = nil

api :post, CREDENTIAL_BASE, params: SERVER_PARAMS,
                            body: { type: "SMTP", name: "smoke-user", key: "smoke-password" },
                            expect: 201, description: "POST /credentials creates a credential" do |body|
  credential_uuid = body.dig("data", "uuid")
  # Credential#generate_key runs before validation and overwrites whatever the
  # client sent for every type except SMTP-IP, so the supplied key must not
  # survive. Asserting the opposite would pin down a security regression.
  generated = body.dig("data", "key").to_s
  assert "  the supplied key was replaced by a generated one",
         !generated.empty? && generated != "smoke-password"
  assert "  usage_type is Unused for a credential which has never been used",
         body.dig("data", "usage_type") == "Unused"
end

# SMTP-IP credentials are the one type where the client chooses the key, and
# Credential#validate_key_for_smtp_ip requires it to be a valid IP address.
api :post, CREDENTIAL_BASE, params: SERVER_PARAMS,
                            body: { type: "SMTP-IP", name: "smoke-ip", key: "192.0.2.1" },
                            expect: 201, description: "POST /credentials creates an SMTP-IP credential" do |body|
  assert "  an SMTP-IP credential keeps the key it was given",
         body.dig("data", "key") == "192.0.2.1"
end

api :get, CREDENTIAL_BASE, params: SERVER_PARAMS, expect: 200 do |body|
  assert("  the collection redacts keys", body["data"].none? { |c| c.key?("key") })
end

api :get, "#{CREDENTIAL_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: credential_uuid), expect: 200

api :patch, "#{CREDENTIAL_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: credential_uuid),
                                         body: { name: "smoke-user-2" }, expect: 200,
                                         description: "PATCH /credentials/:uuid updates it" do |body|
  assert "  the name changed", body.dig("data", "name") == "smoke-user-2"
end

api :put, "#{CREDENTIAL_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: credential_uuid),
                                       body: { name: "smoke-user-3" }, expect: 200,
                                       description: "PUT /credentials/:uuid updates it" do |body|
  assert "  PUT behaves like PATCH", body.dig("data", "name") == "smoke-user-3"
end

api :delete, "#{CREDENTIAL_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: credential_uuid), expect: 204

puts
puts "== HTTP endpoint lifecycle =="

# HTTPEndpoint#format must survive the round trip. The API is mounted with a
# routing default of format: json which used to clobber it, so this is a
# regression guard for the resource_params fix.
HTTP_BASE = "#{SERVER_BASE}/http_endpoints".freeze
http_uuid = nil

api :post, HTTP_BASE, params: SERVER_PARAMS,
                      body: { name: "Smoke HTTP", url: "https://example.com/hook",
                              encoding: "BodyAsJSON", format: "RawMessage" },
                      expect: 201, description: "POST /http_endpoints creates an endpoint" do |body|
  http_uuid = body.dig("data", "uuid")
  assert "  format is RawMessage and was not clobbered by the route default",
         body.dig("data", "format") == "RawMessage"
  assert "  encoding round trips", body.dig("data", "encoding") == "BodyAsJSON"
  assert "  timeout defaults to 5", body.dig("data", "timeout") == 5
  assert "  strip_replies defaults to false", body.dig("data", "strip_replies") == false
end

api :get, "#{HTTP_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: http_uuid), expect: 200 do |body|
  assert "  GET returns the same format", body.dig("data", "format") == "RawMessage"
end

api :patch, "#{HTTP_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: http_uuid),
                                   body: { encoding: "FormData", timeout: 30 }, expect: 200,
                                   description: "PATCH /http_endpoints/:uuid updates it" do |body|
  assert "  the encoding changed", body.dig("data", "encoding") == "FormData"
  assert "  the timeout changed", body.dig("data", "timeout") == 30
  assert "  the format was left alone", body.dig("data", "format") == "RawMessage"
end

api :put, "#{HTTP_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: http_uuid),
                                 body: { encoding: "BodyAsJSON" }, expect: 200,
                                 description: "PUT /http_endpoints/:uuid updates it"

# timeout is validated as being between 5 and 60 seconds.
api :patch, "#{HTTP_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: http_uuid),
                                   body: { timeout: 600 }, expect: 422,
                                   description: "a timeout above the maximum returns 422"

# encoding and format have no default and are validated for inclusion, so they
# are required in practice even though the column allows null.
api :post, HTTP_BASE, params: SERVER_PARAMS,
                      body: { name: "Smoke HTTP", url: "https://example.com/hook" },
                      expect: 422, description: "POST /http_endpoints without an encoding returns 422"

puts
puts "== SMTP endpoint lifecycle =="

SMTP_BASE = "#{SERVER_BASE}/smtp_endpoints".freeze
smtp_uuid = nil

api :post, SMTP_BASE, params: SERVER_PARAMS,
                      body: { name: "Smoke SMTP", hostname: "smtp.example.com", port: 2525,
                              ssl_mode: "STARTTLS" },
                      expect: 201, description: "POST /smtp_endpoints creates an endpoint" do |body|
  smtp_uuid = body.dig("data", "uuid")
  assert "  ssl_mode round trips", body.dig("data", "ssl_mode") == "STARTTLS"
  assert "  port round trips", body.dig("data", "port") == 2525
end

api :patch, "#{SMTP_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: smtp_uuid),
                                   body: { ssl_mode: "TLS" }, expect: 200,
                                   description: "PATCH /smtp_endpoints changes the ssl mode" do |body|
  assert "  the new ssl_mode is returned", body.dig("data", "ssl_mode") == "TLS"
end

api :put, "#{SMTP_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: smtp_uuid),
                                 body: { ssl_mode: "None" }, expect: 200,
                                 description: "PUT /smtp_endpoints updates it" do |body|
  assert "  PUT behaves like PATCH", body.dig("data", "ssl_mode") == "None"
end

api :get, "#{SMTP_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: smtp_uuid), expect: 200

# SMTPEndpoint validates ssl_mode for inclusion and there is no default.
api :post, SMTP_BASE, params: SERVER_PARAMS,
                      body: { name: "Smoke SMTP", hostname: "smtp.example.com", ssl_mode: "SSL" },
                      expect: 422, description: "POST /smtp_endpoints with an unknown ssl_mode returns 422"

api :delete, "#{SMTP_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: smtp_uuid), expect: 204

puts
puts "== Address endpoint lifecycle =="

ADDRESS_BASE = "#{SERVER_BASE}/address_endpoints".freeze
address_uuid = nil

api :post, ADDRESS_BASE, params: SERVER_PARAMS, body: { address: "smoke-forward@example.com" },
                         expect: 201, description: "POST /address_endpoints creates one" do |body|
  address_uuid = body.dig("data", "uuid")
  assert "  the address round trips", body.dig("data", "address") == "smoke-forward@example.com"
end

api :get, "#{ADDRESS_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: address_uuid), expect: 200

api :patch, "#{ADDRESS_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: address_uuid),
                                      body: { address: "smoke-forward-2@example.com" }, expect: 200,
                                      description: "PATCH /address_endpoints/:uuid updates it" do |body|
  assert "  the new address is returned", body.dig("data", "address") == "smoke-forward-2@example.com"
end

api :put, "#{ADDRESS_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: address_uuid),
                                    body: { address: "smoke-forward-3@example.com" }, expect: 200,
                                    description: "PUT /address_endpoints/:uuid updates it"

# AddressEndpoint validates that the address contains an @.
api :post, ADDRESS_BASE, params: SERVER_PARAMS, body: { address: "not-an-address" },
                         expect: 422, description: "an address without an @ returns 422"

api :delete, "#{ADDRESS_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: address_uuid), expect: 204

puts
puts "== Route lifecycle =="

# Route#_endpoint is a virtual attribute rather than a column, so it used to be
# dropped by Rails' parameter wrapping. This is a regression guard for the
# wrap_parameters fix.
ROUTE_BASE = "#{SERVER_BASE}/routes".freeze
route_uuid = nil

api :post, ROUTE_BASE, params: SERVER_PARAMS,
                       body: { name: "smoke-route", domain_id: domain_id, spam_mode: "Mark",
                               _endpoint: "HTTPEndpoint##{http_uuid}" },
                       expect: 201, description: "POST /routes creates a route pointing at an endpoint" do |body|
  route_uuid = body.dig("data", "uuid")
  assert "  the HTTP endpoint was attached", body.dig("data", "endpoint") == "HTTPEndpoint##{http_uuid}"
  assert "  the domain was attached", body.dig("data", "domain_uuid") == domain_uuid
end

api :get, "#{ROUTE_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: route_uuid), expect: 200

api :patch, "#{ROUTE_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: route_uuid),
                                    body: { spam_mode: "Fail" }, expect: 200,
                                    description: "PATCH /routes/:uuid changes the spam mode" do |body|
  assert "  the new spam_mode is returned", body.dig("data", "spam_mode") == "Fail"
end

# A route update may omit the properties it does not want to change, which is
# why RouteInput and RouteUpdateInput are separate schemas in the document.
api :put, "#{ROUTE_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: route_uuid),
                                  body: { name: "smoke-route-2" }, expect: 200,
                                  description: "PUT /routes/:uuid changes only what is sent" do |body|
  assert "  the name changed", body.dig("data", "name") == "smoke-route-2"
  assert "  the spam mode was left alone", body.dig("data", "spam_mode") == "Fail"
  assert "  the endpoint was left alone", body.dig("data", "endpoint") == "HTTPEndpoint##{http_uuid}"
end

# Route validates the presence of domain_id for every route which is not the
# return path route.
api :post, ROUTE_BASE, params: SERVER_PARAMS,
                       body: { name: "no-domain", spam_mode: "Mark", _endpoint: "Accept" },
                       expect: 422, description: "POST /routes without a domain_id returns 422"

api :post, ROUTE_BASE, params: SERVER_PARAMS,
                       body: { name: "bad route!", domain_id: domain_id, spam_mode: "Mark", _endpoint: "Accept" },
                       expect: 422, description: "an invalid route name returns 422"

api :delete, "#{ROUTE_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: route_uuid), expect: 204
api :delete, "#{HTTP_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: http_uuid), expect: 204

puts
puts "== Track domain lifecycle =="

TRACK_BASE = "#{SERVER_BASE}/track_domains".freeze
track_uuid = nil

api :post, TRACK_BASE, params: SERVER_PARAMS,
                       body: { name: "track", domain_id: domain_id, track_clicks: true },
                       expect: 201, description: "POST /track_domains creates a tracking domain" do |body|
  track_uuid = body.dig("data", "uuid")
  assert "  the parent domain was attached", body.dig("data", "domain_uuid") == domain_uuid
  assert "  the full name is the parent domain appended",
         body.dig("data", "full_name") == "track.smoke.example.com"
end

api :get, "#{TRACK_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: track_uuid), expect: 200

api :patch, "#{TRACK_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: track_uuid),
                                    body: { track_loads: true }, expect: 200,
                                    description: "PATCH /track_domains/:uuid updates it" do |body|
  assert "  track_loads was turned on", body.dig("data", "track_loads") == true
end

api :put, "#{TRACK_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: track_uuid),
                                  body: { track_clicks: false }, expect: 200,
                                  description: "PUT /track_domains/:uuid updates it" do |body|
  assert "  track_clicks was turned off", body.dig("data", "track_clicks") == false
end

api :post, "#{TRACK_BASE}/{uuid}/check", params: SERVER_PARAMS.merge(uuid: track_uuid),
                                         expect: [200, 422],
                                         description: "POST /track_domains/:uuid/check runs a DNS check"

api :post, "#{TRACK_BASE}/{uuid}/toggle_ssl", params: SERVER_PARAMS.merge(uuid: track_uuid),
                                              expect: 200,
                                              description: "POST /track_domains/:uuid/toggle_ssl flips SSL"

api :delete, "#{TRACK_BASE}/{uuid}", params: SERVER_PARAMS.merge(uuid: track_uuid), expect: 204

# A track domain cannot be created without knowing the parent domain's integer
# ID, which is the reason DomainSerializer exposes it.
api :post, TRACK_BASE, params: SERVER_PARAMS, body: { name: "track2" },
                       expect: 422, description: "POST /track_domains without a domain_id returns 422"

puts
puts "== Message detail =="

# Messages cannot be created through the API because in a real installation they
# arrive over SMTP, so everything in this section walks over the three which
# script/smoke/seed.rb placed in the server's message database: one which has
# been sent, one which is being held and one which is waiting in the queue.
MESSAGE_BASE = "#{SERVER_BASE}/messages/{id}".freeze
SENT_PARAMS = SERVER_PARAMS.merge(id: SENT_MESSAGE_ID).freeze
HELD_PARAMS = SERVER_PARAMS.merge(id: HELD_MESSAGE_ID).freeze
QUEUED_PARAMS = SERVER_PARAMS.merge(id: QUEUED_MESSAGE_ID).freeze

api :get, "#{SERVER_BASE}/messages", params: SERVER_PARAMS, expect: 200,
                                     description: "GET /messages lists the server's outgoing messages" do |body|
  ids = body["data"].map { |message| message["id"] }
  assert "  the sent message is listed", ids.include?(SENT_MESSAGE_ID.to_i)
  assert "  the queued message is listed", ids.include?(QUEUED_MESSAGE_ID.to_i)
  # Loading the raw message is expensive so it is only rendered for a single
  # message. A collection which carried it would be a performance regression.
  assert("  a collection omits the raw message details",
         body["data"].none? { |message| message.key?("headers") })
end

api :get, "#{SERVER_BASE}/messages", params: SERVER_PARAMS, query: { scope: "incoming" }, expect: 200,
                                     description: "GET /messages?scope=incoming filters by scope" do |body|
  assert("  every message it returns is an incoming one",
         body["data"].all? { |message| message["scope"] == "incoming" })
end

api :get, MESSAGE_BASE, params: SENT_PARAMS, expect: 200,
                        description: "GET /messages/:id returns the message with its raw content" do |body|
  data = body["data"]
  assert "  the id matches the one which was asked for", data["id"] == SENT_MESSAGE_ID.to_i
  assert "  the status is the one the seed set", data["status"] == "Sent"
  assert "  the raw message is still stored", data["raw_message"] == true
  assert "  a single message carries its parsed headers", data["headers"].is_a?(Hash)
  assert "  the text part was parsed out of the multipart message",
         data["plain_body"].to_s.include?("Hello world!")
  assert "  the html part was parsed out of the multipart message",
         data["html_body"].to_s.include?("<p>Hello world!</p>")
  attachments = data["attachments"]
  assert "  the attachment is listed", attachments.is_a?(Array) && attachments.length == 1
  assert "  the attachment is described by its filename", attachments.to_a.first&.fetch("filename", nil) == "example.txt"
end

# The message ids come from a separate database with its own sequence, so the
# only way to ask for one which does not exist is to ask for an implausible id.
api :get, MESSAGE_BASE, params: SERVER_PARAMS.merge(id: SENT_MESSAGE_ID.to_i + 100_000), expect: 404,
                        description: "GET /messages/:id for a message which does not exist returns 404"

api :get, "#{MESSAGE_BASE}/deliveries", params: SENT_PARAMS, expect: 200,
                                        description: "GET /messages/:id/deliveries lists the delivery attempts" do |body|
  assert "  the attempt the seed wrote is present", body["data"].length >= 1
  assert("  it records the status it was created with",
         body["data"].any? { |delivery| delivery["status"] == "Sent" })
end

api :get, "#{MESSAGE_BASE}/activity", params: SENT_PARAMS, expect: 200,
                                      description: "GET /messages/:id/activity lists deliveries, clicks and loads" do |body|
  assert("  the delivery appears as an activity entry",
         body["data"].any? { |entry| entry["type"] == "Delivery" })
end

api :get, "#{MESSAGE_BASE}/spam_checks", params: SENT_PARAMS, expect: 200,
                                         description: "GET /messages/:id/spam_checks lists the checks which ran" do |body|
  assert("  the check the seed wrote is present",
         body["data"].any? { |check| check["code"] == "SPAMASSASSIN" })
end

api :get, "#{MESSAGE_BASE}/plain", params: SENT_PARAMS, expect: 200,
                                   description: "GET /messages/:id/plain returns the text part" do |body|
  assert "  the body is the text part", body.dig("data", "body").to_s.include?("Hello world!")
end

api :get, "#{MESSAGE_BASE}/html", params: SENT_PARAMS, expect: 200,
                                  description: "GET /messages/:id/html returns the html part" do |body|
  assert "  the body is the html part", body.dig("data", "body").to_s.include?("<p>Hello world!</p>")
end

api :get, "#{MESSAGE_BASE}/headers", params: SENT_PARAMS, expect: 200,
                                     description: "GET /messages/:id/headers returns the parsed headers" do |body|
  headers = body.dig("data", "headers")
  assert "  the headers are keyed by their lower cased name", headers.is_a?(Hash) && headers.key?("subject")
  # A header may legitimately appear more than once, for example Received, so
  # every value is the list of its occurrences rather than a single string.
  assert "  each value is a list of occurrences", headers.to_h.fetch("subject", nil).is_a?(Array)
end

api :get, "#{MESSAGE_BASE}/attachments", params: SENT_PARAMS, expect: 200,
                                         description: "GET /messages/:id/attachments describes them" do |body|
  attachments = body.dig("data", "attachments")
  assert "  one attachment is described", attachments.is_a?(Array) && attachments.length == 1
  assert "  it carries its size", attachments.to_a.first&.fetch("size", nil).is_a?(Integer)
end

# The content of an attachment and the raw message are the two responses which
# are not JSON. Their bytes are checked by the contract stage instead.
api :get, "#{MESSAGE_BASE}/attachment", params: SENT_PARAMS, query: { attachment: 0 }, expect: 200,
                                        description: "GET /messages/:id/attachment returns its content"

api :get, "#{MESSAGE_BASE}/attachment", params: SENT_PARAMS, query: { attachment: 9 }, expect: 404,
                                        description: "an attachment position which does not exist returns 404"

api :get, "#{MESSAGE_BASE}/download", params: SENT_PARAMS, expect: 200,
                                      description: "GET /messages/:id/download returns the raw message"

api :post, "#{MESSAGE_BASE}/retry", params: SENT_PARAMS, expect: 200,
                                    description: "POST /messages/:id/retry queues a message which is not queued"

# Cancelling the hold is what removes the message from the held collection which
# was read earlier, so it has to happen after that request rather than with the
# rest of the writes.
api :post, "#{MESSAGE_BASE}/cancel_hold", params: HELD_PARAMS, expect: 200,
                                          description: "POST /messages/:id/cancel_hold releases it" do |body|
  assert "  the message is no longer held", body.dig("data", "held") == false
end

api :get, "#{SERVER_BASE}/messages/held", params: SERVER_PARAMS, expect: 200,
                                          description: "GET /messages/held after the hold was cancelled" do |body|
  assert("  the released message has left the collection",
         body["data"].none? { |message| message["id"] == HELD_MESSAGE_ID.to_i })
end

api :delete, "#{MESSAGE_BASE}/remove_from_queue", params: QUEUED_PARAMS, expect: 204,
                                                  description: "DELETE /messages/:id/remove_from_queue dequeues it"

# The action is documented as idempotent so that a client can retry it safely.
api :delete, "#{MESSAGE_BASE}/remove_from_queue", params: QUEUED_PARAMS, expect: 204,
                                                  description: "removing a message which is not queued is not an error"

puts
puts "== Suppression lifecycle =="

SUPPRESSION_BASE = "#{SERVER_BASE}/messages/suppressions".freeze

api :post, SUPPRESSION_BASE, params: SERVER_PARAMS,
                             body: { type: "recipient", address: "smoke-bounce@example.com" },
                             expect: 201, description: "POST /messages/suppressions adds one"

api :get, SUPPRESSION_BASE, params: SERVER_PARAMS, expect: 200 do |body|
  assert("  the suppression is listed", body["data"].any? { |s| s["address"] == "smoke-bounce@example.com" })
end

api :delete, "#{SUPPRESSION_BASE}/{suppression_type}/{suppression_address}",
    params: SERVER_PARAMS.merge(suppression_type: "recipient", suppression_address: "smoke-bounce@example.com"),
    expect: 204, description: "DELETE /messages/suppressions/:type/:address removes it"

api :post, SUPPRESSION_BASE, params: SERVER_PARAMS,
                             body: { type: "NotAType", address: "x@example.com" },
                             expect: 422, description: "an unknown suppression type returns 422"

puts
puts "== Pagination =="

api :get, "#{SERVER_BASE}/messages", params: SERVER_PARAMS, query: { per_page: 1, page: 1 },
                                     expect: 200, description: "GET /messages honours pagination parameters" do |body|
  assert "  the pagination metadata is present", body.key?("pagination")
end

api :get, "/api/v2/organizations", query: { per_page: 1, page: 1 }, expect: 200 do |body|
  assert "  per_page caps the collection at one record", body["data"].length <= 1
end

puts
puts "== Server scoped domains and teardown =="

# The same domains controller serves both nestings, so the server scoped one is
# exercised separately.
SERVER_DOMAIN_BASE = "#{SERVER_BASE}/domains".freeze
SERVER_DOMAIN_PATH = "#{SERVER_BASE}/domains/{domain_uuid}".freeze
server_domain_uuid = nil

api :post, SERVER_DOMAIN_BASE, params: SERVER_PARAMS, body: { name: "server.smoke.example.com" },
                               expect: 201, description: "POST /servers/:permalink/domains creates a domain" do |body|
  server_domain_uuid = body.dig("data", "uuid")
  assert "  the owner is the server", body.dig("data", "owner_type") == "Server"
  assert "  the integer id is exposed here too", body.dig("data", "id").is_a?(Integer)
end

api :get, "#{SERVER_BASE}/domains", params: SERVER_PARAMS, expect: 200 do |body|
  assert("  the server scoped collection contains only the server's domains",
         body["data"].all? { |domain| domain["owner_type"] == "Server" })
end

api :get, SERVER_DOMAIN_PATH, params: SERVER_PARAMS.merge(domain_uuid: server_domain_uuid), expect: 200
api :get, "#{SERVER_DOMAIN_PATH}/dns_records", params: SERVER_PARAMS.merge(domain_uuid: server_domain_uuid), expect: 200

# The same controller actions serve both nestings, but each nesting is a separate
# operation in the document so both have to be walked through.
api :post, "#{SERVER_DOMAIN_PATH}/check", params: SERVER_PARAMS.merge(domain_uuid: server_domain_uuid),
                                          expect: [200, 422],
                                          description: "POST /servers/:permalink/domains/:uuid/check runs a DNS check"

api :post, "#{SERVER_DOMAIN_PATH}/verify", params: SERVER_PARAMS.merge(domain_uuid: server_domain_uuid),
                                           expect: 422,
                                           description: "POST /servers/:permalink/domains/:uuid/verify on a verified domain returns 422"

api :delete, SERVER_DOMAIN_PATH, params: SERVER_PARAMS.merge(domain_uuid: server_domain_uuid), expect: 204

# The organization scoped domain is removed last because the route and the track
# domain which were created against it have already been deleted.
api :delete, DOMAIN_PATH, params: ORG_PARAMS.merge(domain_uuid: domain_uuid), expect: 204,
                          description: "DELETE /domains/:uuid removes the domain"

# ---------------------------------------------------------------------------

$recording.close

puts
puts "=" * 64
puts "#{$passed} passed, #{$failures.size} failed"
unless $failures.empty?
  puts
  puts "Failures:"
  $failures.each_with_index { |failure, index| puts "  #{index + 1}. #{failure}" }
end
puts "Recordings written to #{RECORDINGS}"
puts "=" * 64

exit($failures.empty? ? 0 : 1)
