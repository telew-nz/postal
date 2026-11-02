#!/usr/bin/env bash
# ./deploy.sh migrate -- create the schema and apply any pending migrations.
#
# Safe to re-run. On a fresh database it loads db/schema.rb; on an existing one it
# runs db:migrate. That decision is made by Postal's own `postal:update` task, not
# here, so there is one implementation of it rather than two that can drift.

# Reconcile the application database user and grants against the current .env,
# so that a MariaDB volume initialized before the grant script existed -- or
# with an older password -- converges to the running configuration instead of
# leaving the app serving access-denied. Idempotent and safe to re-run.
# Start mariadb if it is not already running, and wait for it to be healthy.
# Called before reconciliation so migrate works from a cold start (fresh
# volume, no containers), where the bootstrap container's dependency is not
# available yet.
ensure_mariadb_running() {
  local cid
  cid="$(compose ps -q mariadb 2>/dev/null || true)"
  if [[ -n $cid ]]; then
    return 0
  fi
  ok "starting mariadb"
  compose up -d mariadb >/dev/null
  local tries=0
  until [[ $(docker inspect -f '{{.State.Health.Status}}' "$(compose ps -q mariadb 2>/dev/null)" 2>/dev/null) == healthy ]]; do
    tries=$((tries+1))
    if (( tries > 90 )); then
      die "mariadb did not become healthy after starting"
    fi
    sleep 2
  done
}

ensure_database_grants() {
  local cid user
  user="${MAIN_DB_USERNAME:-postal}"
  ensure_mariadb_running
  cid="$(compose ps -q mariadb 2>/dev/null || true)"
  [[ -n $cid ]] || die "mariadb container is not running; cannot reconcile database grants"

  # The same statements init renders into database/init/001-postal-user.sql,
  # applied to the live server so an existing volume catches up. MYSQL_PWD is
  # injected via docker exec rather than on the command line, so the password
  # never appears in argv /proc.
  local sql
  sql="CREATE USER IF NOT EXISTS '${user}'@'%' IDENTIFIED BY '${MAIN_DB_PASSWORD}';
ALTER USER '${user}'@'%' IDENTIFIED BY '${MAIN_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`postal\`.* TO '${user}'@'%';
GRANT ALL PRIVILEGES ON \`postal-server-%\`.* TO '${user}'@'%';
FLUSH PRIVILEGES;"

  local err
  err="$(printf '%s' "$sql" | docker exec -i -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" "$cid" mariadb -u root 2>&1)" || {
    printf '%s\n' "$err" | tail -n3 | while read -r l; do warn "  $l"; done
    die "could not apply the application database grants as root: the volume's root password differs from .env. Recreate the volume with ./deploy.sh reset (a fresh volume initializes from the current .env), or match MARIADB_ROOT_PASSWORD to the volume."
  }

  # Prove the application user can actually authenticate with the .env password.
  if ! docker exec -i -e MYSQL_PWD="$MAIN_DB_PASSWORD" "$cid" \
      mariadb -h127.0.0.1 -u "$user" -N -B -e "SELECT 1" >/dev/null 2>&1; then
    die "database grant reconciliation did not produce a working '${user}' login"
  fi
  ok "database grants reconciled for user '${user}'"
}

migrate_cmd() {
  while (($#)); do
    case $1 in
      -h|--help) migrate_usage; return 0 ;;
      *)         die "migrate: unknown option '$1'" ;;
    esac
  done

  require_cmd docker
  load_env
  need_env POSTAL_IMAGE MAIN_DB_PASSWORD MARIADB_ROOT_PASSWORD
  require_image

  step "Reconciling database grants"
  ensure_database_grants

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

Before that it reconciles the application database user and grants against the
current .env, so a volume initialized before the grant script existed (or with
an older password) is fixed rather than leaving the app serving access-denied.
If the volume's root password differs from .env this fails with instructions to
recreate the volume with ./deploy.sh reset.

Starts MariaDB if it is not already running, because the bootstrap container
depends on it and a migration against an absent database reports a connection
error that reads like a schema problem.
USAGE
}
