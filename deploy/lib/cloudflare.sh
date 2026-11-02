#!/usr/bin/env bash
# ./deploy.sh cloudflare -- provision the Cloudflare DNS records and the tunnel
# for this installation, via the Cloudflare API.
#
# This automates the steps the runbook otherwise does by hand:
#   - the installation-wide DNS records that `./deploy.sh dns` prints (A for
#     the MX names, SPF, return-path MX + DKIM, route MX, tracking CNAME);
#   - a tunnel, its connector token (written to CLOUDFLARE_TUNNEL_TOKEN) and
#     the CNAME + ingress route that make POSTAL_WEB_HOSTNAME reach the origin.
#
# It does not create the PTR record (that lives at the hosting provider, not in
# Cloudflare) and it does not touch per-domain records, which depend on data
# from the management API once the stack is up and domains exist.
#
# Idempotent: existing records and tunnels are matched and updated, never
# duplicated, and nothing is deleted. `--dry-run` prints the intended API calls
# without making them.

# The Cloudflare API token, in .env:
#   CLOUDFLARE_API_TOKEN   needs Zone:DNS:Edit, Zone:Zone:Read and
#                          Account:CFD_TUNNEL:Edit on the zone/account.
# Optionally pin the zone and account:
#   CLOUDFLARE_ZONE_ID     defaults to a lookup from POSTAL_WEB_HOSTNAME.
#   CLOUDFLARE_ACCOUNT_ID  defaults to the zone's owning account.

CF_API_BASE="https://api.cloudflare.com/client/v4"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

cf_cmd() {
  local sub="${1:-provision}"
  shift || true
  local dry=false
  local -a rest=()

  while (($#)); do
    case $1 in
      --dry-run) dry=true; shift ;;
      -h|--help) cf_usage; return 0 ;;
      *) rest+=("$1"); shift ;;
    esac
  done

  case $sub in
    provision|dns|tunnel|status|zone|keys) ;;
    *) die "cloudflare: unknown subcommand '$sub'" ;;
  esac

  require_cmd curl
  load_env

  # `keys` only needs the token itself, not the install hostnames.
  if [[ $sub == keys ]]; then
    need_env CLOUDFLARE_API_TOKEN
    cf_keys_cmd "$dry" "${rest[@]}"
    return 0
  fi

  need_env CLOUDFLARE_API_TOKEN POSTAL_WEB_HOSTNAME POSTAL_SMTP_HOSTNAME \
           DNS_MX_RECORDS DNS_SPF_INCLUDE DNS_RETURN_PATH_DOMAIN \
           DNS_ROUTE_DOMAIN DNS_TRACK_DOMAIN DNS_HELO_HOSTNAME

  case $sub in
    provision) cf_provision "$dry" ;;
    dns)      cf_dns_apply "$dry" ;;
    tunnel)    cf_tunnel_apply "$dry" ;;
    status)    cf_status ;;
    zone)      cf_zone_cmd "$dry" "${rest[@]}" ;;
  esac
}

# One Cloudflare API call. Leaves the response body in CF_BODY and the HTTP
# status in CF_HTTP. Never fails on a non-2xx; callers inspect CF_HTTP.
cf_call() {
  local method=$1 path=$2 data=${3:-}
  local out
  out="$(curl -sS -o /dev/null -w '%{http_code}' \
        -X "$method" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        ${data:+-d "$data"} \
        "${CF_API_BASE}${path}")" || true
  local body
  body="$(curl -sS \
        -X "$method" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        ${data:+-d "$data"} \
        "${CF_API_BASE}${path}")" || true
  CF_HTTP=$out
  CF_BODY=$body
}

# Die with the Cloudflare error messages when the API did not succeed.
cf_require_success() {
  local what=$1 http=$2 body=$3
  [[ $http == 2* ]] || {
    local msg
    msg="$(printf '%s' "$body" | { grep -o '"message":"[^"]*"' || true; } | head -n1 | sed 's/"message":"//; s/"$//')"
    die "cloudflare: $what -> HTTP $http ${msg:+($msg)}"
  }
}

# Minimal URL encoding (hostnames and names carry only safe characters).
cf_urlencode() {
  local s=$1
  s=${s//%/ %25}
  s=${s// /%20}
  printf '%s' "$s"
}

# Resolve the zone id for a hostname by trying progressively wider suffixes.
# Sets CF_ZONE_ID and CF_ZONE_NAME. Empty on failure.
cf_zone_id() {
  local host=$1 name=$1
  while [[ -n $name ]]; do
    cf_call GET "/zones?name=$(cf_urlencode "$name")&per_page=5"
    # A non-2xx or an error envelope is a real failure (permissions, IP
    # restriction, invalid token) -- not "no zone". Surface it rather than
    # walking up the domain and reporting a misleading "not found".
    if [[ $CF_HTTP != 2* ]] || ! printf '%s' "$CF_BODY" | grep -q '"success":true'; then
      local msg
      msg="$(printf '%s' "$CF_BODY" | { grep -o '"message":"[^"]*"' || true; } | head -n1 | sed 's/"message":"//; s/"$//')"
      die "cloudflare: zone lookup for '$host' failed (HTTP $CF_HTTP) ${msg:+($msg)}; check CLOUDFLARE_API_TOKEN scopes and IP restrictions"
    fi
    local id
    id="$(printf '%s' "$CF_BODY" | sed -n 's/.*"result":\[{"id":"\([^"]*\)".*/\1/p')"
    if [[ -n $id ]]; then
      CF_ZONE_ID=$id
      CF_ZONE_NAME=$name
      return 0
    fi
    name="${name#*.}"
    [[ $name == *.* ]] || break
  done
  CF_ZONE_ID=""
  return 1
}

# The owning account of the zone, derived from the zone object when not pinned.
cf_account_id() {
  if [[ -n ${CLOUDFLARE_ACCOUNT_ID:-} ]]; then
    CF_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID
    return 0
  fi
  # Derive the account from the token's own account list, so that creating a
  # zone does not depend on an existing zone. With more than one account the
  # first is used; pin CLOUDFLARE_ACCOUNT_ID to be explicit.
  cf_call GET /accounts
  if [[ $CF_HTTP == 2* ]] && printf '%s' "$CF_BODY" | grep -q '"success":true'; then
    CF_ACCOUNT_ID="$(printf '%s' "$CF_BODY" | sed -n 's/.*"result":\[{"id":"\([^"]*\)".*/\1/p')"
  fi
  [[ -n ${CF_ACCOUNT_ID:-} ]] || die "could not determine the Cloudflare account id; set CLOUDFLARE_ACCOUNT_ID in .env"
}

# List DNS records for a type+name. One line per record:
#   id<TAB>type<TAB>name<TAB>content<TAB>proxied
cf_list_records() {
  local zone=${CLOUDFLARE_ZONE_ID:-$CF_ZONE_ID}
  local type=$1 name=$2
  cf_call GET "/zones/${zone}/dns_records?type=${type}&name=$(cf_urlencode "$name")&per_page=50"
  [[ $CF_HTTP == 2* ]] || return 0
  printf '%s' "$CF_BODY" |
    sed 's/},{/}\n{/g' |
    { grep -o '{[^{}]*"id":"[^"]*"[^{}]*}' || true; } |
    while read -r r; do
      local id rtype rname content proxied
      id="$(printf '%s' "$r" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
      rtype="$(printf '%s' "$r" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')"
      rname="$(printf '%s' "$r" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
      content="$(printf '%s' "$r" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')"
      proxied="$(printf '%s' "$r" | sed -n 's/.*"proxied":\(true\|false\).*/\1/p')"
      [[ -n $id ]] || continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$rtype" "$rname" "$content" "$proxied"
    done
}

# Create or update one DNS record. Returns 0 on create/update, 1 on dry-run.
cf_upsert_record() {
  local dry=$1 type=$2 name=$3 content=$4 proxied=$5
  local zone=${CLOUDFLARE_ZONE_ID:-$CF_ZONE_ID}

  if [[ $dry == true ]]; then
    log "  [dry-run] dns_records: $type $name -> $content"
    return 0
  fi

  local existing
  existing="$(cf_list_records "$type" "$name")"

  local data
  data="{\"type\":\"${type}\",\"name\":\"${name}\",\"content\":\"${content}\",\"proxied\":${proxied},\"ttl\":1}"

  if [[ -z $existing ]]; then
    cf_call POST "/zones/${zone}/dns_records" "$data"
    cf_require_success "create $type $name" "$CF_HTTP" "$CF_BODY"
    ok "dns_records: created $type $name"
  else
    local id cur cur_content
    id="$(printf '%s' "$existing" | head -n1 | cut -f1)"
    cur_content="$(printf '%s' "$existing" | head -n1 | cut -f4)"
    if [[ "$cur_content" != "$content" ]]; then
      cf_call PUT "/zones/${zone}/dns_records/${id}" "$data"
      cf_require_success "update $type $name" "$CF_HTTP" "$CF_BODY"
      ok "dns_records: updated $type $name"
    else
      ok "dns_records: $type $name unchanged"
    fi
  fi
}

# ---------------------------------------------------------------------------
# The records `deploy.sh dns` prints, as machine-readable rows.
# One line per record: type<TAB>name<TAB>content<TAB>proxied
# ---------------------------------------------------------------------------

cf_dns_desired() {
  local mx ip dkim_id
  ip="${POSTAL_PUBLIC_IP:-}"
  dkim_id="${DNS_DKIM_IDENTIFIER:-postal}"

  local -a mxes=()
  IFS=',' read -ra mxes <<<"$DNS_MX_RECORDS"
  local m
  for m in "${mxes[@]}"; do
    m="${m// /}"
    [[ -n $m ]] || continue
    if [[ -n $ip ]]; then
      printf 'A\t%s\t%s\tfalse\n' "$m" "$ip"
    else
      warn "POSTAL_PUBLIC_IP is empty, so the A records for the MX names cannot"
      warn "be provisioned. Set it in .env and re-run."
    fi
  done

  printf 'TXT\t%s\tv=spf1 mx a:%s ~all\tfalse\n' "$DNS_SPF_INCLUDE" "$POSTAL_SMTP_HOSTNAME"
  printf 'MX\t%s\t10 %s\tfalse\n' "$DNS_RETURN_PATH_DOMAIN" "$POSTAL_SMTP_HOSTNAME"
  printf 'MX\t%s\t10 %s\tfalse\n' "$DNS_ROUTE_DOMAIN" "$POSTAL_SMTP_HOSTNAME"
  printf 'CNAME\t%s\t%s.\ttrue\n' "$DNS_TRACK_DOMAIN" "$POSTAL_WEB_HOSTNAME"

  local rp_dkim
  rp_dkim="$(dns_rp_dkim_record)"
  if [[ -n $rp_dkim ]]; then
    printf 'TXT\t%s._domainkey.%s\t%s\tfalse\n' "$dkim_id" "$DNS_RETURN_PATH_DOMAIN" "$rp_dkim"
  else
    warn "return-path DKIM record unavailable (run init, then build), so it was"
    warn "not provisioned. Publish it from ./deploy.sh dns later."
  fi
}

cf_dns_apply() {
  local dry=$1
  step "Cloudflare DNS records"
  cf_zone_ready
  local type name content proxied
  while IFS=$'\t' read -r type name content proxied; do
    [[ -n $type ]] || continue
    cf_upsert_record "$dry" "$type" "$name" "$content" "$proxied"
  done <<<"$(cf_dns_desired)"
  log ""
  log "  The PTR record for ${POSTAL_PUBLIC_IP:-<public IPv4>} is not a Cloudflare"
  log "  record: set it at the hosting provider to ${DNS_HELO_HOSTNAME}."
}

# ---------------------------------------------------------------------------
# Tunnel
# ---------------------------------------------------------------------------

cf_zone_ready() {
  if [[ -n ${CLOUDFLARE_ZONE_ID:-} ]]; then
    CF_ZONE_ID=$CLOUDFLARE_ZONE_ID
  fi
  if [[ -z ${CF_ZONE_ID:-} ]]; then
    cf_zone_id "$POSTAL_WEB_HOSTNAME" || die "could not find a Cloudflare zone for $POSTAL_WEB_HOSTNAME"
    ok "resolved zone $CF_ZONE_NAME ($CF_ZONE_ID)"
  fi
  cf_account_id
  [[ -n ${CF_ACCOUNT_ID:-} ]] || die "could not determine the Cloudflare account id"
}

cf_tunnel_find() {
  local name=${CLOUDFLARE_TUNNEL_NAME:-postal}
  cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=$(cf_urlencode "$name")&per_page=50"
  [[ $CF_HTTP == 2* ]] || return 1
  CF_TUNNEL_ID="$(printf '%s' "$CF_BODY" |
    sed 's/},{/}\n{/g' |
    { grep -o '{[^{}]*"name":"'"$name"'"[^{}]*}' || true; } |
    head -n1 |
    sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
  [[ -n ${CF_TUNNEL_ID:-} ]]
}

cf_tunnel_ensure() {
  local dry=$1 name=${CLOUDFLARE_TUNNEL_NAME:-postal}

  if cf_tunnel_find; then
    ok "tunnel '$name' exists ($CF_TUNNEL_ID)"
    return 0
  fi

  if [[ $dry == true ]]; then
    log "  [dry-run] create tunnel '$name'"
    CF_TUNNEL_ID="dry-run"
    return 0
  fi

  cf_call POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" "{\"name\":\"${name}\"}"
  cf_require_success "create tunnel '$name'" "$CF_HTTP" "$CF_BODY"
  CF_TUNNEL_ID="$(printf '%s' "$CF_BODY" | sed -n 's/.*"result":{"id":"\([^"]*\)".*/\1/p')"
  [[ -n ${CF_TUNNEL_ID:-} ]] || die "tunnel created but no id in the response"
  ok "created tunnel '$name' ($CF_TUNNEL_ID)"
}

cf_tunnel_token() {
  local dry=$1
  if [[ $dry == true ]]; then
    log "  [dry-run] set CLOUDFLARE_TUNNEL_TOKEN from the tunnel's token endpoint"
    return 0
  fi
  cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/token"
  cf_require_success "tunnel token" "$CF_HTTP" "$CF_BODY"
  local token
  token="$(printf '%s' "$CF_BODY" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')"
  [[ -n $token ]] || die "tunnel token endpoint returned no token"
  # The connector token is never the API token. Writing the API token here is
  # the exact misconfiguration that makes cloudflared restart-loop with
  # "Provided Tunnel token is not valid", so refuse it outright.
  if [[ $token == "$CLOUDFLARE_API_TOKEN" ]]; then
    die "the tunnel token endpoint returned the API token itself, which is never a valid connector token. Refusing to write it."
  fi
  if [[ "$(env_get CLOUDFLARE_TUNNEL_TOKEN)" != "$token" ]]; then
    env_set CLOUDFLARE_TUNNEL_TOKEN "$token"
    ok "wrote CLOUDFLARE_TUNNEL_TOKEN to .env"
  else
    ok "CLOUDFLARE_TUNNEL_TOKEN unchanged"
  fi
}

cf_tunnel_web_cname() {
  local dry=$1
  cf_upsert_record "$dry" CNAME "$POSTAL_WEB_HOSTNAME" "${CF_TUNNEL_ID}.cfargotunnel.com" true
}

cf_tunnel_ingress() {
  local dry=$1
  local data
  data="{\"config\":{\"ingress\":[{\"hostname\":\"${POSTAL_WEB_HOSTNAME}\",\"service\":\"http://postal:5000\",\"originRequest\":{\"connectTimeout\":\"30s\",\"noTLSVerify\":true,\"http2Origin\":false}},{\"service\":\"http_status:404\"}]}}"
  if [[ $dry == true ]]; then
    log "  [dry-run] set tunnel ingress for $POSTAL_WEB_HOSTNAME -> http://postal:5000"
    return 0
  fi
  cf_call PUT "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" "$data"
  cf_require_success "tunnel ingress" "$CF_HTTP" "$CF_BODY"
  ok "tunnel ingress: $POSTAL_WEB_HOSTNAME -> http://postal:5000"
}

cf_tunnel_apply() {
  local dry=$1
  step "Cloudflare tunnel"
  cf_zone_ready
  local cur
  cur="$(env_get CLOUDFLARE_TUNNEL_TOKEN)"
  if [[ -n $cur && $cur == "$CLOUDFLARE_API_TOKEN" ]]; then
    warn "CLOUDFLARE_TUNNEL_TOKEN is set to the API token, which is invalid."
    warn "It will be replaced by the tunnel's real connector token."
  fi
  cf_tunnel_ensure "$dry"
  cf_tunnel_token "$dry"
  cf_tunnel_web_cname "$dry"
  cf_tunnel_ingress "$dry"
}

cf_provision() {
  local dry=$1
  cf_dns_apply "$dry"
  cf_tunnel_apply "$dry"
  log ""
  log "  Next: ./deploy.sh build && ./deploy.sh migrate && ./deploy.sh up"
  log "  Then: ./deploy.sh admin && ./deploy.sh doctor"
}

# ---------------------------------------------------------------------------
# Read-only status
# ---------------------------------------------------------------------------

cf_status() {
  step "Cloudflare status"
  cf_zone_ready
  echo "  zone:      ${CF_ZONE_NAME:-${CLOUDFLARE_ZONE_ID:-?}} ($CF_ZONE_ID)"
  echo "  account:   $CF_ACCOUNT_ID"
  if cf_tunnel_find; then
    echo "  tunnel:    $CLOUDFLARE_TUNNEL_NAME ($CF_TUNNEL_ID)"
    local existing
    existing="$(cf_list_records CNAME "$POSTAL_WEB_HOSTNAME")"
    if [[ -n $existing ]]; then
      echo "  web CNAME: $(printf '%s' "$existing" | head -n1 | cut -f4)"
    else
      echo "  web CNAME: none"
    fi
  else
    echo "  tunnel:    none (run ./deploy.sh cloudflare provision)"
  fi
}

# ---------------------------------------------------------------------------
# Client domain onboarding: add a zone and confirm activation
# ---------------------------------------------------------------------------

cf_zone_cmd() {
  local dry=$1; shift
  local op="${1:-}"; shift || true
  case $op in
    add)    cf_zone_add "$dry" "$@" ;;
    status) cf_zone_status "$@" ;;
    *) die "cloudflare zone: expected 'add <domain>' or 'status <domain>'" ;;
  esac
}

cf_zone_add() {
  local dry=$1 domain=$2
  [[ -n $domain ]] || die "cloudflare zone add: missing domain argument"
  cf_account_id

  step "Adding zone $domain"
  cf_call GET "/zones?name=$(cf_urlencode "$domain")&per_page=5"
  if [[ $CF_HTTP == 2* ]] && printf '%s' "$CF_BODY" | grep -q '"success":true'; then
    local already
    already="$(printf '%s' "$CF_BODY" | sed -n 's/.*"result":\[{"id":"\([^"]*\)".*/\1/p')"
    if [[ -n $already ]]; then
      warn "zone '$domain' already exists ($already)."
      CF_ZONE_ID=$already
      CF_ZONE_NAME=$domain
      cf_zone_wait_active "$dry"
      return 0
    fi
  fi

  if [[ $dry == true ]]; then
    log "  [dry-run] POST /zones {\"name\":\"$domain\",\"type\":\"full\"}"
    log "  [dry-run] would print the assigned nameservers and wait for activation."
    return 0
  fi

  cf_call POST /zones "{\"name\":\"${domain}\",\"type\":\"full\",\"account\":{\"id\":\"${CF_ACCOUNT_ID}\"}}"
  cf_require_success "create zone '$domain'" "$CF_HTTP" "$CF_BODY"
  CF_ZONE_ID="$(printf '%s' "$CF_BODY" | sed -n 's/.*"result":{"id":"\([^"]*\)".*/\1/p')"
  [[ -n ${CF_ZONE_ID:-} ]] || die "zone created but no id in the response"
  CF_ZONE_NAME=$domain
  ok "created zone '$domain' ($CF_ZONE_ID)"

  echo ""
  echo "  Point the domain's nameservers at Cloudflare:"
  cf_zone_print_ns "$CF_BODY"
  echo ""
  cf_zone_wait_active "$dry"
}

cf_zone_print_ns() {
  local body=$1 ns
  ns="$(printf '%s' "$body" | sed -n 's/.*"name_servers":\[\([^]]*\)\].*/\1/p')"
  if [[ -n $ns ]]; then
    printf '%s\n' "$ns" | tr ',' '\n' | sed 's/^ *//; s/"//g; s/^/    /'
  else
    echo "    (name servers not present in the response; copy them from the dashboard)"
  fi
}

cf_zone_wait_active() {
  local dry=$1
  if [[ $dry == true ]]; then
    log "  [dry-run] skip waiting for activation"
    return 0
  fi
  local status="" tries=0
  until [[ $status == active ]]; do
    cf_call GET "/zones/${CF_ZONE_ID}"
    [[ $CF_HTTP == 2* ]] || break
    status="$(printf '%s' "$CF_BODY" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
    [[ -n $status ]] || status="(unknown)"
    if [[ $status != active ]]; then
      tries=$((tries+1))
      if (( tries > 60 )); then
        warn "zone '$CF_ZONE_NAME' is still not active after ~10 minutes."
        warn "Confirm the nameservers were updated at the registrar."
        return 1
      fi
      printf '  waiting for nameserver verification: %s (attempt %s/60)\r' "$status" "$tries"
      sleep 10
    fi
  done
  printf '\n'
  if [[ $status == active ]]; then
    ok "zone '$CF_ZONE_NAME' is active: nameservers verified."
    log "  You can now publish DNS records in this zone."
  fi
}

cf_zone_status() {
  local domain=$1
  [[ -n $domain ]] || die "cloudflare zone status: missing domain argument"
  cf_call GET "/zones?name=$(cf_urlencode "$domain")&per_page=5"
  [[ $CF_HTTP == 2* ]] || die "could not look up zone '$domain' (HTTP $CF_HTTP)"
  local id status ns
  id="$(printf '%s' "$CF_BODY" | sed -n 's/.*"result":\[{"id":"\([^"]*\)".*/\1/p')"
  if [[ -z $id ]]; then
    echo "  zone '$domain': not found in this account"
    return 0
  fi
  status="$(printf '%s' "$CF_BODY" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
  echo "  zone: $domain ($id)"
  echo "  status: ${status:-?}"
  ns="$(printf '%s' "$CF_BODY" | sed -n 's/.*"name_servers":\[\([^]]*\)\].*/\1/p')"
  if [[ -n $ns ]]; then
    echo "  nameservers:"
    printf '%s\n' "$ns" | tr ',' '\n' | sed 's/^ *//; s/"//g; s/^/    /'
  fi
}

# Copy the unified API token into the other Cloudflare key field
# (CLOUDFLARE_DNS_API_TOKEN) so one token can drive everything. The unified
# token carries Zone:DNS:Edit, which is all the DNS field is used for.
cf_keys_cmd() {
  local dry=$1 force=false; shift
  while (($#)); do
    case $1 in
      --force) force=true; shift ;;
      -h|--help) cf_usage; return 0 ;;
      *) die "cloudflare keys: unknown option '$1'" ;;
    esac
  done

  local current
  current="$(env_get CLOUDFLARE_DNS_API_TOKEN)"
  if [[ -n $current && $force != true ]]; then
    ok "CLOUDFLARE_DNS_API_TOKEN is already set; use --force to overwrite it"
    return 0
  fi
  if [[ $dry == true ]]; then
    log "  [dry-run] would set CLOUDFLARE_DNS_API_TOKEN = CLOUDFLARE_API_TOKEN"
    return 0
  fi
  env_set CLOUDFLARE_DNS_API_TOKEN "$CLOUDFLARE_API_TOKEN"
  ok "CLOUDFLARE_DNS_API_TOKEN copied from CLOUDFLARE_API_TOKEN"
}

cf_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh cloudflare [provision|dns|tunnel|status|zone|keys ...] [--dry-run]

Provision Cloudflare for this installation via the API.

  provision   DNS records + tunnel + web hostname route (default).
  dns        Only the installation-wide DNS records.
  tunnel      Only the tunnel, its token and the web hostname route.
  status      Read-only summary of the zone, tunnel and web CNAME.
  zone add <domain>
              Add a client domain as a zone, print its nameservers, and wait
              for activation (NS verification).
  zone status <domain>
              Show a zone's status and nameservers.
  keys [--force]
              Copy CLOUDFLARE_API_TOKEN into CLOUDFLARE_DNS_API_TOKEN so one
              token drives provisioning and TLS issuance. No-op if it is already
              set unless --force is given.
  --dry-run   Print what would be done without calling the API.

Requires in .env: CLOUDFLARE_API_TOKEN. For the installation commands it needs
Zone:DNS:Edit, Zone:Zone:Read and Account:CFD_TUNNEL:Edit. Adding client zones
additionally needs Account:Zone:Edit and Zone resources over All zones (or at
least the client zones), plus CLOUDFLARE_ACCOUNT_ID when the token sees more
than one account. CLOUDFLARE_ZONE_ID is an optional override for the install
zone. The PTR record still has to be set at the hosting provider.

Idempotent: matches and updates existing records and tunnels. Deletes nothing.
USAGE
}
