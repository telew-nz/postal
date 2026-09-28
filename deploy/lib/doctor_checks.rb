# frozen_string_literal: true

# Read-only fact gathering for ./deploy.sh doctor, run inside the bootstrap
# container with `bundle exec rails runner`.
#
# Everything a check needs is collected here rather than in bash for two reasons.
#
# First, the configuration. Reporting `Postal::Config.postal.web_hostname` proves
# the value the application actually resolved, after deploy/config/postal.yml,
# after the environment overrides it, and after the schema's transforms have run.
# Re-reading the YAML in bash would prove only that the file contains a line,
# which is the assumption doctor exists to replace.
#
# Second, the DNS lookups. The image installs curl and netcat but neither dig nor
# host, so there is no resolver to shell out to; Ruby's Resolv is always present.
# Plain Resolv is used deliberately rather than the application's own resolver --
# doctor is asking what the rest of the internet sees, not what Postal is
# configured to ask.
#
# Output is one marker line per fact, each a flat JSON object, so that bash can
# read it with sed. The prefixes are distinct and each is followed by a space,
# which is what keeps POSTAL_DOCTOR from matching POSTAL_DOCTOR_IP.
#
# Nothing here writes to the database.

require "resolv"
require "json"

MARKER = "POSTAL_DOCTOR"

# ---------------------------------------------------------------------------
# Helpers

def emit(prefix, hash)
  puts "#{prefix} #{JSON.generate(hash)}"
end

# A DNS answer, or nil. Exceptions are the normal outcome here -- a name which
# does not exist, a resolver which does not answer -- and every one of them means
# the same thing to the caller: there is no record.
#
# Resolv::ResolvError and Resolv::ResolvTimeout are both StandardError, so naming
# them alongside it would only shadow them.
def resolve(dns, name, type)
  dns.getresources(name, type).map { |r| resource_value(r) }
rescue StandardError
  nil
end

def resource_value(resource)
  case resource
  when Resolv::DNS::Resource::IN::TXT
    # A long TXT is published as several quoted strings and Resolv hands back the
    # concatenation, but providers differ on where they split it. Whitespace is
    # therefore removed before any comparison; DKIM records in particular are
    # commonly published with the key wrapped across strings.
    resource.strings.join.gsub(/\s+/, "")
  when Resolv::DNS::Resource::IN::CNAME
    resource.name.to_s.sub(/\.\z/, "")
  else
    resource.address.to_s
  end
end

def dns_client
  dns = Resolv::DNS.new
  # Bounded so that a resolver which silently drops queries produces a report
  # rather than a hung command. doctor is run interactively and often over ssh.
  dns.timeouts = [2, 4]
  dns
rescue StandardError
  nil
end

# ---------------------------------------------------------------------------
# The configuration the application resolved

config = Postal::Config

emit(MARKER, {
  postal_version: Postal.version.to_s,
  rails_environment: config.rails.environment,
  web_hostname: config.postal.web_hostname,
  web_protocol: config.postal.web_protocol,
  smtp_hostname: config.postal.smtp_hostname,
  use_ip_pools: config.postal.use_ip_pools?,
  api_enabled: config.api.enabled?,
  signing_key_path: config.postal.signing_key_path,
  signing_key_present: File.readable?(config.postal.signing_key_path.to_s),
  # CIDR, not to_s. IPAddr#to_s returns the address alone -- "172.28.0.0" for
  # 172.28.0.0/24 -- and #to_string returns the same thing, so neither can be
  # compared against the compose subnet as doctor writes it. Without the prefix
  # this reported a correctly configured installation as trusting the wrong
  # network. #prefix is Ruby 3.1+; the guard keeps a bare address working on
  # anything older, where the comparison degrades to what it did before.
  trusted_proxies: Array(config.postal.trusted_proxies).map { |ip|
    ip.respond_to?(:prefix) ? "#{ip}/#{ip.prefix}" : ip.to_s
  },
  mx_records: Array(config.dns.mx_records),
  spf_include: config.dns.spf_include,
  return_path_domain: config.dns.return_path_domain,
  route_domain: config.dns.route_domain,
  track_domain: config.dns.track_domain,
  helo_hostname: config.dns.helo_hostname,
  dkim_identifier: config.dns.dkim_identifier,
  smtp_tls_enabled: config.smtp_server.tls_enabled?,
  main_db_host: config.main_db.host,
  main_db_username: config.main_db.username,
  main_db_database: config.main_db.database
})

# The public half of the DKIM key. Derived rather than read from the environment:
# this is the string which has to appear in DNS for mail to verify, and taking it
# from the same code path that signs the mail is the only way the two cannot drift.
rp_dkim = begin
  Postal.rp_dkim_dns_record.gsub(/\s+/, "")
rescue StandardError => e
  emit("#{MARKER}_DKIM_ERROR", { error: e.class.name, message: e.message.to_s[0, 200] })
  nil
end

# ---------------------------------------------------------------------------
# DNS as the rest of the internet sees it

public_ip = ENV["DOCTOR_PUBLIC_IP"].to_s
expected = {
  return_path_domain: config.dns.return_path_domain,
  helo_hostname: config.dns.helo_hostname,
  web_hostname: config.postal.web_hostname,
  smtp_hostname: config.postal.smtp_hostname,
  rp_dkim: rp_dkim
}

dns = dns_client
if dns.nil?
  emit("#{MARKER}_DNS", { check: "resolver", ok: false, error: "no resolver available" })
else
  # Reverse DNS for the address mail leaves from. Checked first because it is the
  # most common reason outbound mail is rejected and the least visible: nothing in
  # Postal fails when it is wrong, the recipient's mail server simply penalises or
  # refuses the message.
  if public_ip.empty?
    emit("#{MARKER}_DNS", { check: "ptr", ok: nil, error: "DOCTOR_PUBLIC_IP is not set" })
  else
    ptr = resolve(dns, Resolv::IPv4.create(public_ip).reverse_name, Resolv::DNS::Resource::IN::PTR)
    names = Array(ptr).map { |n| n.sub(/\.\z/, "") }
    emit("#{MARKER}_DNS", {
      check: "ptr",
      name: public_ip,
      expected: expected[:helo_hostname],
      actual: names.join(","),
      ok: names.map(&:downcase).include?(expected[:helo_hostname].to_s.downcase)
    })
  end

  # Forward DNS for the names in dns.mx_records. Every sending domain's MX points
  # at one of these, so inbound mail has nowhere to go unless they resolve here.
  Array(config.dns.mx_records).each do |name|
    a = resolve(dns, name, Resolv::DNS::Resource::IN::A)
    emit("#{MARKER}_DNS", {
      check: "a",
      name: name,
      expected: public_ip.empty? ? nil : public_ip,
      actual: Array(a).join(","),
      # With no POSTAL_PUBLIC_IP there is nothing to compare against, so any
      # answer at all is the best evidence available that the name resolves.
      ok: public_ip.empty? ? Array(a).any? : Array(a).include?(public_ip)
    })
  end

  dkim_name = "#{config.dns.dkim_identifier}._domainkey.#{config.dns.return_path_domain}"
  txt = resolve(dns, dkim_name, Resolv::DNS::Resource::IN::TXT)
  emit("#{MARKER}_DNS", {
    check: "dkim",
    name: dkim_name,
    # The expected value is only useful in the report if it could be derived.
    expected: rp_dkim ? rp_dkim[0, 60] : nil,
    actual: Array(txt).join(" | ")[0, 60],
    ok: rp_dkim ? Array(txt).include?(rp_dkim) : Array(txt).any?
  })

  spf = resolve(dns, config.dns.spf_include, Resolv::DNS::Resource::IN::TXT)
  emit("#{MARKER}_DNS", {
    check: "spf",
    name: config.dns.spf_include,
    expected: "v=spf1",
    actual: Array(spf).join(" | ")[0, 120],
    # has_dns_checks.rb greps the resolved records for one beginning v=spf1, so
    # that is the condition being asserted here too.
    ok: Array(spf).any? { |r| r.start_with?("v=spf1") }
  })

  rp_mx = resolve(dns, config.dns.return_path_domain, Resolv::DNS::Resource::IN::MX)
  emit("#{MARKER}_DNS", {
    check: "return_path_mx",
    name: config.dns.return_path_domain,
    expected: expected[:smtp_hostname],
    actual: Array(rp_mx).join(","),
    ok: Array(rp_mx).any? { |r| r.downcase.include?(expected[:smtp_hostname].to_s.downcase) }
  })

  cname = resolve(dns, config.dns.track_domain, Resolv::DNS::Resource::IN::CNAME)
  a = resolve(dns, config.dns.track_domain, Resolv::DNS::Resource::IN::A)
  emit("#{MARKER}_DNS", {
    check: "track_domain",
    name: config.dns.track_domain,
    expected: expected[:web_hostname],
    actual: (Array(cname) + Array(a)).join(","),
    # Either a CNAME at the web hostname or an A record for it is workable: the
    # requirement is that the name reaches the web process, which serves the
    # redirect, and that is what the second alternative proves.
    ok: Array(cname).any? { |c| c.downcase == expected[:web_hostname].to_s.downcase } ||
        !Array(a).empty?
  })

  route_mx = resolve(dns, config.dns.route_domain, Resolv::DNS::Resource::IN::MX)
  emit("#{MARKER}_DNS", {
    check: "route_domain",
    name: config.dns.route_domain,
    expected: expected[:smtp_hostname],
    actual: Array(route_mx).join(","),
    ok: Array(route_mx).any? { |r| r.downcase.include?(expected[:smtp_hostname].to_s.downcase) }
  })
end

# ---------------------------------------------------------------------------
# Database and application state

begin
  conn = ActiveRecord::Base.connection

  # The identity the application is really connecting as. This is the direct
  # assertion that the scoped user replaced root: a value of root@localhost means
  # the grant script was never applied, and the application can then read every
  # schema on the server.
  current_user = conn.select_value("SELECT CURRENT_USER()").to_s

  # select_values rather than `conn.query(...).map { |row| row.values.first }`.
  # ActiveRecord sets the mysql2 client's default query options to :as => :array,
  # so a raw query hands back Arrays and `.values` raises NoMethodError -- which
  # the rescue at the end of this block turns into a one-line error, silently
  # dropping every check below it including the CURRENT_USER() assertion above.
  visible = conn.select_values("SHOW DATABASES").map(&:to_s)

  # The grant tables are the sharpest probe available. Being unable to read
  # mysql.user is what "cannot reach other schemas" means in practice, and unlike
  # a list of visible databases it cannot be satisfied by an accident of the
  # server's default grants.
  mysql_readable = begin
    conn.select_value("SELECT COUNT(*) FROM mysql.user")
    true
  rescue StandardError
    false
  end

  migrations = conn.select_values("SELECT version FROM schema_migrations").map(&:to_s)

  pending = begin
    ActiveRecord::Base.connection.migration_context.needs_migration?
  rescue StandardError
    nil
  end

  queued = conn.select_value("SELECT COUNT(*) FROM queued_messages").to_i
  locked = conn.select_value(
    "SELECT COUNT(*) FROM queued_messages WHERE locked_at IS NOT NULL"
  ).to_i

  # The tasks role is held by exactly one worker at a time and is renewed every
  # 60 seconds; a row older than five minutes is stolen by whichever worker next
  # tries (WorkerRole.acquire, app/models/worker_role.rb). A stale row therefore
  # means no worker is running the scheduled tasks -- retention, queue sizing,
  # suppression -- even though message delivery may still be happening elsewhere.
  role = conn.select_one(
    "SELECT worker, acquired_at FROM worker_roles WHERE role = 'tasks' LIMIT 1"
  )

  emit("#{MARKER}_DB", {
    current_user: current_user,
    is_root: current_user.split("@").first == "root",
    database: config.main_db.database,
    visible_schemas: visible.join(","),
    mysql_schema_readable: mysql_readable,
    schema_versions: migrations.size,
    migrations_pending: pending,
    queued_messages: queued,
    queued_locked: locked,
    tasks_worker: role && role["worker"],
    tasks_acquired_at: role && role["acquired_at"]&.to_s,
    tasks_age_seconds: role && role["acquired_at"] ? (Time.current - role["acquired_at"]).round : nil
  })
rescue StandardError => e
  # Reported rather than raised: doctor's job is to say what is wrong, and an
  # unreachable database is one of the things it has to be able to say. A runner
  # which dies with a backtrace reports the symptom instead.
  emit("#{MARKER}_DB", { error: e.class.name, message: e.message.to_s[0, 300] })
end

# ---------------------------------------------------------------------------
# Registered outbound addresses

begin
  # Read with SQL rather than through the model so that this still reports on an
  # installation whose schema is only part way migrated.
  #
  # select_all, not query: ActiveRecord configures the mysql2 client with
  # :as => :array, so query hands back Arrays and the row["ipv4"] lookups below
  # raise TypeError -- which the rescue at the end of this block turns into a
  # one-line error and nothing else. select_all returns an ActiveRecord::Result
  # whose rows are Hashes, so the string keys the code is written against work.
  rows = ActiveRecord::Base.connection.select_all(<<~SQL.squish).to_a
    SELECT ip_addresses.ipv4 AS ipv4, ip_addresses.hostname AS hostname,
           ip_addresses.priority AS priority, ip_pools.name AS pool
    FROM ip_addresses LEFT JOIN ip_pools ON ip_pools.id = ip_addresses.ip_pool_id
    ORDER BY ip_addresses.id
  SQL

  rows.each do |row|
    v4 = row["ipv4"].to_s
    hostname = row["hostname"].to_s

    # The PTR of each registered address, resolved here rather than in bash
    # because the image has no dig or host. SMTPClient::Endpoint passes
    # IPAddress.hostname to Net::SMTP as the HELO name, so a hostname which is
    # not that address's PTR is the configuration most likely to get outbound
    # mail rejected -- and nothing in Postal reports it.
    ptr = if dns && !v4.empty?
            resolve(dns, Resolv::IPv4.create(v4).reverse_name, Resolv::DNS::Resource::IN::PTR)
          end
    names = Array(ptr).map { |n| n.sub(/\.\z/, "").downcase }

    emit("#{MARKER}_IP", {
      ipv4: v4,
      hostname: hostname,
      priority: row["priority"],
      pool: row["pool"],
      ptr: names.join(","),
      ptr_matches: dns ? names.include?(hostname.downcase) : nil
    })
  end
rescue StandardError => e
  emit("#{MARKER}_IP", { error: e.class.name, message: e.message.to_s[0, 200] })
end
