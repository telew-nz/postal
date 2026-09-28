#!/usr/bin/env bash
# ./deploy.sh doctor -- assert the deployment rather than assume it.
#
# Every check here asks something which has an observable answer: what the
# application resolved, what the tunnel serves, what port 25 says, what DNS
# returns, which worker holds the tasks role. None of it reads a file and reports
# that the file exists.
#
# Exits non-zero if any check failed, so it can be used as a gate after `up` and
# after `upgrade`.
#
# Counters are incremented by the d_* helpers below. Every loop in this file is
# therefore fed by a here-string rather than by a pipeline: `cmd | while read`
# runs the loop body in a subshell, where the increments would be discarded and
# doctor would report zero failures having printed several.

DOCTOR_PASS=0
DOCTOR_WARN=0
DOCTOR_FAIL=0
DOCTOR_SKIP=0

# Raw output of doctor_checks.rb, filled by doctor_runner.
DOCTOR_OUT=""
# The single POSTAL_DOCTOR line within it, holding the resolved configuration.
DOCTOR_CFG=""

d_ok()   { DOCTOR_PASS=$((DOCTOR_PASS + 1)); ok "$*"; }
d_warn() { DOCTOR_WARN=$((DOCTOR_WARN + 1)); warn "$*"; }
d_fail() { DOCTOR_FAIL=$((DOCTOR_FAIL + 1)); fail "$*"; }
d_skip() { DOCTOR_SKIP=$((DOCTOR_SKIP + 1)); info "skip  $*"; }

doctor_cmd() {
  local quick=false

  while (($#)); do
    case $1 in
      --quick)   quick=true; shift ;;
      -h|--help) doctor_usage; return 0 ;;
      *)         die "doctor: unknown option '$1'" ;;
    esac
  done

  require_cmd docker
  require_cmd curl
  load_env
  need_env POSTAL_IMAGE POSTAL_WEB_HOSTNAME POSTAL_SMTP_HOSTNAME

  step "Files and configuration on disk"
  doctor_files

  step "Containers"
  doctor_stack

  step "HTTPS through the tunnel"
  doctor_http

  step "Management API"
  doctor_api

  step "Inbound SMTP on port 25"
  doctor_smtp

  step "Inbound SMTP TLS"
  doctor_tls

  if [[ $quick == true ]]; then
    d_skip "everything which needs a container (--quick)"
  else
    doctor_runner
  fi

  doctor_summary || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Host side

doctor_files() {
  if [[ -f $SIGNING_KEY ]]; then
    d_ok "signing key present at $SIGNING_KEY"
    # The container runs as uid 999 and ./config is mounted read-only. A key it
    # cannot read produces mail which is delivered but does not verify, which is
    # visible only to the recipient's mail server.
    if [[ $(id -u) -ne 0 ]]; then
      local owner
      owner="$(stat -c '%u' "$SIGNING_KEY" 2>/dev/null || echo '?')"
      if [[ $owner == "$POSTAL_UID" ]]; then
        d_ok "signing key owned by uid $POSTAL_UID"
      else
        d_fail "signing key is owned by uid $owner, the container runs as $POSTAL_UID"
        fail "  sudo chown $POSTAL_UID:$POSTAL_UID $SIGNING_KEY"
      fi
    fi
  else
    d_fail "signing key missing -- run ./deploy.sh init"
  fi

  if [[ -f $CONFIG_DIR/postal.yml ]]; then
    d_ok "config/postal.yml present"
    # Without `version: 2` the file is read through LegacyConfigSource and every
    # v2 key in it is ignored silently, with no error anywhere.
    if grep -q '^version: 2' "$CONFIG_DIR/postal.yml"; then
      d_ok "config/postal.yml declares version 2"
    else
      d_fail "config/postal.yml does not declare 'version: 2', so its keys are ignored"
    fi
  else
    d_fail "config/postal.yml missing"
  fi

  # .env holds every secret in this installation. Checked rather than assumed
  # because env_set writes it 600 but a copy made by hand may not be.
  if [[ -f $ENV_FILE && $(id -u) -ne 0 ]]; then
    local mode
    mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '?')"
    if [[ $mode == 600 || $mode == 400 ]]; then
      d_ok ".env is mode $mode"
    else
      d_warn ".env is mode $mode and holds the database passwords and API token"
      warn "  chmod 600 $ENV_FILE"
    fi
  fi

  local subnet proxies
  subnet="$(compose_subnet)"
  proxies="$(config_trusted_proxy)"
  if [[ -z $subnet || -z $proxies ]]; then
    d_skip "subnet/trusted_proxies comparison (could not read both)"
  elif [[ $subnet == "$proxies" ]]; then
    d_ok "postal.trusted_proxies matches the compose subnet ($subnet)"
  else
    # Not a warning: with these disagreeing, X-Forwarded-For from cloudflared is
    # not trusted, so request.ip is the tunnel's address for every request. Rate
    # limiting then applies to all clients at once and the logs are useless, with
    # nothing in the application reporting it.
    d_fail "compose subnet is $subnet but postal.trusted_proxies is $proxies"
    fail "  request.ip will be the tunnel, not the client. Make them agree."
  fi

  # Two independent declarations of the compose project name: --project-name in
  # common.sh and `name:` at the top of docker-compose.yml. The CLI wins, so a
  # divergence is silent -- and the project name is what the MariaDB volume is
  # called, so getting it wrong presents as a healthy, completely empty
  # installation rather than as an error.
  local file_project
  file_project="$(sed -n 's/^name:[[:space:]]*//p' "$COMPOSE_FILE" | head -n1)"
  if [[ -z $file_project ]]; then
    d_skip "compose project name (docker-compose.yml declares no 'name:')"
  elif [[ $file_project == "$COMPOSE_PROJECT" ]]; then
    d_ok "compose project name is '$COMPOSE_PROJECT' in both places"
  else
    d_fail "docker-compose.yml declares name '$file_project' but deploy.sh uses '$COMPOSE_PROJECT'"
    fail "  The data volume is called ${COMPOSE_PROJECT}_postal-data, so this"
    fail "  decides which database the stack opens."
  fi
  return 0
}

doctor_stack() {
  local expected=(mariadb postal smtp)
  if [[ ${POSTAL_USE_IP_POOLS:-false} == true ]]; then
    expected+=(worker-hostnet)
  else
    expected+=(worker)
  fi
  if [[ -z ${CLOUDFLARE_TUNNEL_TOKEN:-} ]]; then
    d_skip "cloudflared (CLOUDFLARE_TUNNEL_TOKEN is empty)"
  else
    expected+=(cloudflared)
  fi

  # Read once, rather than invoking compose per service: compose re-resolves the
  # whole project on every call and the answers have to describe one moment.
  local ps svc state health seen
  ps="$(compose ps --format '{{.Service}}|{{.State}}|{{.Health}}' 2>/dev/null || true)"
  seen=""

  local s
  for s in "${expected[@]}"; do
    svc="$(printf '%s\n' "$ps" | awk -F'|' -v want="$s" '$1 == want { print; exit }')"
    if [[ -z $svc ]]; then
      d_fail "$s is not running"
      continue
    fi
    seen="$seen $s"
    state="$(printf '%s' "$svc" | cut -d'|' -f2)"
    health="$(printf '%s' "$svc" | cut -d'|' -f3)"

    if [[ $state != running ]]; then
      d_fail "$s is $state"
    elif [[ -n $health && $health != healthy ]]; then
      # Running but not healthy is worth more than running: a wrong
      # POSTAL_WEB_HOSTNAME makes the web healthcheck fail forever because
      # config.hosts rejects the probe's Host header.
      d_fail "$s is running but $health"
    else
      d_ok "$s is ${health:-running}"
    fi
  done

  # The worker exists as two services of which exactly one may run. Both running
  # at once doubles delivery concurrency and confuses the tasks role, and looks
  # entirely normal from the outside.
  local workers
  workers="$(printf '%s\n' "$ps" | awk -F'|' '$1 == "worker" || $1 == "worker-hostnet" { print $1 }' | tr '\n' ' ')"
  local count
  count="$(printf '%s' "$workers" | wc -w | tr -d ' ')"
  if [[ ${count:-0} -gt 1 ]]; then
    d_fail "two worker variants are running:${workers}"
    fail "  ./deploy.sh down && ./deploy.sh up   (--remove-orphans clears the old one)"
  fi
  return 0
}

doctor_http() {
  local url="https://${POSTAL_WEB_HOSTNAME}/api/v2/spec"
  local code
  # `|| true`, not `|| echo 000`: curl has already written its own %{http_code}
  # to stdout when it fails, so appending a second one produced "000000", which
  # matched no arm of the case below and was reported as an unknown status. The
  # `|| true` is still needed -- errexit is active, and a bare assignment whose
  # command substitution fails aborts the whole command.
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || true)"
  code="$(normalize_http_code "$code")"

  case $code in
    200) d_ok "GET $url -> 200" ;;
    403)
      # HostAuthorization. config.hosts receives exactly one entry,
      # postal.web_hostname, so this is never a permissions question.
      d_fail "GET $url -> 403"
      fail "  ActionDispatch::HostAuthorization rejected the Host header."
      fail "  POSTAL_WEB_HOSTNAME must equal postal.web_hostname, and must be"
      fail "  the public hostname the tunnel serves -- not the origin's name."
      ;;
    000)
      d_fail "GET $url -> no response"
      fail "  DNS does not resolve to the tunnel, the tunnel is down, or the"
      fail "  public hostname has no ingress rule. ./deploy.sh logs cloudflared"
      ;;
    404)
      d_warn "GET $url -> 404"
      warn "  Expected if API_ENABLED is false; otherwise the route is missing,"
      warn "  which means the image was built from a revision without the API."
      ;;
    301|302|307|308)
      d_warn "GET $url -> $code (redirect). Follow it to see where it lands."
      ;;
    *)
      d_fail "GET $url -> $code"
      ;;
  esac

  # The origin, probed from inside. Separating this from the result above is the
  # whole point: if the origin answers and the public name does not, the fault is
  # in the tunnel or in DNS, and there is no reason to look at the application.
  if service_running postal; then
    local cid origin_code
    cid="$(container_of postal)"
    origin_code="$(docker exec "$cid" sh -c \
      'curl -sS -o /dev/null -w "%{http_code}" --max-time 10 -H "Host: $POSTAL_WEB_HOSTNAME" http://127.0.0.1:5000/api/v2/spec' \
      2>/dev/null || true)"
    origin_code="$(normalize_http_code "$origin_code")"
    case $origin_code in
      200) d_ok "origin answers 200 with the right Host header" ;;
      403) d_fail "origin answers 403: POSTAL_WEB_HOSTNAME != postal.web_hostname" ;;
      *)   d_fail "origin answers $origin_code, so the fault is not the tunnel" ;;
    esac
  else
    d_skip "origin probe (the postal container is not running)"
  fi
  return 0
}

doctor_api() {
  # The unauthenticated case is checked first and deliberately: /api/v2/spec is
  # not authenticated by design, but /api/v2/me is, and an installation which
  # answers /me without a key has an authentication problem rather than a
  # configuration one.
  local saved="${POSTAL_API_TOKEN:-}"
  POSTAL_API_TOKEN=""

  # Not `body="$(api_request ...)"`: that runs api_request in a subshell and
  # leaves API_STATUS at its initialized value, so the case below would always
  # take the 000 arm and report the API as unreachable whatever it answered.
  api_request GET /api/v2/me
  local body="$API_BODY"
  case $API_STATUS in
    401)
      if printf '%s' "$body" | grep -q MissingAPIKey; then
        d_ok "GET /api/v2/me without a key -> 401 MissingAPIKey"
      else
        d_warn "GET /api/v2/me without a key -> 401, but not MissingAPIKey: $body"
      fi
      ;;
    200) d_fail "GET /api/v2/me without a key -> 200. Authentication is not being enforced." ;;
    000) d_skip "API auth checks (the API is unreachable from here)" ;;
    *)   d_fail "GET /api/v2/me without a key -> $API_STATUS" ;;
  esac

  POSTAL_API_TOKEN="$saved"

  if [[ -z $saved ]]; then
    d_skip "authenticated API check (POSTAL_API_TOKEN is not set; ./deploy.sh admin saves one)"
    return 0
  fi

  api_request GET /api/v2/me
  body="$API_BODY"
  case $API_STATUS in
    200)
      local email
      email="$(json_get "$body" email_address)"
      d_ok "GET /api/v2/me with the saved key -> 200 (${email:-unknown user})"
      ;;
    401)
      d_fail "GET /api/v2/me with the saved key -> 401"
      if printf '%s' "$body" | grep -q InvalidAPIKey; then
        fail "  The token is unknown, revoked or expired. ./deploy.sh admin --new-token"
      else
        fail "  $body"
      fi
      ;;
    # The same branch the unauthenticated check above has. Without it one
    # unreachable host produced a skip and a FAIL for the same cause, and the
    # FAIL read as a broken installation rather than as a host with no route to
    # the public hostname.
    000) d_skip "authenticated API check (the API is unreachable from here)" ;;
    *) d_fail "GET /api/v2/me with the saved key -> $API_STATUS" ;;
  esac
  return 0
}

doctor_smtp() {
  # 127.0.0.1 first. This proves the container is listening and that the port is
  # published on the host, which is the part under this installation's control.
  local banner
  banner="$(doctor_tcp_banner 127.0.0.1 25 || true)"

  if [[ -z $banner ]]; then
    d_fail "no SMTP banner on 127.0.0.1:25"
    fail "  Is the smtp container running? ./deploy.sh logs smtp"
  else
    doctor_check_banner "127.0.0.1:25" "$banner"
  fi

  # Then by the name inbound mail actually arrives at. This exercises DNS and the
  # provider's firewall as well, so a failure here is not necessarily a fault in
  # this installation: many hosts cannot reach their own public address, because
  # the provider does not hairpin.
  if [[ -n ${POSTAL_PUBLIC_IP:-} && $POSTAL_SMTP_HOSTNAME != "$POSTAL_PUBLIC_IP" ]]; then
    local pub
    pub="$(doctor_tcp_banner "$POSTAL_SMTP_HOSTNAME" 25 || true)"
    if [[ -z $pub ]]; then
      d_warn "no SMTP banner at ${POSTAL_SMTP_HOSTNAME}:25"
      warn "  Check from another network before concluding anything: a host often"
      warn "  cannot reach its own public address. MX records will not deliver here"
      warn "  until this works from outside."
    else
      doctor_check_banner "${POSTAL_SMTP_HOSTNAME}:25" "$pub"
    fi
  else
    d_skip "external SMTP probe (set POSTAL_PUBLIC_IP)"
  fi
  return 0
}

doctor_check_banner() {
  local where=$1 banner=$2

  if [[ $banner != 220* ]]; then
    d_fail "$where answered '$banner', which is not a 220 greeting"
    return 0
  fi

  # The banner is built at smtp_server/server.rb:132 as
  # "220 #{postal.smtp_hostname} ESMTP Postal/#{trace_id}", so the hostname in it
  # is the resolved configuration value, read back over the wire.
  if [[ $banner == *"$POSTAL_SMTP_HOSTNAME"* ]]; then
    d_ok "$where greets as $POSTAL_SMTP_HOSTNAME"
  else
    d_fail "$where greets '$banner' but POSTAL_SMTP_HOSTNAME is $POSTAL_SMTP_HOSTNAME"
    fail "  The banner carries postal.smtp_hostname, so the running container is"
    fail "  using a different value than .env -- rebuild or restart it."
  fi

  if [[ $banner == *example.com* ]]; then
    d_fail "$where still announces an example.com hostname"
  fi
  return 0
}

# Read the greeting from a TCP port. bash's /dev/tcp has no timeout of its own
# and a host which silently drops packets on port 25 -- the common case when the
# provider blocks it -- would otherwise hang doctor until it is interrupted, so
# the connect and the read are both bounded.
doctor_tcp_banner() {
  local host=$1 port=$2 wait=${3:-8}

  # Passed as positional arguments rather than interpolated into the script text,
  # so that a hostname cannot change what is executed.
  local -a inner=(bash -c '
    exec 3<>"/dev/tcp/$1/$2" || exit 2
    IFS= read -r -t "$3" -u 3 line || true
    printf "%s" "$line"
  ' _ "$host" "$port" "$wait")

  if command -v timeout >/dev/null 2>&1; then
    timeout "$((wait + 4))" "${inner[@]}" 2>/dev/null | tr -d '\r'
  else
    "${inner[@]}" 2>/dev/null | tr -d '\r'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The certificate the SMTP server presents
#
# Host-side like everything above it: the files are on the host and port 25 is
# published on the host, so a check from here is a check from roughly where a
# sender is. The one part which is not host-side is the resolved configuration,
# which doctor_config reads from inside the installation -- and the two are
# compared in doctor_tls_runtime below, because they disagree in exactly one
# situation and it is a common one.

doctor_tls() {
  local from_env="${SMTP_SERVER_TLS_ENABLED:-false}"

  if [[ $from_env != true ]]; then
    d_skip "SMTP TLS (SMTP_SERVER_TLS_ENABLED is not true)"
    # Reported rather than left silent. An installed certificate which nothing
    # reads is indistinguishable from no certificate at all, and whoever installed
    # it will believe TLS is on.
    if [[ -f $TLS_CERT ]]; then
      d_warn "config/smtp.cert exists but SMTP_SERVER_TLS_ENABLED is not true"
      warn "  the certificate is installed and unused: ./deploy.sh tls install"
    fi
    return 0
  fi

  if [[ ! -f $TLS_CERT || ! -f $TLS_KEY ]]; then
    d_fail "SMTP_SERVER_TLS_ENABLED is true but a certificate or key is missing"
    fail "  STARTTLS is being advertised on a handshake which cannot complete, and"
    fail "  that is worse than TLS being off: a sender enforcing MTA-STS will refuse"
    fail "  to deliver rather than fall back to plaintext, while an opportunistic"
    fail "  sender would have delivered over plaintext all along."
    fail "  ./deploy.sh tls install, or set SMTP_SERVER_TLS_ENABLED=false"
    return 0
  fi

  doctor_tls_permissions
  doctor_tls_certificate
  doctor_tls_names
  doctor_tls_runtime
  return 0
}

doctor_tls_permissions() {
  local f owner mode
  for f in "$TLS_CERT" "$TLS_KEY"; do
    owner="$(stat -c '%u' "$f" 2>/dev/null || echo '?')"
    mode="$(stat -c '%a' "$f" 2>/dev/null || echo '?')"
    if [[ $owner == "$POSTAL_UID" ]]; then
      d_ok "$(basename "$f") is owned by uid $POSTAL_UID (mode $mode)"
    else
      # Not merely untidy. The container reads these at process start through a
      # read-only mount as uid 999, and a key it cannot read makes ssl_context
      # raise. server.rb catches that, logs it and drops the connection.
      d_fail "$(basename "$f") is owned by uid $owner; the container runs as $POSTAL_UID"
      fail "  sudo chown $POSTAL_UID:$POSTAL_UID $f"
    fi
  done
  return 0
}

doctor_tls_certificate() {
  local count
  count="$(tls_cert_chain_count "$TLS_CERT")"
  if [[ ${count:-0} -ge 2 ]]; then
    d_ok "the chain holds $count certificates, so the intermediate is presented"
  else
    # server.rb scans every PEM block in the file in order, assigns the first to
    # the context and the rest to extra_chain_cert. A leaf-only file therefore
    # gives an empty extra_chain_cert, and a peer without the intermediate cached
    # cannot build a path to a trust anchor. Let's Encrypt's intermediate is
    # widely cached, so this passes most of the time and then fails for one
    # sender -- which is why it is a failure here rather than a warning.
    d_fail "the chain holds ${count:-0} certificate(s); the intermediate is missing"
    fail "  ./deploy.sh tls install   reinstalls the full chain"
  fi

  case "$(tls_key_matches_cert)" in
    yes) d_ok "the private key matches the certificate" ;;
    no)  d_fail "the private key does NOT match the certificate" ;;
    *)   d_fail "openssl could not parse config/smtp.cert or config/smtp.key" ;;
  esac

  case "$(tls_is_self_signed)" in
    yes)
      # script/generate_tls_certificate.rb produces exactly this, at exactly this
      # filename. Nothing else here would object to one being left behind.
      d_fail "the certificate is self-signed"
      fail "  no remote server will trust it: ./deploy.sh tls issue"
      ;;
    no)  d_ok "the certificate is issued by $(tls_cert_issuer)" ;;
    *)   d_fail "the certificate's subject and issuer could not be read" ;;
  esac

  case "$(tls_expiry_verdict "$TLS_CERT")" in
    expired)
      d_fail "the certificate has EXPIRED"
      fail "  senders which enforce MTA-STS will refuse to deliver here, and the"
      fail "  renewal timer has been failing for at least 90 days"
      ;;
    week)
      d_fail "the certificate expires within 7 days"
      fail "  ./deploy.sh tls renew --force"
      ;;
    three-weeks)
      # With a 30-day renewal window this means at least one renewal attempt has
      # already failed. Worth a warning rather than a failure: mail still flows.
      d_warn "the certificate expires within 21 days, so a renewal has already been missed"
      warn "  ./deploy.sh tls renew --force, then check the timer is installed"
      ;;
    ok) d_ok "the certificate is valid for more than 21 days" ;;
    *)  d_fail "openssl could not read config/smtp.cert" ;;
  esac
  return 0
}

doctor_tls_names() {
  local sans missing n
  sans="$(tls_cert_sans "$TLS_CERT")"
  if [[ -z $sans ]]; then
    d_fail "the certificate has no Subject Alternative Names"
    fail "  peers match on SAN, not on the subject CN, so nothing will accept it"
    return 0
  fi

  # Derived the way tls_load_domains does it, but without that function's
  # precondition that DNS_MX_RECORDS is set. Doctor runs against installations in
  # every state, and a missing MX list should not abort the rest of the audit.
  if [[ -z ${DNS_MX_RECORDS:-} ]]; then
    d_skip "MX name coverage (DNS_MX_RECORDS is empty)"
    return 0
  fi
  tls_load_domains

  missing="$(tls_missing_names)"
  if [[ -n $missing ]]; then
    d_fail "the certificate does not cover: $(printf '%s' "$missing" | tr '\n' ' ')"
    fail "  a sender connecting to any of those names rejects the handshake."
    fail "  ./deploy.sh tls issue   re-issues for the current name set -- a"
    fail "  renewal will not add names, it renews the certificate as it stands."
  else
    local -a want=()
    for n in ${TLS_DOMAINS[@]+"${TLS_DOMAINS[@]}"}; do want+=("$n"); done
    d_ok "the certificate covers all ${#want[@]} required name(s)"
  fi
  return 0
}

# The two values which have to agree and are read in two different places.
#
# .env is what doctor_config and everything above reads. The container's own
# environment is what the process was started with, and those diverge whenever
# .env is edited and the container is restarted rather than recreated --
# `docker compose restart` reuses the existing container and therefore its
# original environment. The divergence is invisible from either side alone: .env
# says TLS is on, the process says it is off, and the port simply stops offering
# STARTTLS.
doctor_tls_runtime() {
  if ! service_running smtp; then
    d_skip "the running container's TLS setting (smtp is not running)"
    return 0
  fi

  local cid inside
  cid="$(container_of smtp)"
  inside="$(docker exec "$cid" printenv SMTP_SERVER_TLS_ENABLED 2>/dev/null || true)"
  if [[ $inside == true ]]; then
    d_ok "the running smtp container has SMTP_SERVER_TLS_ENABLED=true"
  else
    d_fail "the running smtp container has SMTP_SERVER_TLS_ENABLED='${inside:-unset}' but .env says true"
    fail "  it was restarted rather than recreated, so it kept its old environment:"
    fail "  docker compose up -d --no-deps smtp   (which ./deploy.sh tls install does)"
    return 0
  fi

  # The handshake itself, which is the only check here answering the question
  # anyone actually cares about. It earns its place: server.rb rescues
  # OpenSSL::SSL::SSLError during negotiation and logs "SSL Negotiation Failed" at
  # debug level, off in production, so a certificate every remote server rejects
  # produces no output on this host at all.
  local verdict detail
  verdict="$(tls_probe_live)"
  case $verdict in
    ok)
      d_ok "a real STARTTLS handshake on port 25 verified against this host's trust store"
      ;;
    nostarttls)
      d_fail "port 25 completed no TLS handshake and presented no certificate"
      fail "  the process has the flag set, so the certificate it loaded is unusable:"
      fail "  ./deploy.sh logs smtp, and ./deploy.sh tls status"
      ;;
    unreachable)
      d_warn "nothing answered a STARTTLS probe on 127.0.0.1:25"
      ;;
    untrusted\|*)
      detail="${verdict#untrusted|}"
      d_fail "the presented certificate did not verify: $detail"
      fail "  This is what a remote sender sees, and it is the failure this host"
      fail "  never reports: negotiation errors are logged at debug level."
      ;;
    *)
      d_warn "unrecognised handshake probe result: $verdict"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Inside the installation

doctor_runner() {
  step "Inside the installation"

  if ! docker image inspect "$POSTAL_IMAGE" >/dev/null 2>&1; then
    d_skip "image '$POSTAL_IMAGE' is absent -- run ./deploy.sh build"
    return 0
  fi

  # Forwarded explicitly: compose only passes into the container the variables
  # the service definition names, and this one is not in the committed file
  # because nothing in Postal reads it.
  export DOCTOR_PUBLIC_IP="${POSTAL_PUBLIC_IP:-}"

  local out
  out="$(bootstrap_run DOCTOR_PUBLIC_IP -- \
    bundle exec rails runner /deploy-lib/doctor_checks.rb 2>&1)" || true

  DOCTOR_CFG="$(printf '%s\n' "$out" | marker_line POSTAL_DOCTOR)"
  if [[ -z $DOCTOR_CFG ]]; then
    d_fail "doctor_checks.rb reported nothing"
    printf '%s\n' "$out" | tail -n 15 | while read -r line; do fail "  $line"; done
    return 0
  fi
  DOCTOR_OUT="$out"

  doctor_config
  doctor_database
  doctor_dns
  doctor_ip_addresses
  return 0
}

doctor_config() {
  local v
  v="$(json_get "$DOCTOR_CFG" web_protocol)"
  if [[ $v == https ]]; then
    d_ok "postal.web_protocol is https, which is what a tunnel needs"
  else
    d_fail "postal.web_protocol is '$v': generated links and redirects will be http"
    fail "  The local test stack overrides this to http because nothing there"
    fail "  terminates TLS. Production must not inherit that."
  fi

  v="$(json_get "$DOCTOR_CFG" rails_environment)"
  if [[ $v == production ]]; then
    d_ok "rails.environment is production"
  else
    d_fail "rails.environment is '$v'"
  fi

  # Reported rather than judged when enabled: the API is on by default and
  # /api/v2/spec is unauthenticated, so anyone who can reach the hostname can
  # enumerate the whole surface. Whether that is acceptable depends on the Access
  # policy in front of it, which is not visible from here.
  v="$(json_get_raw "$DOCTOR_CFG" api_enabled)"
  if [[ $v == true ]]; then
    d_warn "api.enabled is true and GET /api/v2/spec is unauthenticated"
    warn "  Put a Cloudflare Access policy on this hostname, or set API_ENABLED"
    warn "  false. See the security section of doc/deployment.md."
  else
    d_ok "api.enabled is false"
  fi

  v="$(json_get_raw "$DOCTOR_CFG" signing_key_present)"
  if [[ $v == true ]]; then
    d_ok "the container can read the signing key"
  else
    d_fail "the container cannot read $(json_get "$DOCTOR_CFG" signing_key_path)"
  fi

  # trusted_proxies reaches the application as IPAddr objects, so this compares
  # the value after the schema's transform has run rather than the string in .env.
  local proxies subnet
  proxies="$(json_get "$DOCTOR_CFG" trusted_proxies)"
  subnet="$(compose_subnet)"
  if [[ -n $subnet && $proxies == *"$subnet"* ]]; then
    d_ok "the running application trusts $subnet"
  else
    d_fail "the running application trusts [$proxies], not the compose subnet $subnet"
  fi

  # IP pools change how the worker runs, so the configuration and the container
  # have to agree. use_ip_pools true with a bridge-networked worker means every
  # delivery attempts to bind an address the container does not hold and fails
  # with EADDRNOTAVAIL.
  local pools
  pools="$(json_get_raw "$DOCTOR_CFG" use_ip_pools)"
  if [[ $pools == true ]]; then
    if service_running worker-hostnet; then
      d_ok "use_ip_pools is true and the host-networked worker is running"
    else
      d_fail "use_ip_pools is true but the bridge-networked worker is running"
      fail "  Delivery will fail with EADDRNOTAVAIL. ./deploy.sh down && ./deploy.sh up"
    fi
  elif service_running worker; then
    d_ok "use_ip_pools is false and the bridge-networked worker is running"
  fi

  # The value the application itself resolved, which is the authoritative one
  # because it accounts for the environment overriding the YAML. Compared against
  # the running smtp container's own environment in doctor_tls_runtime: the two
  # disagree whenever .env is edited and the container is restarted rather than
  # recreated.
  v="$(json_get_raw "$DOCTOR_CFG" smtp_tls_enabled)"
  if [[ $v == true ]]; then
    d_ok "smtp_server.tls_enabled is true, so STARTTLS is offered on port 25"
  else
    d_warn "smtp_server.tls_enabled is false, so inbound mail is not offered STARTTLS"
    warn "  Not a defect on its own: inbound SMTP is opportunistic, and a sender"
    warn "  which cannot validate a session falls back to plaintext and still"
    warn "  delivers. ./deploy.sh tls issue obtains a Let's Encrypt certificate and"
    warn "  switches it on. What that does and does not buy is at the top of"
    warn "  lib/tls.sh -- in short, it is what MTA-STS enforcement and mail-client"
    warn "  submission require, not what ordinary server-to-server delivery needs."
  fi

  doctor_config_defaults
  return 0
}

# The schema defaults every dns.* key to a name under postal.example.com. They
# resolve to nothing, so mail signed for them cannot be verified and cannot be
# delivered, and no error is raised anywhere.
doctor_config_defaults() {
  # mx_records is an array, so this depends on json_get reading arrays: with the
  # scalar-only form it came back empty, and an empty value never matches
  # *example.com*, so the one dns.* key with two defaults was the one key this
  # check could not see.
  local keys=(smtp_hostname return_path_domain route_domain track_domain
              spf_include helo_hostname mx_records)
  local k v leftover=""
  for k in "${keys[@]}"; do
    v="$(json_get "$DOCTOR_CFG" "$k")"
    if [[ $v == *example.com* ]]; then
      leftover="$leftover $k=$v"
    fi
  done

  if [[ -n ${leftover// /} ]]; then
    d_fail "still using schema defaults:${leftover}"
    fail "  Set these in .env and re-run ./deploy.sh init."
  else
    d_ok "no dns.* value is still an example.com default"
  fi
  return 0
}

doctor_database() {
  local line
  line="$(printf '%s\n' "$DOCTOR_OUT" | marker_line POSTAL_DOCTOR_DB)"
  if [[ -z $line ]]; then
    d_skip "database checks (no report)"
    return 0
  fi

  local err
  err="$(json_get "$line" error)"
  if [[ -n $err ]]; then
    d_fail "the database could not be queried: $err"
    fail "  $(json_get "$line" message)"
    return 0
  fi

  # The scoped user replacing root is a requirement of this deployment, not a
  # preference: with root the application can read every schema on the server,
  # including the grant tables.
  local user
  user="$(json_get "$line" current_user)"
  if [[ $user == root@* ]]; then
    d_fail "the application connects as $user"
    fail "  ./deploy.sh init renders the grant script; recreate the volume."
  else
    d_ok "the application connects as $user"
  fi

  if [[ $(json_get_raw "$line" mysql_schema_readable) == true ]]; then
    d_fail "$user can read mysql.user, so the grants are not scoped"
  else
    d_ok "$user cannot read the mysql schema"
  fi

  local schemas
  schemas="$(json_get "$line" visible_schemas)"
  if [[ $schemas == *mysql* || $schemas == *,sys* ]]; then
    d_warn "$user can see: $schemas"
  else
    d_ok "$user sees only: $schemas"
  fi

  local versions
  versions="$(json_get_raw "$line" schema_versions)"
  if [[ ${versions:-0} -eq 0 ]]; then
    d_fail "schema_migrations is empty -- run ./deploy.sh migrate"
  else
    d_ok "schema is loaded ($versions migrations recorded)"
  fi

  if [[ $(json_get_raw "$line" migrations_pending) == true ]]; then
    d_warn "migrations are pending -- run ./deploy.sh migrate"
  fi

  doctor_worker_role "$line"
  doctor_queue "$line"
  return 0
}

doctor_worker_role() {
  local line=$1
  local age worker
  age="$(json_get_raw "$line" tasks_age_seconds)"
  worker="$(json_get "$line" tasks_worker)"

  if [[ -z $age || $age == null ]]; then
    # Absent is different from stale and means something different: no worker has
    # ever acquired the role, so either none is running or it cannot reach this
    # database.
    d_fail "no worker holds the tasks role, so no scheduled task runs"
    fail "  Retention, queue sizing and suppression are all driven from it."
    return 0
  fi

  # Renewed every 60 seconds and stolen after five minutes
  # (WorkerRole.acquire, app/models/worker_role.rb).
  if (( age < 300 )); then
    d_ok "worker '$worker' holds the tasks role (renewed ${age}s ago)"
  else
    d_fail "the tasks role is held by '$worker' but is ${age}s old"
    fail "  The worker that held it is gone. Scheduled tasks are not running."
  fi
  return 0
}

doctor_queue() {
  local line=$1
  local queued locked
  queued="$(json_get_raw "$line" queued_messages)"
  locked="$(json_get_raw "$line" queued_locked)"

  if [[ ${queued:-0} -eq 0 ]]; then
    d_ok "the message queue is empty"
    return 0
  fi

  # A non-empty queue is not on its own a fault -- mail arrives faster than it
  # leaves all the time -- so it is reported with the two numbers that distinguish
  # a backlog being worked on from one being ignored.
  if [[ ${locked:-0} -gt 0 ]]; then
    d_warn "$queued message(s) queued, $locked being delivered now"
  else
    d_warn "$queued message(s) queued and none in flight"
    warn "  If this does not fall, delivery is failing: ./deploy.sh logs worker"
  fi
  return 0
}

doctor_dns() {
  local lines
  lines="$(printf '%s\n' "$DOCTOR_OUT" | marker_lines POSTAL_DOCTOR_DNS)"
  if [[ -z ${lines// /} ]]; then
    d_skip "DNS checks (nothing reported)"
    return 0
  fi

  info "resolved from inside the container, so this is what the internet sees"

  local line
  while read -r line; do
    [[ -n $line ]] || continue
    doctor_dns_one "$line"
  done <<<"$lines"
  return 0
}

doctor_dns_one() {
  local line=$1
  local check name result expected actual
  check="$(json_get "$line" check)"
  name="$(json_get "$line" name)"
  result="$(json_get_raw "$line" ok)"
  expected="$(json_get "$line" expected)"
  actual="$(json_get "$line" actual)"

  case $result in
    true)  d_ok "$check $name" ;;
    null)  d_skip "$check $name -- $(json_get "$line" error)" ;;
    false)
      # Deliverability and verifiability are failures: nothing in Postal reports
      # them, and the symptom is a recipient's server refusing the mail. The rest
      # are warnings because they only matter if the feature is in use.
      case $check in
        ptr|dkim|spf|a) d_fail "$check $name: expected '$expected', resolved '$actual'" ;;
        *)              d_warn "$check $name: expected '$expected', resolved '$actual'" ;;
      esac
      ;;
    *)     d_warn "$check $name: unparseable result '$result'" ;;
  esac
  return 0
}

doctor_ip_addresses() {
  local lines
  lines="$(printf '%s\n' "$DOCTOR_OUT" | marker_lines POSTAL_DOCTOR_IP)"
  if [[ -z ${lines// /} ]]; then
    if [[ $(json_get_raw "$DOCTOR_CFG" use_ip_pools) == true ]]; then
      d_fail "use_ip_pools is true but no IP address is registered"
      fail "  ./deploy.sh ip"
    else
      d_skip "IP addresses (use_ip_pools is false, so none are needed)"
    fi
    return 0
  fi

  local host_addrs=""
  if command -v ip >/dev/null 2>&1; then
    host_addrs="$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"
  fi

  local line
  while read -r line; do
    [[ -n $line ]] || continue
    doctor_ip_one "$line" "$host_addrs"
  done <<<"$lines"
  return 0
}

doctor_ip_one() {
  local line=$1 host_addrs=$2
  local v4 host matches pool
  v4="$(json_get "$line" ipv4)"
  host="$(json_get "$line" hostname)"
  matches="$(json_get_raw "$line" ptr_matches)"
  pool="$(json_get "$line" pool)"

  if [[ -z $v4 ]]; then
    d_warn "an IP address could not be read: $(json_get "$line" message)"
    return 0
  fi

  d_ok "registered $v4 as $host${pool:+ in pool '$pool'}"

  if [[ $matches == false ]]; then
    d_fail "$v4 resolves to '$(json_get "$line" ptr)' but is registered as $host"
    fail "  IPAddress.hostname becomes the HELO string, so these must match."
  fi

  # Asked of the host, not of the container: the worker binds the source address
  # (SMTPClient::Endpoint sets Net::SMTP#source_address), and under host
  # networking that bind only succeeds if the address is genuinely on an
  # interface here. The failure is EADDRNOTAVAIL on every message.
  if [[ -z ${host_addrs// /} ]]; then
    d_skip "$v4 on a host interface ('ip' is not available)"
  elif [[ $host_addrs == *" $v4 "* || $host_addrs == "$v4 "* ]]; then
    d_ok "$v4 is on an interface of this host"
  else
    if [[ $(json_get_raw "$DOCTOR_CFG" use_ip_pools) == true ]]; then
      d_fail "$v4 is not on any interface of this host, so binding it will fail"
    else
      d_warn "$v4 is not on any interface of this host"
      warn "  Harmless while use_ip_pools is false, since nothing binds it."
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------

doctor_summary() {
  step "Summary"
  log "  ${C_GREEN}${DOCTOR_PASS} passed${C_RESET}, ${C_YELLOW}${DOCTOR_WARN} warned${C_RESET}, ${C_RED}${DOCTOR_FAIL} failed${C_RESET}, ${DOCTOR_SKIP} skipped"

  if (( DOCTOR_FAIL > 0 )); then
    log ""
    log "  The failures above are all fixable from here. Re-run ./deploy.sh doctor"
    log "  after each change; it is read-only and safe to repeat."
    return 1
  fi

  if (( DOCTOR_WARN > 0 )); then
    log ""
    log "  Nothing failed. The warnings are decisions to make, not defects."
  fi
  return 0
}

doctor_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh doctor [--quick]

Checks the deployment by observing it, not by reading its configuration back:

  files      the signing key and its ownership, config/postal.yml and its
             `version: 2`, .env permissions, trusted_proxies against the
             compose subnet
  containers every expected service running and healthy, and only one worker
             variant
  https      GET /api/v2/spec through the tunnel, and the same request against
             the origin from inside, which separates a tunnel fault from an
             application one. A 403 is HostAuthorization, never permissions.
  api        /api/v2/me is refused without a key and accepted with the saved one
  smtp       port 25 greets with 220 and announces postal.smtp_hostname
  tls        the installed certificate: readable by uid 999, the intermediate
             present, the key matching, not self-signed, not expiring, covering
             every name the MX records point at -- and then a real STARTTLS
             handshake against port 25, validated with this host's trust store.
             Skipped when SMTP_SERVER_TLS_ENABLED is not true.
  config     what the application actually resolved, including whether it is
             still an example.com default
  database   the connecting user is not root and cannot read other schemas, the
             schema is loaded, a worker holds the tasks role, the queue depth
  dns        PTR, SPF, DKIM, the MX A records and the tracking CNAME, resolved
             from inside the container
  addresses  each registered IP is on an interface of this host and its hostname
             is that address's PTR

  --quick   Skip the four groups which run a bootstrap container: config,
            database, dns and addresses. Everything else still runs, including
            the `docker exec` probe of the origin and of the smtp container, so
            this needs a working docker and a stack which is up -- it just starts
            nothing itself.

Exits non-zero if any check failed.
USAGE
}
