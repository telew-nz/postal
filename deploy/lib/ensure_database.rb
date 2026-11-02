# frozen_string_literal: true

# Create the main database if it does not exist. Run by `./deploy.sh migrate`.
#
# This exists because `rake db:create` is not idempotent: it raises
# ActiveRecord::DatabaseAlreadyExists against an installation which already has
# its schema, which makes the one command an operator is most likely to re-run
# after an interruption fail on every subsequent attempt. Creating the database
# conditionally and leaving everything else to `rake postal:update` gives a
# migrate which can be run as often as needed.
#
# It deliberately does not use Rails. Requiring config/environment would build a
# connection pool against a database which may not exist yet, which is the exact
# condition being handled here, and it would fail before reaching this code.
# Mysql2 talks to the server directly, so it can create the database that
# ActiveRecord is about to want.
#
# Configuration is read from the same environment variables the application
# uses, so there is no second definition of where the database lives:
#
#   MAIN_DB_HOST, MAIN_DB_PORT, MAIN_DB_USERNAME, MAIN_DB_PASSWORD
#
# The database name comes from the committed config file rather than an
# environment variable, because main_db.database is not something a deployment
# should be varying: the scoped user's grant and message_db.database_name_prefix
# are both written against it.

require "yaml"
require "mysql2"

config_path = ENV.fetch("POSTAL_CONFIG_FILE_PATH", "/config/postal.yml")
raise "#{config_path} is missing. Is ./config mounted?" unless File.exist?(config_path)

config = YAML.safe_load(File.read(config_path)) || {}
database = config.dig("main_db", "database") || "postal"

# The name is interpolated into CREATE DATABASE below, inside backticks, so a
# name containing a backtick would close the identifier early. It comes from a
# committed file rather than from an operator, which makes this belt and braces,
# but the alternative is a statement whose meaning depends on a value nobody
# validates. MariaDB identifiers of this shape cover every real database name.
unless database.match?(/\A[A-Za-z0-9_-]+\z/)
  abort "main_db.database is '#{database}', which is not a plain identifier."
end

host = ENV.fetch("MAIN_DB_HOST", "127.0.0.1")
port = Integer(ENV.fetch("MAIN_DB_PORT", "3306"))
username = ENV.fetch("MAIN_DB_USERNAME", "postal")
password = ENV.fetch("MAIN_DB_PASSWORD") do
  abort "MAIN_DB_PASSWORD must be set."
end

# Connected without selecting a database, which is the point: `database: nil`
# means the server accepts the connection even when the target schema is absent.
client = Mysql2::Client.new(
  host: host,
  port: port,
  username: username,
  password: password
)

# Compared in Ruby rather than in a WHERE clause, so there is no quoted literal
# to get wrong. SHOW DATABASES only lists schemas the connecting user can see,
# which is the right test here anyway: a database the scoped user cannot reach is
# indistinguishable from one that does not exist, and either way the next step
# would fail.
existed = client.query("SHOW DATABASES").map { |row| row.values.first }.include?(database)

unless existed
  # Character set and collation are stated rather than inherited from the
  # server, so that the result is the same against the containerised MariaDB
  # (which docker-compose.yml starts with utf8mb4/utf8mb4_unicode_ci) and
  # against an externally managed server whose defaults may differ. Postal stores
  # message bodies and headers here, and a latin1 database truncates at the first
  # non-Latin1 character in a subject line.
  client.query(
    "CREATE DATABASE `#{database}` " \
    "CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
  )
end

# Report as a single parseable line. The caller separates this from any warning
# the driver emits by prefix, rather than by assuming it is the last line.
puts "POSTAL_ENSURE_DATABASE #{existed ? 'exists' : 'created'} #{database}"
