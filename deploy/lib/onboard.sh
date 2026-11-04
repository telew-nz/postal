#!/usr/bin/env bash
# ./deploy.sh onboard -- automate client onboarding end to end.
#
# Runs the whole flow for a client domain:
#   1. resolve (or create) the organization
#   2. ensure the mail server exists (or create it)
#   3. create the domain under the server
#   4. publish + verify the domain's DNS records in Cloudflare
#   5. create an address endpoint (receive@<domain>) unless
#      POSTAL_DEFAULT_ROUTE_ENDPOINT points routes at a webhook
#   6. create a route (a wildcard webhook route, or to the address endpoint)
#   7. create an API credential and capture its key
#   8. optionally send an outbound test message and an inbound loopback
#   9. print a summary, including the API credential key
#
# Idempotent: existing pieces are reused, nothing is duplicated.

onboard_cmd() {
  local domain="" org="" srv_name="" test_to="" no_test=false

  while (($#)); do
    case $1 in
      --domain) domain=${2:?--domain needs a value}; shift 2 ;;
      --org) org=${2:?--org needs a value}; shift 2 ;;
      --server-name) srv_name=${2:?--server-name needs a value}; shift 2 ;;
      --test-to) test_to=${2:?--test-to needs an email}; shift 2 ;;
      --no-test) no_test=true; shift ;;
      -h|--help) onboard_usage; return 0 ;;
      *) die "onboard: unknown option '$1'" ;;
    esac
  done

  [[ -n $domain ]] || die "onboard: --domain is required"

  require_cmd curl
  load_env
  need_env POSTAL_API_TOKEN CLOUDFLARE_API_TOKEN POSTAL_WEB_HOSTNAME

  local apibase
  apibase="$(api_base_url)"
  local api="$apibase/api/v2"

  local step_no=0
  step() {
    step_no=$((step_no+1))
    echo
    echo "==> $step_no. $*"
  }

  # --- 1. organization ---
  step "Resolving organization"
  local org_permalink="$org"
  if [[ -z $org_permalink ]]; then
    api_request GET /api/v2/organizations
    org_permalink="$(printf '%s' "$API_BODY" | grep -o '"permalink":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  fi
  if [[ -z $org_permalink ]]; then
    # none exist yet -> create one
    [[ -n $org ]] || die "onboard: no organization exists and --org was not given"
    api_request POST /api/v2/organizations "{\"name\":\"$org\"}"
    [[ $API_STATUS == 201 || $API_STATUS == 200 ]] || die "create org -> $API_STATUS ($API_BODY)"
    org_permalink="$(printf '%s' "$API_BODY" | grep -o '"permalink":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  fi
  ok "organization permalink: $org_permalink"

  # --- 2. mail server ---
  step "Ensuring mail server"
  [[ -n $srv_name ]] || srv_name="${domain/./-}-mail"
  api_request GET "/api/v2/organizations/$org_permalink/servers"
  local srv_permalink=""
  local line
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    local nm pk
    nm="$(printf '%s' "$line" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
    pk="$(printf '%s' "$line" | sed -n 's/.*"permalink":"\([^"]*\)".*/\1/p')"
    if [[ $nm == "$srv_name" ]]; then srv_permalink="$pk"; break; fi
  done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"permalink"[^{}]*}' || true)"
  if [[ -z $srv_permalink ]]; then
    api_request POST "/api/v2/organizations/$org_permalink/servers" "{\"name\":\"$srv_name\",\"mode\":\"Live\"}"
    [[ $API_STATUS == 201 || $API_STATUS == 200 ]] || die "create server -> $API_STATUS ($API_BODY)"
    srv_permalink="$(printf '%s' "$API_BODY" | grep -o '"permalink":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  fi
  ok "server permalink: $srv_permalink"

  # --- 3. domain under server ---
  step "Ensuring domain under server"
  local dom_uuid="" dom_id=""
  api_request GET "/api/v2/organizations/$org_permalink/servers/$srv_permalink/domains"
  local d
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    local du dn di
    du="$(printf '%s' "$d" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')"
    dn="$(printf '%s' "$d" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
    di="$(printf '%s' "$d" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')"
    if [[ -n $du && $dn == "$domain" ]]; then dom_uuid="$du"; dom_id="$di"; break; fi
  done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"uuid"[^{}]*}' || true)"
  if [[ -z $dom_uuid ]]; then
    api_request POST "/api/v2/organizations/$org_permalink/servers/$srv_permalink/domains" "{\"name\":\"$domain\"}"
    [[ $API_STATUS == 201 || $API_STATUS == 200 ]] || die "create domain -> $API_STATUS ($API_BODY)"
    dom_uuid="$(printf '%s' "$API_BODY" | grep -o '"uuid":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
    dom_id="$(printf '%s' "$API_BODY" | grep -o '"id":[0-9]*' | head -1 | sed 's/.*://')"
  fi
  ok "domain uuid: $dom_uuid (id $dom_id)"

  # --- 4. publish + verify DNS ---
  step "Publishing and verifying DNS records in Cloudflare"
  cf_zone_ready
  cf_domain_publish false "$domain" true "$org_permalink" "$srv_permalink"

  # --- 5. address endpoint ---
  step "Ensuring address endpoint"
  local addr="receive@$domain"
  local addr_uuid=""
  api_request GET "/api/v2/organizations/$org_permalink/servers/$srv_permalink/address_endpoints"
  local ae
  while IFS= read -r ae; do
    [[ -n $ae ]] || continue
    local au aa
    au="$(printf '%s' "$ae" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')"
    aa="$(printf '%s' "$ae" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p')"
    if [[ -n $au && $aa == "$addr" ]]; then addr_uuid="$au"; break; fi
  done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"uuid"[^{}]*}' || true)"
  if [[ -z $addr_uuid ]]; then
    api_request POST "/api/v2/organizations/$org_permalink/servers/$srv_permalink/address_endpoints" "{\"address\":\"$addr\"}"
    [[ $API_STATUS == 201 || $API_STATUS == 200 ]] || die "create address endpoint -> $API_STATUS ($API_BODY)"
    addr_uuid="$(printf '%s' "$API_BODY" | grep -o '"uuid":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  fi
  ok "address endpoint $addr ($addr_uuid)"

  # --- 6. route ---
  local route_uuid=""
  if [[ -n ${POSTAL_DEFAULT_ROUTE_ENDPOINT:-} ]]; then
    step "Ensuring default HTTP route to $POSTAL_DEFAULT_ROUTE_ENDPOINT"
    local inbound_url="${POSTAL_DEFAULT_HTTP_ENDPOINT:-${POSTAL_DEFAULT_ROUTE_ENDPOINT}}"
    onboard_ensure_http_endpoint "$org_permalink" "$srv_permalink" "inbound" "$inbound_url"
    local http_uuid="$ONBOARD_HTTP_UUID"
    ok "http endpoint $http_uuid ($inbound_url)"

    # A wildcard route (*) on this domain delivers every unmatched local part to
    # the default endpoint, making it the default route for all addresses on the
    # domain.
    api_request GET "/api/v2/organizations/$org_permalink/servers/$srv_permalink/routes"
    while IFS= read -r r; do
      [[ -n $r ]] || continue
      local rn ru
      rn="$(printf '%s' "$r" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
      ru="$(printf '%s' "$r" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')"
      if [[ $rn == "*" ]]; then route_uuid="$ru"; break; fi
    done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"uuid"[^{}]*}' || true)"
    if [[ -z $route_uuid ]]; then
      api_request POST "/api/v2/organizations/$org_permalink/servers/$srv_permalink/routes" \
        "{\"name\":\"*\",\"domain_id\":$dom_id,\"spam_mode\":\"Mark\",\"endpoint_type\":\"HTTPEndpoint\",\"endpoint_uuid\":\"$http_uuid\"}"
      [[ $API_STATUS == 201 || $API_STATUS == 200 ]] || die "create route -> $API_STATUS ($API_BODY)"
      route_uuid="$(printf '%s' "$API_BODY" | grep -o '"uuid":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
    fi
    ok "wildcard route $route_uuid"

    # Optional server-level webhook for lifecycle events.
    if [[ -n ${POSTAL_DEFAULT_WEBHOOK_ENDPOINT:-} ]]; then
      step "Ensuring webhook to $POSTAL_DEFAULT_WEBHOOK_ENDPOINT"
      local wh_uuid=""
      api_request GET "/api/v2/organizations/$org_permalink/servers/$srv_permalink/webhooks"
      local w
      while IFS= read -r w; do
        [[ -n $w ]] || continue
        local wu wurl
        wu="$(printf '%s' "$w" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')"
        wurl="$(printf '%s' "$w" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')"
        if [[ -n $wu && $wurl == "$POSTAL_DEFAULT_WEBHOOK_ENDPOINT" ]]; then wh_uuid="$wu"; break; fi
      done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"uuid"[^{}]*}' || true)"
      if [[ -z $wh_uuid ]]; then
        api_request POST "/api/v2/organizations/$org_permalink/servers/$srv_permalink/webhooks" \
          "{\"name\":\"events\",\"url\":\"$POSTAL_DEFAULT_WEBHOOK_ENDPOINT\",\"all_events\":true}"
        [[ $API_STATUS == 201 || $API_STATUS == 200 ]] || die "create webhook -> $API_STATUS ($API_BODY)"
        wh_uuid="$(printf '%s' "$API_BODY" | grep -o '"uuid":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
      fi
      ok "webhook $wh_uuid ($POSTAL_DEFAULT_WEBHOOK_ENDPOINT)"
    fi
  else
    step "Ensuring a route to the address endpoint"
    api_request GET "/api/v2/organizations/$org_permalink/servers/$srv_permalink/routes"
    while IFS= read -r r; do
      [[ -n $r ]] || continue
      local ru
      ru="$(printf '%s' "$r" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')"
      if [[ -n $ru ]]; then route_uuid="$ru"; break; fi
    done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"uuid"[^{}]*}' || true)"
    if [[ -z $route_uuid ]]; then
      api_request POST "/api/v2/organizations/$org_permalink/servers/$srv_permalink/routes" \
        "{\"name\":\"receive-$domain\",\"domain_id\":$dom_id,\"spam_mode\":\"Mark\",\"endpoint_type\":\"AddressEndpoint\",\"endpoint_uuid\":\"$addr_uuid\"}"
      [[ $API_STATUS == 201 || $API_STATUS == 200 ]] || die "create route -> $API_STATUS ($API_BODY)"
      route_uuid="$(printf '%s' "$API_BODY" | grep -o '"uuid":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
    fi
    ok "route $route_uuid"
  fi

  # --- 7. API credential ---
  step "Ensuring an API credential"
  local cred_uuid="" cred_key=""
  api_request GET "/api/v2/organizations/$org_permalink/servers/$srv_permalink/credentials"
  local c
  local first_uuid=""
  while IFS= read -r c; do
    [[ -n $c ]] || continue
    local cu ct
    cu="$(printf '%s' "$c" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')"
    ct="$(printf '%s' "$c" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')"
    [[ -n $cu ]] || continue
    [[ -z $first_uuid ]] && first_uuid="$cu"
    if [[ $ct == API ]]; then cred_uuid="$cu"; break; fi
  done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"uuid"[^{}]*}' || true)"
  [[ -n $cred_uuid ]] || cred_uuid="$first_uuid"
  if [[ -n $cred_uuid ]]; then
    # The list endpoint redacts keys, so fetch the key via show.
    api_request GET "/api/v2/organizations/$org_permalink/servers/$srv_permalink/credentials/$cred_uuid"
    [[ $API_STATUS == 200 ]] || die "fetch credential -> $API_STATUS ($API_BODY)"
    cred_key="$(printf '%s' "$API_BODY" | grep -o '"key":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  fi
  if [[ -z $cred_key ]]; then
    api_request POST "/api/v2/organizations/$org_permalink/servers/$srv_permalink/credentials" \
      "{\"type\":\"API\",\"name\":\"onboard-api\"}"
    [[ $API_STATUS == 201 || $API_STATUS == 200 ]] || die "create credential -> $API_STATUS ($API_BODY)"
    cred_uuid="$(printf '%s' "$API_BODY" | grep -o '"uuid":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
    cred_key="$(printf '%s' "$API_BODY" | grep -o '"key":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  fi
  ok "API credential $cred_uuid"

  # --- 8. tests ---
  if [[ $no_test != true ]]; then
    step "Sending test messages"
    if [[ -n $test_to ]]; then
      onboard_send "$cred_key" "$test_to" "hello@$domain" "Postal onboard test" "Onboard outbound test."
      if [[ $ONBOARD_SEND_OK == true ]]; then
        ok "outbound test sent to $test_to"
      else
        warn "outbound test not confirmed"
      fi
    else
      info "--test-to not given; skipping outbound external test"
    fi
    # inbound loopback
    onboard_send "$cred_key" "receive@$domain" "hello@$domain" "Postal onboard loopback" "Inbound loopback test."
    if [[ $ONBOARD_SEND_OK == true ]]; then
      ok "inbound loopback sent to receive@$domain"
    else
      warn "inbound loopback not confirmed"
    fi
  else
    info "--no-test; skipping test sends"
  fi

  # --- summary ---
  echo
  echo "================ onboard complete ================"
  echo "  domain:            $domain"
  echo "  organization:       $org_permalink"
  echo "  server:            $srv_permalink"
  echo "  domain uuid:       $dom_uuid"
  echo "  address endpoint:   $addr ($addr_uuid)"
  echo "  route uuid:        $route_uuid"
  echo "  API credential:    $cred_uuid"
  echo "  API KEY (store this): $cred_key"
  echo "  send via X-Server-API-Key: $cred_key"
  echo "===================================================="
}

# Ensure an HTTP endpoint with the given name/url exists on a server, creating
# it if absent. Prints nothing; sets ONBOARD_HTTP_UUID to the endpoint's uuid.
# Reused by URL so onboarding stays idempotent.
onboard_ensure_http_endpoint() {
  local org=$1 srv=$2 ep_name=$3 ep_url=$4
  local ep_uuid=""
  api_request GET "/api/v2/organizations/$org/servers/$srv/http_endpoints"
  local he
  while IFS= read -r he; do
    [[ -n $he ]] || continue
    local hu hurl
    hu="$(printf '%s' "$he" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')"
    hurl="$(printf '%s' "$he" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')"
    if [[ -n $hu && $hurl == "$ep_url" ]]; then ep_uuid="$hu"; break; fi
  done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"uuid"[^{}]*}' || true)"
  if [[ -z $ep_uuid ]]; then
    api_request POST "/api/v2/organizations/$org/servers/$srv/http_endpoints" \
      "{\"name\":\"$ep_name\",\"url\":\"$ep_url\",\"encoding\":\"BodyAsJSON\",\"format\":\"Hash\"}"
    [[ $API_STATUS == 201 || $API_STATUS == 200 ]] || die "create http endpoint '$ep_name' -> $API_STATUS ($API_BODY)"
    ep_uuid="$(printf '%s' "$API_BODY" | grep -o '"uuid":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  fi
  ONBOARD_HTTP_UUID="$ep_uuid"
}

# Send a message through the legacy API using a server API credential. The
# legacy send endpoint authenticates with X-Server-API-Key, not the user API
# token, so this is a dedicated caller.
onboard_send() {
  local key=$1 to=$2 from=$3 subject=$4 body=$5
  local out json
  json="{\"to\":[\"$to\"],\"from\":\"$from\",\"subject\":\"$subject\",\"plain_body\":\"$body\"}"
  out="$(curl -sS -w '\n%{http_code}' -X POST \
    -H "X-Server-API-Key: $key" \
    -H "Content-Type: application/json" \
    --data "$json" \
    "$(api_base_url)/api/v1/send/message" 2>/dev/null || true)"
  API_STATUS="$(normalize_http_code "$(printf '%s' "$out" | tail -n1)")"
  API_BODY="$(printf '%s' "$out" | sed '$d')"
  ONBOARD_SEND_OK=false
  if [[ $API_STATUS == 200 && $API_BODY == *'"status":"success"'* ]]; then
    ONBOARD_SEND_OK=true
  fi
}

# ./deploy.sh teardown -- cleanly remove a client domain and its DNS records.
#
# Removes, in order:
#   1. the domain's Cloudflare DNS records (from the per-domain dns_records
#      plus the verification TXT)
#   2. the domain from Postal
#   3. optionally the mail server (--server) and organization (--org)
#
# Requires the same scoping flags as `cloudflare domain` so the correct domain
# record is torn down.

teardown_cmd() {
  local domain="" org="" srv_name="" remove_server=false remove_org=false dry=false

  while (($#)); do
    case $1 in
      --domain) domain=${2:?--domain needs a value}; shift 2 ;;
      --org) org=${2:?--org needs a value}; shift 2 ;;
      --server-name) srv_name=${2:?--server-name needs a value}; shift 2 ;;
      --server) remove_server=true; shift ;;
      --remove-org) remove_org=true; shift ;;
      --dry-run) dry=true; shift ;;
      -h|--help) teardown_usage; return 0 ;;
      *) die "teardown: unknown option '$1'" ;;
    esac
  done

  [[ -n $domain ]] || die "teardown: --domain is required"

  require_cmd curl
  load_env
  need_env POSTAL_API_TOKEN CLOUDFLARE_API_TOKEN POSTAL_WEB_HOSTNAME

  local apibase api
  apibase="$(api_base_url)"
  api="$apibase/api/v2"

  step() { echo; echo "==> $*"; }

  # --- resolve scope ---
  step "Resolving organization"
  local org_permalink="$org"
  if [[ -z $org_permalink ]]; then
    api_request GET /api/v2/organizations
    org_permalink="$(printf '%s' "$API_BODY" | grep -o '"permalink":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  fi
  [[ -n $org_permalink ]] || die "teardown: could not resolve an organization"

  local srv_permalink="$srv_name"
  if [[ -n $srv_name ]]; then
    api_request GET "/api/v2/organizations/$org_permalink/servers"
    srv_permalink="$(printf '%s' "$API_BODY" | grep -o '"permalink":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  fi
  [[ -n $srv_permalink ]] || srv_permalink="$srv_name"

  # --- find domain ---
  step "Locating domain under server"
  local base_url
  if [[ -n $srv_permalink ]]; then
    base_url="/api/v2/organizations/$org_permalink/servers/$srv_permalink"
  else
    base_url="/api/v2/organizations/$org_permalink"
  fi
  local dom_uuid=""
  api_request GET "$base_url/domains"
  local d
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    local du dn
    du="$(printf '%s' "$d" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')"
    dn="$(printf '%s' "$d" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
    if [[ -n $du && $dn == "$domain" ]]; then dom_uuid="$du"; break; fi
  done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"uuid"[^{}]*}' || true)"
  [[ -n $dom_uuid ]] || die "teardown: domain '$domain' not found under the resolved scope"

  # --- delete Cloudflare DNS records ---
  step "Removing Cloudflare DNS records for $domain"
  cf_zone_ready
  local verify_prefix="${DNS_DOMAIN_VERIFY_PREFIX:-postal-verification}"
  cf_delete_record "$dry" TXT "${verify_prefix}.${domain}"

  api_request GET "$base_url/domains/$dom_uuid/dns_records"
  if [[ $API_STATUS == 200 ]]; then
    local r
    while IFS= read -r r; do
      [[ -n $r ]] || continue
      local type host value
      type="$(printf '%s' "$r" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')"
      host="$(printf '%s' "$r" | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')"
      value="$(printf '%s' "$r" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')"
      [[ -n $type && -n $host ]] || continue
      cf_delete_record "$dry" "$type" "$host"
    done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"host"[^{}]*}' || true)"
  else
    warn "could not fetch dns_records for $domain (API $API_STATUS); skipping per-record deletion"
  fi
  # The apex TXT (SPF) is a per-domain record; delete it too.
  cf_delete_record "$dry" TXT "$domain"

  # --- delete domain from Postal ---
  step "Deleting domain from Postal"
  if [[ $dry == true ]]; then
    log "  [dry-run] would DELETE $base_url/domains/$dom_uuid"
  else
    api_request DELETE "$base_url/domains/$dom_uuid"
    [[ $API_STATUS == 204 || $API_STATUS == 200 ]] || warn "domain delete -> $API_STATUS ($API_BODY)"
    ok "deleted domain '$domain'"
  fi

  # --- optionally delete server / org ---
  if [[ $remove_server == true && -n $srv_permalink ]]; then
    step "Deleting mail server"
    if [[ $dry == true ]]; then
      log "  [dry-run] would DELETE /api/v2/organizations/$org_permalink/servers/$srv_permalink"
    else
      api_request DELETE "/api/v2/organizations/$org_permalink/servers/$srv_permalink"
      [[ $API_STATUS == 204 || $API_STATUS == 200 ]] || warn "server delete -> $API_STATUS ($API_BODY)"
      ok "deleted server '$srv_permalink'"
    fi
  fi
  if [[ $remove_org == true ]]; then
    step "Deleting organization"
    if [[ $dry == true ]]; then
      log "  [dry-run] would DELETE /api/v2/organizations/$org_permalink"
    else
      api_request DELETE "/api/v2/organizations/$org_permalink"
      [[ $API_STATUS == 204 || $API_STATUS == 200 ]] || warn "org delete -> $API_STATUS ($API_BODY)"
      ok "deleted organization '$org_permalink'"
    fi
  fi

  echo
  echo "================ teardown complete ================"
  echo "  domain:    $domain"
  if [[ $remove_server == true ]]; then echo "  server:    $srv_permalink (removed)"; fi
  if [[ $remove_org == true ]]; then echo "  org:       $org_permalink (removed)"; fi
  echo "===================================================="
}

teardown_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh teardown --domain client.com [options]

Cleanly removes a client domain and its infrastructure.

  --domain client.com  The domain to tear down (required).
  --org NAME           Organization permalink (default: first found).
  --server-name NAME   Mail server permalink (default: first found).
  --server             Also delete the mail server after the domain.
  --remove-org         Also delete the organization after the server/domain.
  --dry-run            Print what would happen without changing anything.

Removes the domain's Cloudflare DNS records (per-domain records + verification
TXT), then the Postal domain, and optionally the server and organization. This
is the clean mirror of `onboard`.
USAGE
}

# ./deploy.sh mta-sts -- write the MTA-STS policy and enable the records.
#
# Enables MTA-STS for the installation's web/domain: writes the policy file at
# config/mta-sts/.well-known/mta-sts.txt (served by the mtasts container and
# the mta-sts.<domain> tunnel route), sets DNS_MTA_STS=true, and publishes the
# _mta-sts TXT via the per-domain Cloudflare flow.

mta_sts_cmd() {
  local dry=false
  while (($#)); do
    case $1 in
      --dry-run) dry=true; shift ;;
      -h|--help) mta_sts_usage; return 0 ;;
      *) die "mta-sts: unknown option '$1'" ;;
    esac
  done

  load_env
  need_env POSTAL_SMTP_HOSTNAME POSTAL_WEB_HOSTNAME

  local spd
  spd="$(printf '%s' "${DNS_SMTP_HOSTNAME:-$POSTAL_SMTP_HOSTNAME}" | sed 's/^mx\.//')"
  [[ -n $spd ]] || spd="$POSTAL_SMTP_HOSTNAME"

  local mx="$POSTAL_SMTP_HOSTNAME"
  local max_age="${DNS_MTA_STS_MAX_AGE:-604800}"
  local mode="${DNS_MTA_STS_MODE:-enforce}"

  local policy_dir="$CONFIG_DIR/mta-sts/.well-known"
  if [[ $dry == true ]]; then
    log "  [dry-run] would write $policy_dir/mta-sts.txt"
    log "  [dry-run] would set DNS_MTA_STS=true"
    return 0
  fi

  mkdir -p "$policy_dir"
  cat > "$policy_dir/mta-sts.txt" <<EOF
version: STSv1
mode: $mode
mx: $mx
max_age: $max_age
EOF
  ok "wrote $policy_dir/mta-sts.txt (mode $mode, mx $mx)"

  env_set DNS_MTA_STS true
  ok "DNS_MTA_STS=true in .env"

  info "now create/publish the _mta-sts TXT and the mta-sts CNAME/ingress:"
  info "  ./deploy.sh cloudflare provision   # CNAME + ingress"
  info "  ./deploy.sh cloudflare domain ${POSTAL_WEB_HOSTNAME} --verify   # TXT"
}

mta_sts_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh mta-sts [--dry-run]

Write the MTA-STS policy file and enable MTA-STS for this installation.

The policy is written to config/mta-sts/.well-known/mta-sts.txt, which is
served by the mtasts container at https://mta-sts.<web-hostname>/.well-known/
mta-sts.txt through the tunnel. It also sets DNS_MTA_STS=true so the tunnel
ingress and the _mta-sts TXT are published by the cloudflare commands.

Optional .env overrides:
  DNS_MTA_STS_MODE     enforce (default) | testing | none
  DNS_MTA_STS_MAX_AGE  policy lifetime in seconds (default 604800)
USAGE
}

# ./deploy.sh rspamd -- enable rspamd, render per-domain rules, reload.
#
# Opts the stack into rspamd spam inspection: sets RSPAMD_ENABLED=true in .env,
# starts the rspamd service, renders the per-domain allow/block maps from the
# management database, and reloads rspamd so the new rules are live.
#
# Optional flags:
#   --render-only   only regenerate the maps and reload; assume already enabled.

rspamd_cmd() {
  local render_only=false
  while (($#)); do
    case $1 in
      --render-only) render_only=true; shift ;;
      -h|--help) rspamd_usage; return 0 ;;
      *) die "rspamd: unknown option '$1'" ;;
    esac
  done

  load_env
  need_env POSTAL_IMAGE MAIN_DB_PASSWORD

  if [[ $render_only != true ]]; then
    env_set RSPAMD_ENABLED true
    ok "RSPAMD_ENABLED=true in .env"
    step "Starting rspamd"
    compose up -d rspamd
  fi

  step "Rendering per-domain spam rules"
  # Boot the app via rails runner in the bootstrap container so DomainSpamRule
  # is loadable. The renderer writes host ./config/rspamd through the
  # /rspamd-config mount, which the rspamd service binds into /etc/rspamd.
  compose_setup run --rm -T \
    -e RSPAMD_RENDER_DIR=/rspamd-config \
    bootstrap bundle exec rails runner /deploy-lib/render_rspamd.rb \
    || die "could not render rspamd maps"
  ok "rules rendered"

  step "Reloading rspamd"
  if service_running rspamd; then
    local cid
    cid="$(compose ps -q rspamd)"
    docker exec "$cid" rspamd --reload >/dev/null 2>&1 || \
      docker kill --signal HUP "$cid" >/dev/null 2>&1 || \
      warn "could not signal rspamd; it may pick up the maps on next start"
    ok "rspamd reloaded"
  else
    info "rspamd not running; it will load the maps when ./deploy.sh up starts it"
  fi

  log ""
  log "  Next: ./deploy.sh up   (if not already running with rspamd)"
  log "        ./deploy.sh doctor (includes an rspamd reachability check)"
}

rspamd_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh rspamd [--render-only]

Enable rspamd and render per-domain spam rules into live rspamd maps.

  --render-only   Only regenerate the maps and reload; do not change .env or
                  start the service.

The per-domain allow/block lists created through the management API
(/api/v2/.../spam_rules) are rendered into rspamd multimap files and rspamd is
reloaded so the rules take effect without restarting the stack.
USAGE
}

onboard_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh onboard --domain client.com [options]

Automates the full client-onboarding flow and prints the API key at the end.

  --domain client.com    The client domain to onboard (required).
  --org NAME             Organization permalink/name. If omitted and none exist,
                         a new one is created with this name.
  --server-name NAME     Mail server name (default: <domain>-mail).
  --test-to you@example.com
                         Also send an outbound test to that address.
  --no-test              Skip the test sends.

The flow creates/ensures: the organization, the mail server, the domain under
the server, the Cloudflare DNS records + verification, an address endpoint
(receive@<domain>), a route to it, and an API credential. The API key is
printed once at the end; use it as X-Server-API-Key for the legacy send API.
USAGE
}
