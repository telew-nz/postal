#!/usr/bin/env bash
# ./deploy.sh dns -- print every DNS record this installation needs.
#
# Nothing here is hardcoded. The installation-wide records are derived from the
# dns.* configuration, the return-path DKIM value comes from the signing key via
# Postal's own script/default_dkim_record.rb, and the per-domain records come from
# GET /api/v2/.../dns_records. Two commands run against the same configuration
# therefore cannot drift apart.
#
# Read-only. It creates nothing and changes nothing.

dns_cmd() {
  local api=true

  while (($#)); do
    case $1 in
      --no-api) api=false; shift ;;
      -h|--help) dns_usage; return 0 ;;
      *)         die "dns: unknown option '$1'" ;;
    esac
  done

  require_cmd docker
  load_env
  need_env POSTAL_WEB_HOSTNAME POSTAL_SMTP_HOSTNAME \
           DNS_MX_RECORDS DNS_SPF_INCLUDE DNS_RETURN_PATH_DOMAIN \
           DNS_ROUTE_DOMAIN DNS_TRACK_DOMAIN DNS_HELO_HOSTNAME

  local dkim_id verify_prefix rp_prefix
  dkim_id="${DNS_DKIM_IDENTIFIER:-postal}"
  verify_prefix="${DNS_DOMAIN_VERIFY_PREFIX:-postal-verification}"
  rp_prefix="${DNS_CUSTOM_RETURN_PATH_PREFIX:-psrp}"

  dns_header

  step "1. The names in dns.mx_records need A records"
  # dns.mx_records are hostnames, not addresses. They are what every sending
  # domain's MX points at, so each one has to resolve to this host or inbound
  # mail has nowhere to go. There is no record of the public address in Postal's
  # configuration -- it cannot know it from inside a NAT'd container -- which is
  # why POSTAL_PUBLIC_IP is asked for separately.
  local mx ip
  local -a _mxes=()
  ip="${POSTAL_PUBLIC_IP:-}"
  IFS=',' read -ra _mxes <<<"$DNS_MX_RECORDS"
  for mx in "${_mxes[@]}"; do
    mx="${mx// /}"
    [[ -n $mx ]] || continue
    if [[ -n $ip ]]; then
      dns_row A "$mx" "$ip"
    else
      dns_row A "$mx" "<this host's public IPv4 -- set POSTAL_PUBLIC_IP>"
    fi
  done

  step "2. The SPF include domain"
  # has_dns_checks.rb greps the resolved records for one beginning `v=spf1`, and
  # domain.spf_record makes every sending domain include this name. The mechanism
  # list is not something Postal defines -- it has to authorise whatever actually
  # sends -- so this is the conventional shape with the real hostname filled in.
  dns_row TXT "$DNS_SPF_INCLUDE" "v=spf1 mx a:${POSTAL_SMTP_HOSTNAME} ~all"
  info "must begin with v=spf1 and authorise every address this host sends from."

  step "3. The return-path domain (bounces and DKIM)"
  dns_row MX "$DNS_RETURN_PATH_DOMAIN" "10 ${POSTAL_SMTP_HOSTNAME}"
  # The envelope sender (MAIL FROM / Return-Path) is <local>@<return-path
  # domain>, so SPF is checked against THAT domain. Without an SPF record here,
  # SPF is NONE and DMARC fails even when DKIM passes.
  dns_row TXT "$DNS_RETURN_PATH_DOMAIN" "v=spf1 mx a:${POSTAL_SMTP_HOSTNAME} ~all"
  # DKIMHeader falls back to d=dns.return_path_domain with s=dns.dkim_identifier
  # whenever a domain has no verified DKIM key of its own, which is the common
  # case. The value is the public half of config/signing.key.
  local rp_dkim
  rp_dkim="$(dns_rp_dkim_record)"
  if [[ -n $rp_dkim ]]; then
    dns_row TXT "${dkim_id}._domainkey.${DNS_RETURN_PATH_DOMAIN}" "$rp_dkim"
  else
    dns_row TXT "${dkim_id}._domainkey.${DNS_RETURN_PATH_DOMAIN}" \
      "<unavailable -- see the warning above>"
  fi

  step "4. The route domain"
  # smtp_server/client.rb routes a recipient at dns.route_domain to the address
  # endpoint or HTTP endpoint the route names, so mail has to arrive here.
  dns_row MX "$DNS_ROUTE_DOMAIN" "10 ${POSTAL_SMTP_HOSTNAME}"

  step "5. The tracking domain"
  # track_domain.rb#check_dns requires exactly one CNAME at
  # <track domain>.<sending domain> pointing at dns.track_domain, and that name
  # has to reach the web process, which is what serves the redirect.
  dns_row CNAME "$DNS_TRACK_DOMAIN" "${POSTAL_WEB_HOSTNAME}."

  step "6. Reverse DNS, configured at the hosting provider"
  if [[ -n $ip ]]; then
    dns_row PTR "$ip" "$DNS_HELO_HOSTNAME"
  else
    dns_row PTR "<public IPv4>" "$DNS_HELO_HOSTNAME"
  fi
  info "not a DNS record you can create: ask the provider. It is the single most"
  info "common reason outbound mail is rejected, and it must match DNS_HELO_HOSTNAME"
  info "and the hostname of every registered IP address."

  if [[ $api == true ]]; then
    dns_per_domain "$verify_prefix" "$rp_prefix"
  else
    log ""
    info "--no-api given, skipping the per-domain records."
  fi

  log ""
  log "  After publishing, verify each domain:"
  log "    POST /api/v2/organizations/:org/domains/:uuid/verify"
  log "    POST /api/v2/organizations/:org/servers/:server/domains/:uuid/verify"
  log ""
  log "  Which of the two applies depends on whether the domain is attached to the"
  log "  organization or to a single server. The per-domain lines above print the"
  log "  exact path for each, so copy it from there rather than guessing."
  log ""
  log "  Then confirm what actually resolves:  ./deploy.sh doctor"
  return 0
}

dns_header() {
  log ""
  log "  Records for the installation at ${POSTAL_WEB_HOSTNAME}"
  log "  Mail hostname ${POSTAL_SMTP_HOSTNAME}, sending as ${DNS_HELO_HOSTNAME}"
  log ""
  log "  Trailing dots are omitted; add them if your DNS provider needs them."
}

# One record, aligned. Printed rather than returned so that the alignment is
# decided in one place.
dns_row() {
  printf '  %-6s %-46s %s\n' "$1" "$2" "$3"
}

# The public half of the DKIM signing key, from Postal's own script. It requires
# only the configuration and the key file -- no database -- but it does need the
# image, so it is run in the bootstrap container.
dns_rp_dkim_record() {
  if [[ ! -f $SIGNING_KEY ]]; then
    warn "$SIGNING_KEY is missing, so the return-path DKIM record cannot be"
    warn "derived. Run ./deploy.sh init, then ./deploy.sh dns again."
    return 0
  fi

  # The record is derived inside the image, so the image has to exist. Reported
  # rather than left to compose, whose "failed to resolve reference" does not say
  # that the fix is to build.
  local image=${POSTAL_IMAGE:-postal:local}
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    warn "image '$image' is not present, so the return-path DKIM record cannot be"
    warn "derived. Run ./deploy.sh build, then ./deploy.sh dns again."
    return 0
  fi

  local out
  # The record is the only thing on stdout; anything else is a Ruby backtrace,
  # which is more useful shown than swallowed.
  out="$(run_bootstrap bundle exec ruby script/default_dkim_record.rb 2>&1)" || {
    warn "could not derive the return-path DKIM record:"
    printf '%s\n' "$out" | tail -n 5 | while read -r line; do warn "  $line"; done
    return 0
  }
  printf '%s' "$out" | tail -n1
  return 0
}

# ---------------------------------------------------------------------------
# Per-domain records, from the API
#
# This is the part which cannot be derived from configuration alone: the SPF and
# DKIM values depend on each domain's own generated key and verification token.

dns_per_domain() {
  local verify_prefix=$1 rp_prefix=$2

  step "7. Per-domain records, from the management API"

  if [[ -z ${POSTAL_API_TOKEN:-} ]]; then
    warn "POSTAL_API_TOKEN is not set, so the per-domain records cannot be fetched."
    warn "Run ./deploy.sh admin, which saves a token, then ./deploy.sh dns again."
    return 0
  fi

  require_cmd curl

  # Not `orgs="$(api_request ...)"`: the command substitution would run
  # api_request in a subshell, leaving API_STATUS at its initialized value and
  # this branch permanently taken. See api_request in lib/common.sh.
  api_request GET /api/v2/organizations
  local orgs="$API_BODY"
  if [[ $API_STATUS != 200 ]]; then
    warn "GET /api/v2/organizations -> ${API_STATUS}"
    dns_api_hint "$orgs"
    return 0
  fi

  # The envelope is {data: [...], pagination: {...}}, and each organization has a
  # permalink which is the path segment the nested routes take.
  # `{ grep ... || true; }` because a response with no permalinks in it makes
  # grep exit 1, and under pipefail that becomes the command substitution's
  # status -- so errexit aborts the whole command here, before the branch below
  # can say that a fresh installation simply has no organizations yet. An empty
  # list is the normal starting state rather than an error, and the info line
  # below is the message that reports it.
  local permalinks
  permalinks="$(printf '%s' "$orgs" |
                { grep -o '"permalink":"[^"]*"' || true; } |
                sed 's/"permalink":"//; s/"$//')"

  if [[ -z $permalinks ]]; then
    info "no organizations exist yet, so there are no domains to publish records for."
    return 0
  fi

  local org
  while read -r org; do
    [[ -n $org ]] || continue
    dns_one_organization "$org" "$verify_prefix" "$rp_prefix"
  done <<<"$permalinks"

  return 0
}

dns_one_organization() {
  local org=$1 verify_prefix=$2 rp_prefix=$3

  log ""
  log "  ${C_BOLD}organization ${org}${C_RESET}"

  # Domains are scoped at two levels, and the API treats them as two separate
  # collections in two separate URL trees:
  #
  #   /organizations/:org/domains                    owned by the organization
  #   /organizations/:org/servers/:srv/domains       owned by one server
  #
  # A domain you intend to send from is normally attached to the server, so
  # walking only the first of these -- as this originally did -- printed an
  # organization header, printed no records, and exited 0. Nothing failed, which
  # is what made it easy to miss: the collection it asked about genuinely was
  # empty, and the domains were in the one it never asked about.
  dns_domains_under "/api/v2/organizations/${org}" "    " "$verify_prefix" "$rp_prefix"

  api_request GET "/api/v2/organizations/${org}/servers"
  if [[ $API_STATUS != 200 ]]; then
    warn "GET /api/v2/organizations/${org}/servers -> ${API_STATUS}"
    return 0
  fi

  # The server's own permalink. `full_permalink` and `organization_permalink`
  # appear in the same objects but do not collide with this pattern: both are
  # preceded by an underscore, and the pattern requires a quote immediately
  # before `permalink`.
  # `{ grep ... || true; }` because an organization with no servers makes grep
  # exit 1, and pipefail would hand that to errexit.
  local servers
  servers="$(printf '%s' "$API_BODY" |
             { grep -o '"permalink":"[^"]*"' || true; } |
             sed 's/"permalink":"//; s/"$//')"

  local srv
  while read -r srv; do
    [[ -n $srv ]] || continue
    log ""
    log "    ${C_BOLD}server ${srv}${C_RESET}"
    dns_domains_under "/api/v2/organizations/${org}/servers/${srv}" "      " \
                      "$verify_prefix" "$rp_prefix"
  done <<<"$servers"

  return 0
}

# Every domain in one collection, and the records for each.
#
#   $1  the API path the collection hangs off, with no trailing /domains
#   $2  how far to indent the domain name, so nesting stays visible
#
# $1 is carried through to the verify and dns_records URLs rather than being
# rebuilt from the organization permalink: a server-scoped domain 404s on the
# org-scoped path, so the URL has to come from the collection it was listed in.
dns_domains_under() {
  local base=$1 indent=$2 verify_prefix=$3 rp_prefix=$4

  api_request GET "${base}/domains"
  local body="$API_BODY"
  if [[ $API_STATUS != 200 ]]; then
    warn "GET ${base}/domains -> ${API_STATUS}"
    return 0
  fi

  # Split the data array into one object per line so that each domain's fields can
  # be read from the same object rather than from positionally-matched lists, which
  # would silently misalign if any domain omitted a field. Rails renders compact
  # JSON, so the separator between elements is exactly `},{`.
  # `{ grep ... || true; }`: a collection with no domains makes grep exit 1, and
  # pipefail would propagate that to errexit -- aborting the whole `dns` command
  # after it has already printed the headers above. Every organization, and every
  # server just created, starts with zero domains, so this is the common case.
  printf '%s' "$body" |
    sed 's/},{/}\n{/g' |
    { grep -o '{[^{}]*"uuid"[^{}]*}' || true; } |
    while read -r d; do
      local uuid name verified token
      uuid="$(printf '%s' "$d" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')"
      name="$(printf '%s' "$d" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
      verified="$(printf '%s' "$d" | sed -n 's/.*"verified":\([a-z]*\).*/\1/p')"
      token="$(printf '%s' "$d" | sed -n 's/.*"verification_token":"\([^"]*\)".*/\1/p')"

      [[ -n $uuid && -n $name ]] || continue

      log ""
      log "${indent}${C_BOLD}${name}${C_RESET}"

      if [[ $verified != true ]]; then
        # The dns_records endpoint answers 422 NotVerified until the domain has
        # been verified, so for an unverified domain the only record that can be
        # published is the one which makes verification possible.
        dns_row TXT "${verify_prefix}.${name}" "${verify_prefix} ${token}"
        info "publish that, then POST ${base}/domains/${uuid}/verify"
        info "and re-run ./deploy.sh dns for the remaining records."
        continue
      fi

      dns_domain_records "${base}/domains/${uuid}" "$rp_prefix"
    done

  return 0
}

# $1 is the domain's own API path, so an org-scoped and a server-scoped domain
# each resolve to the dns_records URL they actually answer on.
dns_domain_records() {
  local base=$1 rp_prefix=$2

  api_request GET "${base}/dns_records"
  local body="$API_BODY"
  if [[ $API_STATUS != 200 ]]; then
    warn "      GET ${base}/dns_records -> ${API_STATUS}"
    return 0
  fi

  # Matched on "host", which every record has and which the sibling `domain`
  # object in the same response does not. Matching on "type" instead would be
  # ambiguous: DomainSerializer renders owner_type.
  # `{ grep ... || true; }` for the same reason as in dns_one_organization: a
  # response carrying no records makes grep exit 1, and pipefail would abort the
  # command rather than print nothing for this domain and carry on.
  printf '%s' "$body" |
    sed 's/},{/}\n{/g' |
    { grep -o '{[^{}]*"host"[^{}]*}' || true; } |
    while read -r r; do
      local type rname host value required status
      type="$(printf '%s' "$r" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')"
      rname="$(printf '%s' "$r" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
      host="$(printf '%s' "$r" | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')"
      value="$(printf '%s' "$r" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')"
      required="$(printf '%s' "$r" | sed -n 's/.*"required":\([a-z]*\).*/\1/p')"
      status="$(printf '%s' "$r" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"

      [[ -n $type ]] || continue
      dns_row "$type" "${host:-$rname}" "$value"
      if [[ $required != true ]]; then
        info "optional"
      fi
      if [[ -n $status && $status != OK ]]; then
        info "currently: $status"
      fi
    done

  return 0
}

# The two 401s are distinguishable and mean different things, and telling them
# apart here saves a round trip.
dns_api_hint() {
  local body=$1
  case $body in
    *MissingAPIKey*) warn "the X-Postal-API-Key header was absent or unrecognized." ;;
    *InvalidAPIKey*) warn "the token is unknown, revoked or expired." ;;
    *)               [[ -n $body ]] && warn "$body" ;;
  esac
  return 0
}

dns_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh dns [--no-api]

Prints every DNS record this installation needs: the A records for the names in
dns.mx_records, the SPF include, the return-path MX and DKIM, the route domain,
the tracking domain, the PTR to ask the hosting provider for, and then the
per-domain SPF, DKIM, return-path CNAME and MX records fetched from the
management API.

  --no-api   Only the records derivable from configuration. Use when the stack is
             not running or no token is available.

Read-only: nothing is created or changed.
USAGE
}
