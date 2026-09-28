#!/usr/bin/env bash
# ./deploy.sh admin | ip
#
# The two operations which create rows the API cannot: the administrator and the
# first token, and the outbound IP addresses. Everything else in a running
# installation is reachable over /api/v2.

admin_cmd() {
  local save=true

  while (($#)); do
    case $1 in
      --new-token)  export POSTAL_FORCE_NEW_TOKEN=1; shift ;;
      --name)       export POSTAL_TOKEN_NAME=${2:?--name needs a value}; shift 2 ;;
      --no-save)    save=false; shift ;;
      -h|--help)    admin_usage; return 0 ;;
      *)            die "admin: unknown option '$1'" ;;
    esac
  done

  require_cmd docker
  load_env
  need_env POSTAL_IMAGE POSTAL_ADMIN_EMAIL POSTAL_ADMIN_PASSWORD
  require_image

  export POSTAL_TOKEN_NAME="${POSTAL_TOKEN_NAME:-deploy}"

  step "Creating the administrator and the first API token"
  info "email=${POSTAL_ADMIN_EMAIL} token='${POSTAL_TOKEN_NAME}'"

  # The password is forwarded with -e rather than added to the compose file, which
  # is committed. bootstrap_run names each variable explicitly, so nothing else in
  # .env leaks into the container's environment.
  local out marker
  out="$(bootstrap_run \
    POSTAL_ADMIN_EMAIL POSTAL_ADMIN_PASSWORD \
    POSTAL_TOKEN_NAME POSTAL_FORCE_NEW_TOKEN -- \
    bundle exec rails runner /deploy-lib/ensure_admin.rb 2>&1)"
  marker="$(printf '%s\n' "$out" | marker_line POSTAL_ADMIN)"

  if [[ -z $marker ]]; then
    printf '%s\n' "$out"
    die "ensure_admin.rb did not report a result"
  fi

  local key uuid prefix created_user orgs
  key="$(json_get "$marker" token)"
  uuid="$(json_get "$marker" token_uuid)"
  prefix="$(json_get "$marker" token_key_prefix)"
  created_user="$(json_get_raw "$marker" created_user)"
  orgs="$(json_get_raw "$marker" organizations)"

  # json_get returns empty for a JSON null, which is how ensure_admin.rb signals
  # "a token already existed and its key is not recoverable".
  if [[ -n $key ]]; then
    ok "created administrator ${POSTAL_ADMIN_EMAIL}"
    ok "created API token '${POSTAL_TOKEN_NAME}' (${uuid})"
    log ""
    log "  ${C_BOLD}${key}${C_RESET}"
    log ""
    log "  Send it as:   X-Postal-API-Key: ${key}"
    log "  This is the only time it is shown. Only the SHA-256 digest is stored,"
    log "  so it cannot be read back -- ./deploy.sh admin --new-token mints another."

    if [[ $save == true ]]; then
      # Saved so that ./deploy.sh dns and ./deploy.sh doctor can call the API
      # without the operator pasting a key each time. .env is gitignored, is
      # chmod 600, and already holds the database passwords, so this does not
      # widen what that file exposes. It stays host side: compose only forwards
      # the variables each service lists, and none of them list this one.
      env_set POSTAL_API_TOKEN "$key"
      ok "saved to POSTAL_API_TOKEN in $ENV_FILE (--no-save to skip)"
    fi
  else
    ok "administrator ${POSTAL_ADMIN_EMAIL} already existed"
    ok "active token '${POSTAL_TOKEN_NAME}' already existed (${prefix}..., ${uuid})"
    info "its key cannot be shown again. ./deploy.sh admin --new-token to mint one."
  fi

  if [[ ${created_user:-false} == true ]]; then
    log ""
    log "  Web UI login: ${POSTAL_ADMIN_EMAIL} / the POSTAL_ADMIN_PASSWORD in .env"
  fi

  if [[ ${orgs:-0} == 0 ]]; then
    log ""
    info "No organizations exist yet. Create one in the web UI, or over the API:"
    info "  POST /api/v2/organizations  {\"name\": \"...\", \"permalink\": \"...\"}"
  fi

  return 0
}

admin_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh admin [--name TOKEN] [--new-token] [--no-save]

Creates the administrator named by POSTAL_ADMIN_EMAIL and an API token, printing
the plain `pst_` key once. Idempotent: an existing administrator and an existing
active token of the same name are left alone.

  --name TOKEN    Name the token something other than "deploy".
  --new-token     Mint a new token even though an active one exists. The old one
                  is left active, so anything still using it keeps working.
  --no-save       Do not write the key to POSTAL_API_TOKEN in .env.
USAGE
}

# ---------------------------------------------------------------------------

ip_cmd() {
  while (($#)); do
    case $1 in
      -h|--help) ip_usage; return 0 ;;
      *)         die "ip: unknown option '$1'" ;;
    esac
  done

  require_cmd docker
  load_env
  need_env POSTAL_IMAGE POSTAL_IP_ADDRESSES
  require_image

  export POSTAL_IP_POOL_NAME="${POSTAL_IP_POOL_NAME:-Default}"

  step "Registering outbound IP addresses"

  local out marker
  out="$(bootstrap_run POSTAL_IP_ADDRESSES POSTAL_IP_POOL_NAME -- \
    bundle exec rails runner /deploy-lib/register_ips.rb 2>&1)"
  marker="$(printf '%s\n' "$out" | marker_line POSTAL_IPS)"

  if [[ -z $marker ]]; then
    printf '%s\n' "$out"
    die "register_ips.rb did not report a result"
  fi

  local pool created
  pool="$(json_get "$marker" pool)"
  created="$(json_get_raw "$marker" created_pool)"
  ok "pool '${pool}' $([[ $created == true ]] && echo created || echo existing)"

  # Reported one per line. The objects are matched by containing "ipv4" rather
  # than by an exact field sequence, so adding a field to register_ips.rb cannot
  # silently make this print nothing. `[^{}]*` keeps each match inside one object,
  # which also stops it spanning into the errors array.
  # `{ grep ... || true; }`: registering no addresses at all is a legitimate
  # outcome -- POSTAL_IPS empty, or every entry rejected into the errors array
  # reported below -- and grep exits 1 when it matches nothing, which pipefail
  # would turn into an abort rather than an empty list.
  printf '%s' "$marker" |
    sed 's/},{/}\n{/g' |
    { grep -o '{[^{}]*"ipv4"[^{}]*}' || true; } |
    while read -r entry; do
      local v4 host action
      v4="$(printf '%s' "$entry" | sed -n 's/.*"ipv4":"\([^"]*\)".*/\1/p')"
      host="$(printf '%s' "$entry" | sed -n 's/.*"hostname":"\([^"]*\)".*/\1/p')"
      action="$(printf '%s' "$entry" | sed -n 's/.*"action":"\([^"]*\)".*/\1/p')"
      printf '  %-9s %-16s -> %s\n' "$action" "$v4" "$host"
    done

  if printf '%s' "$marker" | grep -q '"errors":\[[^]]'; then
    warn "some entries were rejected:"
    printf '%s' "$marker" | grep -o '"errors":\[[^]]*\]' | sed 's/","/\n/g; s/"errors":\["//; s/"\]$//' |
      while read -r e; do warn "  $e"; done
  fi

  log ""
  if [[ ${POSTAL_USE_IP_POOLS:-false} != true ]]; then
    warn "postal.use_ip_pools is false, so servers are not assigned to pools and"
    warn "these addresses will not be used for delivery. Set POSTAL_USE_IP_POOLS"
    warn "true in .env, re-run ./deploy.sh init, and restart with ./deploy.sh up."
  fi
  info "Each address must also be on an interface of the host running the worker,"
  info "and its hostname must be that address's PTR record. ./deploy.sh doctor checks."
  return 0
}

ip_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh ip

Registers the outbound IP addresses listed in POSTAL_IP_ADDRESSES, each as
ipv4=hostname, into the pool named by POSTAL_IP_POOL_NAME. Idempotent: an address
already present is left alone unless its hostname changed.

There is no API route for this. config/routes.rb exposes ip_addresses only as a
web-UI resource nested under ip_pools, and the API gives ip_pools `only: [:index]`.
USAGE
}
