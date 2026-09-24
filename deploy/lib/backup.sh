#!/usr/bin/env bash
# ./deploy.sh backup | restore | backups
#
# Three things make up this installation and all three are backed up together,
# because a database without them is not recoverable:
#
#   databases.sql.gz  every Postal schema -- `postal` and each `postal-server-*`
#   config/           the DKIM signing key above all. Mail already sent was
#                     signed with it and the public half is published in DNS; a
#                     new key invalidates every signature this installation ever
#                     made, and the DNS record has to be replaced and propagated.
#   .env              RAILS_SECRET_KEY and the database passwords. Restoring the
#                     database with a different secret key is fine, but restoring
#                     it with different passwords means it cannot be opened.
#
# The MariaDB system schema is deliberately not dumped. Grants are rendered by
# ./deploy.sh init into database/init/, which the MariaDB entrypoint applies to
# an empty volume, so a restore recreates the scoped user from source rather than
# from a dump of mysql.user taken at some arbitrary earlier moment.

BACKUP_DIR=""

backup_cmd() {
  local label="" volume=false stop=false keep=7 out=""

  while (($#)); do
    case $1 in
      --out)     out=${2:?--out needs a directory}; shift 2 ;;
      --label)   label=${2:?--label needs a value}; shift 2 ;;
      --volume)  volume=true; shift ;;
      --stop)    stop=true; shift ;;
      --keep)    keep=${2:?--keep needs a number}; shift 2 ;;
      -h|--help) backup_usage; return 0 ;;
      *)         die "backup: unknown option '$1'" ;;
    esac
  done

  require_cmd docker
  require_cmd tar
  require_cmd gzip
  load_env
  need_env MARIADB_ROOT_PASSWORD

  BACKUP_DIR="${out:-$BACKUP_DEFAULT_DIR}"
  mkdir -p "$BACKUP_DIR"
  # The archive holds the signing key and every secret. The directory is 700 so
  # that a mistake in the archive's own mode is not also a world-readable secret.
  chmod 700 "$BACKUP_DIR"

  local stamp name work archive
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  name="postal-${stamp}${label:+-$label}"
  work="$(mktemp -d "$BACKUP_DIR/.${name}.XXXXXX")"
  archive="$BACKUP_DIR/${name}.tar.gz"

  # EXIT, not RETURN. A RETURN trap fires only when the function which set it
  # returns -- verified against bash 5.2 -- but every failure path below goes
  # through die, which calls exit. That would leave a directory holding the
  # signing key and a full database dump on disk after a failed backup, which is
  # exactly the kind of thing that is never noticed.
  trap 'rm -rf "$work"' EXIT

  step "Backing up to ${archive##*/}"

  if [[ $stop == true ]]; then
    backup_stop_app
  fi

  backup_databases "$work" "$volume"
  backup_files "$work"

  # Written into the archive so that a restore can say what it is looking at
  # without the operator having to remember which file came from which host.
  {
    printf 'created_at=%s\n' "$stamp"
    printf 'web_hostname=%s\n' "${POSTAL_WEB_HOSTNAME:-}"
    printf 'smtp_hostname=%s\n' "${POSTAL_SMTP_HOSTNAME:-}"
    printf 'revision=%s\n' "$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || echo unknown)"
    printf 'kind=%s\n' "$([[ $volume == true ]] && echo volume || echo dump)"
  } >"$work/MANIFEST"

  tar -czf "$archive" -C "$work" .
  chmod 600 "$archive"
  rm -rf "$work"

  local size
  size="$(du -h "$archive" 2>/dev/null | cut -f1)"
  ok "wrote $archive ($size)"

  backup_prune "$keep"

  if [[ $stop == true ]]; then
    log ""
    log "  The application services are stopped. ./deploy.sh up to restart them."
  fi
  return 0
}

# Stop the processes which write, leaving MariaDB up. A dump taken while the
# worker is delivering is consistent thanks to --single-transaction, but stopping
# first means the backup describes a moment when nothing was in flight, which is
# the moment worth being able to return to.
backup_stop_app() {
  step "Stopping the application services"
  compose stop postal smtp worker worker-hostnet cloudflared 2>/dev/null || true
  ok "stopped"
  return 0
}

backup_databases() {
  local work=$1 volume=$2

  step "MariaDB"

  if ! service_running mariadb; then
    info "mariadb is not running, starting it"
    compose up -d mariadb
    backup_wait_for_mariadb
  fi

  local cid
  cid="$(container_of mariadb)"
  if [[ -z $cid ]]; then
    die "could not find the mariadb container. ./deploy.sh up, then retry."
  fi

  if [[ $volume == true ]]; then
    backup_volume "$work" "$cid"
    return 0
  fi

  # Enumerated rather than --all-databases. The application data is `postal` plus
  # one schema per server, and naming them keeps the MariaDB system schema -- and
  # therefore the grant tables -- out of the archive.
  local dbs
  dbs="$(backup_database_list "$cid")"
  if [[ -z ${dbs// /} ]]; then
    die "no Postal databases were found. Has ./deploy.sh migrate been run?"
  fi
  info "schemas: $dbs"

  # MYSQL_PWD is set inside the container by its own shell, from a variable the
  # compose file already gives it. Passing -p on the command line instead would
  # put the password in argv, where it is readable from /proc by any user on the
  # host for as long as the dump runs.
  #
  # --single-transaction gives a consistent snapshot from a running InnoDB server
  # without locking it, so the stack can stay up. --add-drop-table is the
  # default, which is what makes a restore over an existing schema work.
  if ! docker exec -i "$cid" sh -c \
    'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-dump --single-transaction --quick --routines --triggers --events --databases '"$dbs" \
    2>"$work/dump.stderr" | gzip -9 >"$work/databases.sql.gz"; then
    cat "$work/dump.stderr" >&2
    die "the dump failed"
  fi

  # A dump can fail and still produce a truncated archive, and gzip reports
  # success on an empty input, so the result is checked rather than assumed.
  if ! gzip -t "$work/databases.sql.gz" 2>/dev/null; then
    cat "$work/dump.stderr" >&2
    die "the dump is not valid gzip"
  fi

  local lines
  lines="$(gzip -dc "$work/databases.sql.gz" | grep -c '^CREATE DATABASE' || true)"
  if [[ ${lines:-0} -eq 0 ]]; then
    die "the dump contains no CREATE DATABASE statement"
  fi
  ok "dumped $lines schema(s), $(du -h "$work/databases.sql.gz" | cut -f1) compressed"
  return 0
}

backup_database_list() {
  local cid=$1
  docker exec -i "$cid" sh -c \
    'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -u root -N -B -e "SHOW DATABASES"' 2>/dev/null |
    grep -E '^(postal|postal-server-)' |
    tr '\n' ' '
}

backup_wait_for_mariadb() {
  local deadline=$(( $(date +%s) + 90 ))
  while (( $(date +%s) < deadline )); do
    if [[ $(compose ps --format '{{.Service}} {{.Health}}' 2>/dev/null |
            awk '$1 == "mariadb" { print $2; exit }') == healthy ]]; then
      return 0
    fi
    sleep 3
  done
  die "mariadb did not become healthy within 90s"
}

# A cold copy of the data directory. Larger than a dump and tied to this MariaDB
# version, but it restores without re-running migrations, which is the difference
# that matters when the reason for restoring is that a migration went wrong.
backup_volume() {
  local work=$1 cid=$2

  warn "a volume copy is only consistent if nothing is writing to it."
  if service_running postal || service_running smtp ||
     service_running worker || service_running worker-hostnet; then
    die "the application services are still running. Re-run with --stop."
  fi

  # Copied through the running mariadb container rather than by mounting the
  # volume into a helper, because the container already has the volume at the
  # path the files are expected to live at.
  info "copying /var/lib/mysql (this can take a while)"
  docker exec -i "$cid" tar -cf - -C /var/lib/mysql . 2>"$work/volume.stderr" |
    gzip -1 >"$work/datadir.tar.gz" || {
    cat "$work/volume.stderr" >&2
    die "the volume copy failed"
  }
  gzip -t "$work/datadir.tar.gz" || die "the volume copy is not valid gzip"
  ok "copied the data directory, $(du -h "$work/datadir.tar.gz" | cut -f1) compressed"
  return 0
}

backup_files() {
  local work=$1

  step "Configuration and secrets"
  mkdir -p "$work/config"

  if [[ -d $CONFIG_DIR ]]; then
    cp -a "$CONFIG_DIR/." "$work/config/"
    # The signing key is the reason config/ is in the archive at all, so its
    # absence is a failure rather than something to note in passing.
    if [[ -f $work/config/signing.key ]]; then
      ok "config/ including signing.key"
    else
      warn "config/signing.key was not found"
      warn "  mail already sent cannot be re-verified without it"
    fi
  else
    warn "no config/ directory to back up"
  fi

  if [[ -f $ENV_FILE ]]; then
    cp -a "$ENV_FILE" "$work/env"
    ok ".env"
  else
    warn "no .env to back up"
  fi
  return 0
}

backup_prune() {
  local keep=$1
  local count
  count="$(ls -1 "$BACKUP_DIR"/postal-*.tar.gz 2>/dev/null | grep -c . || true)"
  (( count > keep )) || return 0

  info "keeping the newest $keep of $count backups in $BACKUP_DIR"
  ls -1t "$BACKUP_DIR"/postal-*.tar.gz | tail -n +$((keep + 1)) |
    while read -r old; do
      rm -f "$old"
      info "removed ${old##*/}"
    done
  return 0
}

backup_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh backup [--out DIR] [--label NAME] [--stop] [--volume] [--keep N]

Writes one gzipped tarball containing a dump of every Postal schema, the config
directory (including the DKIM signing key) and .env. The MariaDB system schema is
not included; grants are recreated by ./deploy.sh init on an empty volume.

  --out DIR      Write somewhere other than deploy/backups. Use this to point at
                 a mounted off-host filesystem: a backup on the same disk as the
                 data it protects does not survive losing that disk.
  --label NAME   Suffix the filename, e.g. --label pre-upgrade.
  --stop         Stop the application services first, so the backup describes a
                 moment when nothing was in flight.
  --volume       Copy the raw data directory instead of dumping. Requires
                 --stop. Larger, and tied to this MariaDB version, but restores
                 without re-running migrations.
  --keep N       Delete older backups beyond the newest N (default 7).

Usage: ./deploy.sh backups

Lists the backups in deploy/backups, newest first.

Usage: ./deploy.sh restore FILE [--volume] [--config] [--env] [--yes]

Loads a backup. Stops the application services first, and refuses to overwrite
config/ or .env unless asked, because doing so replaces the DKIM signing key and
every secret the running installation is using.

  --volume   Restore a raw data directory rather than a dump. Destroys the
             current one.
  --config   Also replace deploy/config/ from the archive.
  --env      Also replace deploy/.env from the archive.
  --yes      Do not ask for confirmation.
USAGE
}

# ---------------------------------------------------------------------------

backups_cmd() {
  while (($#)); do
    case $1 in
      -h|--help) log "Usage: ./deploy.sh backups"; return 0 ;;
      *)         die "backups: unknown option '$1'" ;;
    esac
  done

  load_env
  BACKUP_DIR="${BACKUP_OUT:-$BACKUP_DEFAULT_DIR}"

  if [[ ! -d $BACKUP_DIR ]] || [[ -z $(ls -A "$BACKUP_DIR" 2>/dev/null) ]]; then
    info "no backups in $BACKUP_DIR"
    return 0
  fi

  step "Backups in $BACKUP_DIR"
  ls -1t "$BACKUP_DIR"/postal-*.tar.gz 2>/dev/null |
    while read -r f; do
      printf '  %-46s %6s  %s\n' "${f##*/}" "$(du -h "$f" | cut -f1)" \
        "$(date -r "$f" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    done
  return 0
}

restore_cmd() {
  local archive="" volume=false do_config=false do_env=false assume=false

  while (($#)); do
    case $1 in
      --volume) volume=true; shift ;;
      --config) do_config=true; shift ;;
      --env)    do_env=true; shift ;;
      --yes)    assume=true; shift ;;
      -h|--help) backup_usage; return 0 ;;
      -*)       die "restore: unknown option '$1'" ;;
      *)        archive=$1; shift ;;
    esac
  done

  [[ -n $archive ]] || die "restore: which archive? ./deploy.sh backups lists them."
  [[ -f $archive ]] || die "restore: '$archive' does not exist"

  require_cmd docker
  require_cmd tar
  load_env
  need_env MARIADB_ROOT_PASSWORD

  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/postal-restore.XXXXXX")"
  # EXIT rather than RETURN, for the reason given in backup_cmd: the failure
  # paths below all go through die.
  trap 'rm -rf "$work"' EXIT

  step "Inspecting ${archive##*/}"
  tar -xzf "$archive" -C "$work" || die "could not read '$archive'"
  if [[ -f $work/MANIFEST ]]; then
    while read -r line; do info "  $line"; done <"$work/MANIFEST"
  fi

  warn "This replaces the contents of the Postal databases."
  if [[ $do_config == true ]]; then
    warn "It also replaces deploy/config/, including the DKIM signing key."
  fi
  if [[ $do_env == true ]]; then
    warn "It also replaces deploy/.env, including every secret and the database"
    warn "passwords -- which must match the databases being restored."
  fi

  if [[ $assume != true ]]; then
    printf '  Type RESTORE to continue: '
    local answer
    read -r answer || true
    [[ $answer == RESTORE ]] || die "not confirmed, nothing was changed"
  fi

  step "Stopping the application services"
  compose stop postal smtp worker worker-hostnet cloudflared 2>/dev/null || true
  if ! service_running mariadb; then
    compose up -d mariadb
    backup_wait_for_mariadb
  fi

  local cid
  cid="$(container_of mariadb)"
  [[ -n $cid ]] || die "could not find the mariadb container"

  if [[ $volume == true ]]; then
    restore_volume "$work" "$cid"
  else
    restore_dump "$work" "$cid"
  fi

  if [[ $do_config == true && -d $work/config ]]; then
    step "Restoring config/"
    rm -rf "${CONFIG_DIR:?}"
    mkdir -p "$CONFIG_DIR"
    cp -a "$work/config/." "$CONFIG_DIR/"
    # The key has to be readable by the uid the container runs as, and a copy
    # made by root is not. Getting this wrong produces mail which is delivered
    # but does not verify.
    if [[ -f $SIGNING_KEY ]]; then
      chmod 600 "$SIGNING_KEY"
      chown "$POSTAL_UID:$POSTAL_UID" "$SIGNING_KEY" 2>/dev/null ||
        warn "could not chown $SIGNING_KEY to $POSTAL_UID; run it as root or by hand"
    fi
    ok "config/ restored"
  fi

  if [[ $do_env == true && -f $work/env ]]; then
    step "Restoring .env"
    cp -a "$work/env" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok ".env restored"
  fi

  log ""
  log "  Restored from ${archive##*/}."
  log "  ./deploy.sh up        to start the stack again"
  log "  ./deploy.sh doctor    to verify it"
  return 0
}

restore_dump() {
  local work=$1 cid=$2

  [[ -f $work/databases.sql.gz ]] ||
    die "this archive has no databases.sql.gz. If it is a volume copy, use --volume."

  step "Loading the dump"
  # Piped in rather than copied into the container: the dump can be gigabytes and
  # the container's filesystem is not the place to put it.
  gzip -dc "$work/databases.sql.gz" |
    docker exec -i "$cid" sh -c \
      'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -u root' ||
    die "the dump could not be loaded"

  local dbs
  dbs="$(backup_database_list "$cid")"
  ok "loaded. Schemas now present: $dbs"
  return 0
}

restore_volume() {
  local work=$1 cid=$2

  [[ -f $work/datadir.tar.gz ]] ||
    die "this archive has no datadir.tar.gz. Drop --volume to load the dump."

  step "Replacing the data directory"
  warn "the existing contents of /var/lib/mysql are being deleted"

  # The server has to be down to have its files replaced, so it is stopped
  # properly rather than just paused.
  compose stop mariadb

  # The volume is named by the compose project, which common.sh pins, so this
  # does not depend on where the checkout lives. docker-compose.yml also declares
  # `name: postal`; deploy.sh doctor asserts the two agree.
  local vol="${COMPOSE_PROJECT}_postal-data"
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    die "volume '$vol' does not exist, so there is nothing to replace"
  fi

  docker run --rm \
    -v "$vol:/var/lib/mysql" \
    -v "$work:/backup:ro" \
    --entrypoint sh "${MARIADB_IMAGE:-mariadb:11}" \
    -c 'rm -rf /var/lib/mysql/* /var/lib/mysql/.[!.]* 2>/dev/null; tar -xzf /backup/datadir.tar.gz -C /var/lib/mysql && chown -R mysql:mysql /var/lib/mysql' ||
    die "the data directory could not be replaced"

  compose up -d mariadb
  backup_wait_for_mariadb
  ok "data directory restored"
  return 0
}
