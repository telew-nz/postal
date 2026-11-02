#!/usr/bin/env bash
# ./deploy.sh migrate -- create the schema and apply any pending migrations.
#
# Safe to re-run. On a fresh database it loads db/schema.rb; on an existing one it
# runs db:migrate. That decision is made by Postal's own `postal:update` task, not
# here, so there is one implementation of it rather than two that can drift.

migrate_cmd() {
  while (($#)); do
    case $1 in
      -h|--help) migrate_usage; return 0 ;;
      *)         die "migrate: unknown option '$1'" ;;
    esac
  done

  require_cmd docker
  load_env
  need_env POSTAL_IMAGE MAIN_DB_PASSWORD
  require_image

  step "Migrating"

  # The database itself, first. `rake db:create` would be the obvious choice but
  # it is not idempotent: it raises ActiveRecord::DatabaseAlreadyExists against an
  # installation which already has its schema, so the command an operator is most
  # likely to re-run after an interruption would fail on every later attempt.
  local out marker
  out="$(run_bootstrap bundle exec ruby /deploy-lib/ensure_database.rb 2>&1)"
  marker="$(printf '%s\n' "$out" | marker_line POSTAL_ENSURE_DATABASE)"

  if [[ -z $marker ]]; then
    printf '%s\n' "$out"
    die "could not create or find the main database"
  fi

  local result dbname
  result="$(printf '%s' "$marker" | awk '{print $1}')"
  dbname="$(printf '%s' "$marker" | awk '{print $2}')"

  case $result in
    created) ok "created database $dbname" ;;
    exists)  ok "database $dbname already exists" ;;
    *)       printf '%s\n' "$out"; die "unexpected result from ensure_database.rb" ;;
  esac

  # postal:update loads the schema when schema_migrations is empty and runs
  # db:migrate otherwise (lib/tasks/postal.rake:29-40).
  step "Applying schema and migrations"
  run_bootstrap bundle exec rake postal:update

  # Per-server message schemas. db:migrate is already enhanced to invoke this
  # (lib/tasks/postal.rake:63-65), so on an upgrade it has run by now and this is
  # a no-op; it is called explicitly because the schema:load path does not trigger
  # the enhancement, and because a command which lists its own steps is easier to
  # trust than one which relies on a Rake enhancement three files away.
  step "Migrating message databases"
  run_bootstrap bundle exec rake postal:migrate_message_databases

  ok "migrations complete"
  log ""
  log "  Next:  ./deploy.sh up"
  log "         ./deploy.sh admin   # administrator and first API token"
  return 0
}

migrate_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh migrate

Creates the main database if it does not exist, loads or migrates the schema, and
runs migrations against every server's message database. Idempotent.

Starts MariaDB if it is not already running, because the bootstrap container
depends on it and a migration against an absent database reports a connection
error that reads like a schema problem.
USAGE
}
