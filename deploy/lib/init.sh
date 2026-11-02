#!/usr/bin/env bash
# ./deploy.sh init -- create .env, generate secrets, and prepare the DKIM key.
#
# Idempotent. Values which already exist are left alone, so this is safe to
# re-run after an interrupted attempt, and safe to run on an installation which
# is already serving mail. Use --force-secrets to replace the generated secrets,
# which invalidates every existing web session.

init_cmd() {
  local force_secrets=false
  local domain=""

  while (($#)); do
    case $1 in
      --force-secrets) force_secrets=true; shift ;;
      --domain)        domain=${2:?--domain needs a value}; shift 2 ;;
      -h|--help)       init_usage; return 0 ;;
      *)               die "init: unknown option '$1'" ;;
    esac
  done

  require_cmd docker
  require_cmd openssl
  require_cmd git

  step "Preparing $DEPLOY_DIR"

  init_env_file
  load_env
  init_secrets "$force_secrets"
  # env_set writes to the .env file but does not export into this shell, so
  # the values just generated are not visible yet. Reload before anything
  # relies on them.
  load_env
  init_site_values "$domain"
  # Prompted values were also written to .env; reload so they are visible too.
  load_env
  init_signing_key
  init_database_grants

  init_report
}

init_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh init [--domain example.com] [--force-secrets]

Creates deploy/.env from .env.example, fills in the secrets, generates the DKIM
signing key and renders the database grant script. Existing values are kept, so
it is safe to re-run.

  --domain example.com  Derive the dns.* names (spf., rp., routes., track.) and
                        the MX and HELO hostnames from this domain. Only fills
                        values which are currently empty.
  --force-secrets       Regenerate RAILS_SECRET_KEY, MAIN_DB_PASSWORD and
                        MARIADB_ROOT_PASSWORD. Invalidates all web sessions and
                        breaks access to any database created with the old
                        password, so the volume has to be recreated afterwards.
USAGE
}

# ---------------------------------------------------------------------------

init_env_file() {
  if [[ -f $ENV_FILE ]]; then
    ok ".env already exists, keeping it"
    return
  fi

  [[ -f $ENV_EXAMPLE ]] || die "$ENV_EXAMPLE is missing from the checkout."

  # tr -d '\r' because the example file may have been checked out on Windows,
  # where core.autocrlf gives it CRLF. A carriage return inside a dotenv value is
  # invisible and then breaks authentication in a way that looks like a wrong
  # password.
  tr -d '\r' <"$ENV_EXAMPLE" >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "created .env from .env.example"
}

init_secrets() {
  local force=$1
  local key current

  for key in RAILS_SECRET_KEY MAIN_DB_PASSWORD MARIADB_ROOT_PASSWORD POSTAL_ADMIN_PASSWORD; do
    current="$(env_get "$key")"
    if [[ -n $current ]] && [[ $force != true ]]; then
      ok "$key already set, keeping it"
      continue
    fi
    if [[ $key == POSTAL_ADMIN_PASSWORD ]]; then
      # Shorter than the others because a human has to type it into a login form.
      env_set "$key" "$(random_hex 8)"
    else
      env_set "$key" "$(random_hex 32)"
    fi
    ok "generated $key"
  done

  if [[ $force == true ]]; then
    warn "--force-secrets replaced the database passwords. The existing MariaDB"
    warn "volume still holds the old ones, so ./deploy.sh reset is required."
  fi
}

# The values which cannot be invented. Prompted for when there is a terminal,
# left empty and reported otherwise, so that this also works unattended from a
# configuration management tool which has already written them.
init_site_values() {
  local domain=$1
  local value

  if [[ -n $domain ]]; then
    init_apply_domain "$domain"
  fi

  init_prompt POSTAL_WEB_HOSTNAME \
    "Public hostname the Cloudflare Tunnel serves (e.g. postal.example.com)"
  init_prompt POSTAL_SMTP_HOSTNAME \
    "Mail hostname, should match this host's PTR record (e.g. mx.example.com)"
  init_prompt POSTAL_ADMIN_EMAIL \
    "Administrator login email"

  # Read without echoing: this token can serve traffic as the tunnel.
  value="$(env_get CLOUDFLARE_TUNNEL_TOKEN)"
  if [[ -z $value && -t 0 ]]; then
    printf '  %-42s' "Cloudflare tunnel token (hidden input):"
    # `|| true` because read returns non-zero at EOF, and because this is the last
    # statement of the function: under `set -e` a function's status is that of its
    # last command, so an operator pressing enter to skip the question would
    # abort the whole of init. Verified against bash 5.2 -- `[[ -n $v ]] && cmd`
    # as a final statement does terminate the script when the test is false.
    read -rs value || true
    printf '\n'
    if [[ -n $value ]]; then
      env_set CLOUDFLARE_TUNNEL_TOKEN "$value"
    fi
  fi

  init_prompt DNS_HELO_HOSTNAME \
    "Outbound HELO name, must match PTR (defaults to the mail hostname)"
  value="$(env_get DNS_HELO_HOSTNAME)"
  if [[ -z $value ]]; then
    value="$(env_get POSTAL_SMTP_HOSTNAME)"
    if [[ -n $value ]]; then
      env_set DNS_HELO_HOSTNAME "$value"
    fi
  fi

  # Prompted for but deliberately not added to init_report's required set: an
  # installation with no public address is a legitimate configuration, and
  # failing init over it would be wrong. It is asked about because both of its
  # consumers degrade quietly rather than reporting anything -- dns cannot print
  # the A records the MX entries point at, and doctor cannot check that the PTR
  # record matches DNS_HELO_HOSTNAME, which is the single most common reason
  # outbound mail is rejected. Pressing enter leaves it empty, which init_prompt
  # treats as a skipped question rather than as an error.
  init_prompt POSTAL_PUBLIC_IP \
    "This host's public IPv4, for PTR and A records (blank if none)"

  return 0
}

# Fill the dns.* names from a registered domain, without overwriting anything
# already set. These are the schema's postal.example.com defaults replaced with
# something real; leaving them alone produces domains which cannot be verified
# and mail which cannot be delivered, with no error anywhere.
init_apply_domain() {
  local domain=$1
  local smtp_host

  smtp_host="mx.${domain}"

  _init_default DNS_MX_RECORDS "$smtp_host"
  _init_default DNS_SPF_INCLUDE "spf.${domain}"
  _init_default DNS_RETURN_PATH_DOMAIN "rp.${domain}"
  _init_default DNS_ROUTE_DOMAIN "routes.${domain}"
  _init_default DNS_TRACK_DOMAIN "track.${domain}"
  _init_default DNS_HELO_HOSTNAME "$smtp_host"
  _init_default POSTAL_SMTP_HOSTNAME "$smtp_host"
}

_init_default() {
  [[ -n $(env_get "$1") ]] && return 0
  env_set "$1" "$2"
  ok "$1 -> $2"
}

init_prompt() {
  local key=$1 label=$2 value
  value="$(env_get "$key")"
  if [[ -n $value ]]; then
    ok "$key already set ($value)"
    return 0
  fi

  # No terminal to prompt on. Left empty rather than invented: init_report lists
  # everything still missing at the end, which is how an unattended run is meant
  # to be completed -- configuration management writes .env, or a second run
  # supplies the values once they are known.
  [[ -t 0 ]] || return 0

  printf '  %-42s' "${label}:"
  read -r value || true
  if [[ -n $value ]]; then
    env_set "$key" "$value"
  fi

  # Explicit, because skipping a question is a normal outcome and not an error.
  # Without it the function's status is that of the last `[[ ]]`, which is false
  # whenever the operator pressed enter, and `set -e` then aborts init.
  return 0
}

# ---------------------------------------------------------------------------

init_signing_key() {
  mkdir -p "$CONFIG_DIR"

  if [[ -f $SIGNING_KEY ]]; then
    ok "signing.key already exists, keeping it"
  else
    # 2048-bit RSA. This is the DKIM private key: every message this
    # installation signs is verifiable against the public half, which
    # ./deploy.sh dns prints for publishing. Rotating it invalidates
    # verification for mail already delivered.
    openssl genrsa -out "$SIGNING_KEY" 2048 >/dev/null 2>&1
    ok "generated signing.key (2048-bit RSA)"
  fi

  chmod 600 "$SIGNING_KEY"

  # The container runs as uid 999 and mounts ./config read-only, so it has to be
  # able to read this file as that uid. On Linux a real bind mount honours host
  # permissions, and 600 owned by the invoking user would leave the container
  # unable to sign anything -- which surfaces as a DKIM failure on the far side,
  # not as an error here.
  if [[ $(id -u) -eq 0 ]]; then
    chown "$POSTAL_UID:$POSTAL_UID" "$SIGNING_KEY" 2>/dev/null || true
    ok "signing.key owned by uid $POSTAL_UID"
  elif stat -c '%u' "$SIGNING_KEY" 2>/dev/null | grep -qx "$POSTAL_UID"; then
    ok "signing.key owned by uid $POSTAL_UID"
  else
    warn "signing.key is not readable by the container's uid $POSTAL_UID."
    warn "Run:  sudo chown $POSTAL_UID:$POSTAL_UID $SIGNING_KEY"
    warn "DKIM signing will fail until it is. ./deploy.sh doctor checks this."
  fi
}

# The MariaDB image runs /docker-entrypoint-initdb.d on first initialization of an
# empty volume only. The script has to name the scoped user and its password, so
# it is rendered here from .env rather than committed -- which is also why the
# directory is gitignored.
init_database_grants() {
  local username password
  username="${MAIN_DB_USERNAME:-postal}"
  password="${MAIN_DB_PASSWORD:?MAIN_DB_PASSWORD is not set}"

  mkdir -p "$DB_INIT_DIR"

  cat >"$DB_INIT_DIR/001-postal-user.sql" <<SQL
-- Rendered by deploy.sh init. Contains the application database password, so
-- this directory is gitignored.
--
-- The application user is granted on the main schema and on the per-server
-- message schemas, which Postal creates at runtime as postal-server-<id>. A
-- database-level grant on a name pattern also permits CREATE DATABASE for
-- matching names, which is what lets Postal make those schemas itself.
--
-- Deliberately nothing else: no global privileges, nothing on the mysql schema,
-- and no FILE privilege. The root password stays in .env for deploy.sh to use
-- for backups and is never given to the application.
CREATE USER IF NOT EXISTS '${username}'@'%' IDENTIFIED BY '${password}';
ALTER USER '${username}'@'%' IDENTIFIED BY '${password}';
GRANT ALL PRIVILEGES ON \`postal\`.* TO '${username}'@'%';
GRANT ALL PRIVILEGES ON \`postal-server-%\`.* TO '${username}'@'%';
FLUSH PRIVILEGES;
SQL

  chmod 600 "$DB_INIT_DIR/001-postal-user.sql"
  ok "rendered database/init/001-postal-user.sql for user '$username'"
}

# ---------------------------------------------------------------------------

# Say plainly what is still missing, rather than letting the operator discover it
# when compose refuses to start or when a request comes back 403.
init_report() {
  local -a missing=()
  local key

  step "Checking required values"

  for key in RAILS_SECRET_KEY MAIN_DB_PASSWORD MARIADB_ROOT_PASSWORD \
             POSTAL_ADMIN_PASSWORD POSTAL_WEB_HOSTNAME POSTAL_SMTP_HOSTNAME \
             POSTAL_ADMIN_EMAIL CLOUDFLARE_TUNNEL_TOKEN \
             DNS_MX_RECORDS DNS_SPF_INCLUDE DNS_RETURN_PATH_DOMAIN \
             DNS_ROUTE_DOMAIN DNS_TRACK_DOMAIN DNS_HELO_HOSTNAME; do
    [[ -n $(env_get "$key") ]] || missing+=("$key")
  done

  if ((${#missing[@]})); then
    warn "still empty in .env:"
    local m
    for m in "${missing[@]}"; do
      warn "  $m"
    done
    log ""
    log "  Edit $ENV_FILE, or re-run:"
    log "    ./deploy.sh init --domain example.com"
    return 1
  fi

  # Reported separately rather than added to the list above, for the reason given
  # where it is prompted: a host with no public address is a legitimate
  # configuration, so this must not fail init. Leaving it unsaid would let the
  # omission survive to delivery time, where it presents as rejected mail rather
  # than as a missing value.
  if [[ -z $(env_get POSTAL_PUBLIC_IP) ]]; then
    warn "POSTAL_PUBLIC_IP is empty. That is correct for a host with no public"
    warn "  address; otherwise set it, because ./deploy.sh dns cannot print the"
    warn "  A records without it and ./deploy.sh doctor cannot check that the PTR"
    warn "  record matches DNS_HELO_HOSTNAME."
  fi

  ok "all required values are set"
  log ""
  log "  Next:  ./deploy.sh build && ./deploy.sh up"
  log "  Then:  ./deploy.sh dns      # the records to publish"
  log "         ./deploy.sh doctor   # verify the deployment"
}
