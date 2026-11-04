#!/usr/bin/env bash
# ./deploy.sh onboard -- automate client onboarding end to end.
#
# Runs the whole flow for a client domain:
#   1. resolve (or create) the organization
#   2. ensure the mail server exists (or create it)
#   3. create the domain under the server
#   4. publish + verify the domain's DNS records in Cloudflare
#   5. create an address endpoint (receive@<domain>)
#   6. create a route to that address endpoint
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
  local dom_uuid=""
  api_request GET "/api/v2/organizations/$org_permalink/servers/$srv_permalink/domains"
  local d
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    local du dn
    du="$(printf '%s' "$d" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')"
    dn="$(printf '%s' "$d" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
    if [[ -n $du && $dn == "$domain" ]]; then dom_uuid="$du"; break; fi
  done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"uuid"[^{}]*}' || true)"
  if [[ -z $dom_uuid ]]; then
    api_request POST "/api/v2/organizations/$org_permalink/servers/$srv_permalink/domains" "{\"name\":\"$domain\"}"
    [[ $API_STATUS == 201 || $API_STATUS == 200 ]] || die "create domain -> $API_STATUS ($API_BODY)"
    dom_uuid="$(printf '%s' "$API_BODY" | grep -o '"uuid":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  fi
  ok "domain uuid: $dom_uuid"

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
  step "Ensuring a route to the address endpoint"
  local route_uuid=""
  api_request GET "/api/v2/organizations/$org_permalink/servers/$srv_permalink/routes"
  local r
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    local ru
    ru="$(printf '%s' "$r" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')"
    if [[ -n $ru ]]; then route_uuid="$ru"; break; fi
  done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"uuid"[^{}]*}' || true)"
  if [[ -z $route_uuid ]]; then
    api_request POST "/api/v2/organizations/$org_permalink/servers/$srv_permalink/routes" \
      "{\"name\":\"receive-$domain\",\"endpoint_type\":\"AddressEndpoint\",\"endpoint_uuid\":\"$addr_uuid\"}"
    [[ $API_STATUS == 201 || $API_STATUS == 200 ]] || die "create route -> $API_STATUS ($API_BODY)"
    route_uuid="$(printf '%s' "$API_BODY" | grep -o '"uuid":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  fi
  ok "route $route_uuid"

  # --- 7. API credential ---
  step "Ensuring an API credential"
  local cred_uuid="" cred_key=""
  api_request GET "/api/v2/organizations/$org_permalink/servers/$srv_permalink/credentials"
  local c
  while IFS= read -r c; do
    [[ -n $c ]] || continue
    local cu ck
    cu="$(printf '%s' "$c" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')"
    ck="$(printf '%s' "$c" | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')"
    if [[ -n $cu && -n $ck ]]; then cred_uuid="$cu"; cred_key="$ck"; break; fi
  done <<<"$(printf '%s' "$API_BODY" | sed 's/},{/}\n{/g' | grep -o '{[^{}]*"uuid"[^{}]*}' || true)"
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
