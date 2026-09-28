#!/usr/bin/env bash
# ./deploy.sh up | down | restart | ps | logs | exec | status | reset
#
# The compose lifecycle. Each is thin, because the interesting decisions -- which
# worker profile, whether the tunnel is included -- are made in compose() so that
# every command agrees about the shape of the stack. A `ps` that sees a different
# set of services than `up` started reports containers as orphaned.

up_cmd() {
  local debug=false wait=true

  while (($#)); do
    case $1 in
      --without-tunnel) NO_TUNNEL=1; shift ;;
      --debug)          debug=true; shift ;;
      --no-wait)        wait=false; shift ;;
      -h|--help)        up_usage; return 0 ;;
      *)                die "up: unknown option '$1'" ;;
    esac
  done

  if [[ $debug == true ]]; then
    DEPLOY_DEBUG=1
  fi

  require_cmd docker
  load_env
  need_env POSTAL_IMAGE RAILS_SECRET_KEY MAIN_DB_PASSWORD \
           POSTAL_WEB_HOSTNAME POSTAL_SMTP_HOSTNAME
  require_image
  require_signing_key

  up_preflight

  step "Starting the stack"
  info "worker profile: $WORKER_PROFILE$( [[ -n $NO_TUNNEL ]] && echo ', tunnel disabled' )"

  # --remove-orphans matters here specifically because the worker exists as two
  # services of which exactly one is active. Switching POSTAL_USE_IP_POOLS and
  # re-running without it leaves the previous variant running alongside the new
  # one, and two workers draining the same queue is not obviously wrong from the
  # outside -- it just doubles delivery concurrency and confuses the task role.
  compose up -d --remove-orphans

  if [[ $wait == true ]]; then
    # up_wait has already printed the compose state and the two commands which
    # diagnose it, so returning here loses nothing an operator needs -- and
    # without it `up` exits 0 over an unhealthy stack.
    up_wait || return 1
  fi

  up_report
  return 0
}

# Checks which cannot be expressed in the compose file, because they are about
# values agreeing with each other rather than about any one of them being set.
up_preflight() {
  if [[ -z $NO_TUNNEL && -z ${CLOUDFLARE_TUNNEL_TOKEN:-} ]]; then
    log ""
    log "  CLOUDFLARE_TUNNEL_TOKEN is empty. Either set it in $ENV_FILE, or"
    log "  start the origin on its own to diagnose it without Cloudflare:"
    log ""
    log "    ./deploy.sh up --without-tunnel --debug"
    die "no tunnel token"
  fi

  if [[ ${POSTAL_USE_IP_POOLS:-false} == true ]]; then
    warn "IP pools are enabled, so the worker will run on the host network and"
    warn "bind a source address per message. That only works if the addresses"
    warn "are genuinely on an interface of this host. ./deploy.sh doctor checks."
    if [[ -z ${POSTAL_IP_ADDRESSES:-} ]]; then
      warn "POSTAL_USE_IP_POOLS is true but POSTAL_IP_ADDRESSES is empty, so no"
      warn "address is registered and nothing can be assigned to a pool."
    fi
  fi

  # The pinned subnet is named in three places which have to agree: the ipam block
  # in docker-compose.yml, postal.trusted_proxies in config/postal.yml, and the
  # address cloudflared is given. A drift between the first two is invisible until
  # request.ip starts recording the tunnel's address instead of the client's.
  #
  # Both values come from the helpers in common.sh, which doctor also uses, so
  # that the two commands cannot disagree about what is in force.
  local subnet proxies
  subnet="$(compose_subnet)"
  proxies="$(config_trusted_proxy)"

  if [[ -n $subnet && -n $proxies && $subnet != "$proxies" ]]; then
    warn "compose network subnet is $subnet but postal.trusted_proxies is $proxies."
    warn "X-Forwarded-For will be ignored and request.ip will be the tunnel."
  fi
}

# Wait for health rather than for "started". A container can be running and still
# never become healthy -- a wrong POSTAL_WEB_HOSTNAME makes the web healthcheck
# fail forever, because config.hosts rejects the probe's Host header -- and
# reporting success at that point sends the operator looking in the wrong place.
up_wait() {
  local deadline=$(( $(date +%s) + 180 ))
  local unhealthy

  step "Waiting for health"
  while (( $(date +%s) < deadline )); do
    unhealthy="$(compose ps --format '{{.Service}} {{.Health}}' 2>/dev/null |
                 awk '$2 != "" && $2 != "healthy" { print $1 }' | tr '\n' ' ')"
    if [[ -z ${unhealthy// /} ]]; then
      ok "all services healthy"
      return 0
    fi
    info "waiting on:${unhealthy}"
    sleep 5
  done

  warn "timed out waiting for health. Current state:"
  compose ps
  log ""
  log "  ./deploy.sh logs postal     # the web process"
  log "  ./deploy.sh doctor          # what is actually wrong"
  return 1
}

up_report() {
  step "Running"
  compose ps

  log ""
  log "  Web UI and API : https://${POSTAL_WEB_HOSTNAME}"
  log "  Inbound SMTP   : this host, port 25 (${POSTAL_SMTP_HOSTNAME})"
  if [[ -n ${DEPLOY_DEBUG:-} ]]; then
    log "  Debug origin   : http://127.0.0.1:5000  (bypasses Cloudflare and any Access policy)"
  fi
  log ""
  log "  Next:  ./deploy.sh admin    # administrator and first API token"
  log "         ./deploy.sh dns      # the records to publish"
  log "         ./deploy.sh doctor   # verify the deployment"
  return 0
}

up_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh up [--without-tunnel] [--debug] [--no-wait]

Starts MariaDB, the web process, the worker, the SMTP server and the Cloudflare
Tunnel connector, then waits for every healthcheck to pass.

  --without-tunnel  Do not start cloudflared. Use with --debug to reach the
                    origin directly while diagnosing.
  --debug           Also publish the web process on 127.0.0.1:5000. Bypasses
                    Cloudflare, and therefore any Access policy in front of it.
  --no-wait         Return as soon as compose has started the containers.
USAGE
}

# ---------------------------------------------------------------------------

down_cmd() {
  while (($#)); do
    case $1 in
      -h|--help) log "Usage: ./deploy.sh down   (stops the stack, keeps the database volume)"; return 0 ;;
      *)         die "down: unknown option '$1'" ;;
    esac
  done

  require_cmd docker
  load_env

  step "Stopping the stack"
  # No --volumes: that deletes the MariaDB data directory, which is every message
  # this installation has ever received. `./deploy.sh reset` does that, separately
  # and with a confirmation.
  compose down --remove-orphans
  ok "stopped. The database volume is intact."
  return 0
}

restart_cmd() {
  load_env
  step "Restarting"
  compose restart "$@"
  return 0
}

ps_cmd() {
  load_env
  compose ps "$@"
  return 0
}

logs_cmd() {
  load_env
  # --tail bounded by default: an unbounded `logs` on a mail server that has been
  # up for weeks produces more output than a terminal can hold, and the useful
  # part is nearly always at the end.
  compose logs --tail="${LOGS_TAIL:-200}" "$@"
  return 0
}

# A shell, or a single command, inside the running web container. This is the way
# to probe the origin without publishing it: the debug override exists for when
# that is not enough, and it opens a port the debug override's own header warns
# about.
exec_cmd() {
  load_env
  local service=postal
  if [[ ${1:-} == --* ]] || [[ -z ${1:-} ]]; then
    :
  else
    service=$1
    shift
  fi

  if (($#)); then
    compose exec -T "$service" "$@"
  else
    compose exec "$service" /bin/bash
  fi
  return 0
}

status_cmd() {
  load_env
  step "Stack"
  compose ps

  if service_running postal; then
    step "Origin"
    local cid body
    cid="$(container_of postal)"
    # Probed from inside, with the Host header set. config.hosts contains exactly
    # one entry -- postal.web_hostname -- so a probe without it is answered 403 by
    # ActionDispatch::HostAuthorization and says nothing about whether Rails is up.
    body="$(docker exec "$cid" sh -c \
      'curl -sS -o /dev/null -w "%{http_code}" -H "Host: $POSTAL_WEB_HOSTNAME" http://127.0.0.1:5000/api/v2/spec' \
      2>/dev/null || true)"
    # Normalized for the same reason doctor_http normalizes: curl has already
    # written its own code, so `|| echo unreachable` appended to it and reported
    # "000unreachable".
    body="$(normalize_http_code "$body")"
    case $body in
      200) ok "GET /api/v2/spec -> 200" ;;
      403) fail "GET /api/v2/spec -> 403. HostAuthorization rejected the Host header;"
           fail "POSTAL_WEB_HOSTNAME does not match postal.web_hostname." ;;
      000) fail "GET /api/v2/spec -> no response. The web process is not serving"
           fail "on 5000 inside the container; ./deploy.sh logs postal" ;;
      *)   fail "GET /api/v2/spec -> $body" ;;
    esac
  fi
  return 0
}

reset_cmd() {
  load_env

  warn "This deletes the MariaDB volume: every organization, server, credential,"
  warn "domain, message and API token in this installation."

  if [[ ${ASSUME_YES:-} != true ]]; then
    printf '  Type the hostname of this installation to confirm: '
    local answer
    read -r answer || true
    if [[ $answer != "${POSTAL_WEB_HOSTNAME:-}" ]]; then
      die "confirmation did not match '${POSTAL_WEB_HOSTNAME:-}'. Nothing was deleted."
    fi
  fi

  step "Destroying the stack and its volumes"
  compose down --volumes --remove-orphans
  ok "removed. ./deploy.sh migrate will recreate the schema."
  return 0
}
