#!/usr/bin/env bash
# ./deploy.sh tls -- a certificate the SMTP server can present to a stranger.
#
# What this buys, stated plainly, because it is less than it sounds like.
#
# Inbound mail on port 25 is opportunistic. RFC 7435 is explicit that a sending
# server which cannot establish a *validated* TLS session must fall back to
# plaintext rather than give up, so for ordinary server-to-server delivery a
# self-signed certificate is indistinguishable from one Let's Encrypt signed.
# This is not a deliverability fix and should not be described as one.
#
# What a publicly trusted certificate does buy:
#
#   MTA-STS (RFC 8461)  Senders which support it -- Gmail, Microsoft, Yahoo,
#                       Fastmail -- validate the chain and the hostname, and under
#                       an `enforce` policy refuse to deliver over a connection
#                       which fails validation. This is the case where a CA-signed
#                       certificate is a hard requirement. Note it is necessary
#                       but not sufficient: MTA-STS also needs the policy file
#                       served over HTTPS at mta-sts.<domain> and a _mta-sts TXT
#                       record, and Postal serves neither. See doc/deployment.md.
#   DANE (RFC 7672)     A TLSA record can pin the end-entity certificate, in
#                       which case CA validity is irrelevant -- but DANE needs a
#                       DNSSEC-signed zone, which is a larger undertaking than
#                       this.
#   Submission          Any mail client authenticating to this server validates
#                       the certificate the way a browser does.
#
# The challenge is DNS-01 rather than HTTP-01 for two reasons. There is no HTTP
# listener on port 25 and the web origin is behind a Cloudflare Tunnel on a
# different hostname, so HTTP-01 has nowhere to answer. And DNS-01 does not
# require the validated name to be the name being served, which matters here
# because the MX hostname and the web hostname are deliberately different.

# The CA is named explicitly on every invocation rather than set once with
# --set-default-ca, because the default is not the one anyone would guess.
# acme.sh's DEFAULT_CA is ZeroSSL, whose registration needs EAB credentials this
# deployment does not have; its DEFAULT_STAGING_CA, meanwhile, IS Let's Encrypt
# staging, so passing --staging alone would silently select a different CA from
# the one an unflagged run selects. The choice is recorded per-domain at issue
# time, so getting the first one wrong is sticky.
ACME_CA_PRODUCTION="letsencrypt"
ACME_CA_STAGING="letsencrypt_test"

# RSA rather than ECDSA. Some MTAs in the wild still have TLS stacks which do not
# handle ECDSA certificates, and a certificate the peer cannot use is worse than
# a larger handshake. It also keeps acme.sh's certificate directory named after
# the domain rather than "<domain>_ecc", which is one less thing for the install
# step to have to track.
ACME_KEYLENGTH="${ACME_KEYLENGTH:-2048}"

# How many days before expiry a renewal is attempted. Set at issue time: acme.sh
# stores it in the per-domain configuration and --renew reads it from there, so
# changing this afterwards needs a re-issue to take effect.
ACME_RENEW_DAYS="${ACME_RENEW_DAYS:-30}"

# Set by tls_load_domains. Element 0 is the primary domain, which is the
# directory acme.sh files the certificate under and therefore the name every
# later invocation has to agree on.
TLS_DOMAINS=()
# Set by tls_issue and tls_renew from --staging.
TLS_CA="$ACME_CA_PRODUCTION"

tls_cmd() {
  local sub=${1:-status}
  if (($#)); then shift; fi

  case $sub in
    issue)   tls_issue "$@" ;;
    renew)   tls_renew "$@" ;;
    install) tls_install_cmd "$@" ;;
    import)  tls_import_cmd "$@" ;;
    status)  tls_status "$@" ;;
    -h|--help) tls_usage; return 0 ;;
    *)
      printf 'deploy.sh: unknown tls subcommand "%s"\n\n' "$sub" >&2
      tls_usage >&2
      return 2
      ;;
  esac
}

# Shared by every subcommand. openssl is used on the host rather than in a
# container: the files are on the host, port 25 is published on the host, and a
# check which ran inside the network namespace it is inspecting would not be
# checking the same thing an external sender reaches.
tls_prepare_base() {
  require_cmd docker
  require_cmd openssl
  load_env
}

tls_prepare() {
  tls_prepare_base
  need_env POSTAL_SMTP_HOSTNAME DNS_MX_RECORDS
}

# The names the certificate has to cover, primary first and deduplicated.
#
# Derived from the same two values ./deploy.sh dns publishes rather than from a
# variable of its own. A certificate whose names are configured independently of
# the MX records is a certificate which silently stops matching them the first
# time the records change, and the failure surfaces at the sender.
tls_load_domains() {
  TLS_DOMAINS=()
  local seen=" " n
  local -a parts=()

  # POSTAL_SMTP_HOSTNAME first and therefore primary: it is the name in the 220
  # banner, so it is the one a connecting server was told to expect before it ever
  # looked at a certificate.
  IFS=',' read -ra parts <<<"$POSTAL_SMTP_HOSTNAME,$DNS_MX_RECORDS"
  for n in ${parts[@]+"${parts[@]}"}; do
    n="${n// /}"
    if [[ -z $n ]]; then continue; fi
    # Lowercased because DNS names are case-insensitive but acme.sh uses the
    # string as a directory name: a certificate for MX.Example.com would be filed
    # separately from one for mx.example.com and renewal would not find it.
    n="$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')"
    if [[ $seen == *" $n "* ]]; then continue; fi
    seen="$seen$n "
    TLS_DOMAINS+=("$n")
  done

  if ((${#TLS_DOMAINS[@]} == 0)); then
    die "no hostnames to issue for: POSTAL_SMTP_HOSTNAME and DNS_MX_RECORDS are both empty"
  fi
  return 0
}

# Subject Alternative Names of an installed certificate, one per line, lowercased
# and sorted. Empty output if there is no certificate or it cannot be parsed,
# which callers treat as "unknown" rather than as "none".
tls_cert_sans() {
  local f=$1
  [[ -f $f ]] || return 0
  # `|| true` because grep exits 1 on no match, and pipefail would turn a
  # certificate without a SAN extension into a failed command.
  #
  # Spaces, tabs and carriage returns only -- not [:space:], which includes the
  # newline and would collapse every name into one token before sort ever saw
  # them. The result then matches no name, so a correct certificate is reported
  # as covering none of the configured ones.
  openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null |
    grep -o 'DNS:[^,]*' | sed 's/^DNS://' |
    tr -d ' \t\r' | tr '[:upper:]' '[:lower:]' |
    sort -u || true
}

# The file to read names from. The installed copy is preferred; the ACME state
# directory is the fallback for a renewal which has not been installed yet.
tls_cert_source() {
  if [[ -f $TLS_CERT ]]; then
    printf '%s' "$TLS_CERT"
  else
    printf '%s' "$ACME_DIR/$1/fullchain.cer"
  fi
}

# ---------------------------------------------------------------------------
# issue

# Build the name list for a wildcard issuance: the apex plus its wildcard,
# primary (and therefore the acme.sh state directory) being the apex. DNS-01
# is required for wildcards; the command already uses it.
tls_set_wildcard_domains() {
  local domain=$1
  domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
  [[ -n $domain ]] || die "--wildcard needs a base domain"
  [[ $domain != \** ]] || die "--wildcard takes the base domain (e.g. example.com), not '*.example.com'"
  [[ $domain == *.* ]] || die "--wildcard must be a registered domain (e.g. example.com)"
  TLS_DOMAINS=("$domain" "*.$domain")
}

tls_issue() {
  local staging=false wildcard=""
  while (($#)); do
    case $1 in
      --staging) staging=true; shift ;;
      --wildcard) wildcard=${2:?--wildcard needs a domain}; shift 2 ;;
      -h|--help) tls_usage; return 0 ;;
      *) die "tls issue: unknown option '$1'" ;;
    esac
  done

  tls_prepare_base
  need_env CLOUDFLARE_DNS_API_TOKEN ACME_CONTACT_EMAIL
  if [[ -n $wildcard ]]; then
    tls_set_wildcard_domains "$wildcard"
  else
    need_env POSTAL_SMTP_HOSTNAME DNS_MX_RECORDS
    tls_load_domains
  fi
  if [[ $staging == true ]]; then TLS_CA="$ACME_CA_STAGING"; else TLS_CA="$ACME_CA_PRODUCTION"; fi
  tls_check_contact_email

  mkdir -p "$ACME_DIR" "$ACME_INSTALL_DIR"

  step "Issuing a certificate from $TLS_CA"
  log "  names    ${TLS_DOMAINS[*]}"
  log "  key      RSA $ACME_KEYLENGTH"
  log "  contact  $ACME_CONTACT_EMAIL"
  log "  renewal  $ACME_RENEW_DAYS days before expiry"

  if [[ $staging == true ]]; then
    warn "staging certificate: nobody trusts it, so this does not make TLS work."
    warn "  It proves the DNS-01 flow end to end without spending production rate"
    warn "  limit. Re-run without --staging afterwards, and note that the two use"
    warn "  different CAs and therefore different accounts."
  else
    info "Let's Encrypt allows 5 duplicate certificates per exact name set per week."
  fi

  local -a args=(
    --issue
    --dns dns_cf
    --server "$TLS_CA"
    --keylength "$ACME_KEYLENGTH"
    # -m rather than the --accountemail alias the parser also accepts, because
    # this is the form the --help text documents and the one verified to reach
    # the CA: _getAccountEmail prefers the exported ACCOUNT_EMAIL over anything
    # stored, so the contact is registered with the account on this run. The
    # help's claim that it is "only valid for --install and --update-account" is
    # wrong, which is worth knowing because the alternative reading is that a
    # first issuance would register with no contact and no expiry warnings.
    -m "$ACME_CONTACT_EMAIL"
    --days "$ACME_RENEW_DAYS"
    # Unconditional. `issue` is an explicit operator action, and without this
    # acme.sh refuses to replace a certificate which is not near expiry with a
    # message that does not distinguish "already valid, nothing done" from
    # "refused". The cost is rate limit, which is why the limit is printed above.
    --force
  )
  if [[ -n ${ACME_DEBUG:-} ]]; then args+=(--debug "$ACME_DEBUG"); fi

  local d
  for d in ${TLS_DOMAINS[@]+"${TLS_DOMAINS[@]}"}; do args+=(-d "$d"); done

  if ! run_acme ${args[@]+"${args[@]}"}; then
    log ""
    fail "issuance failed."
    fail "  The two causes worth checking first, in order:"
    fail "  1. CLOUDFLARE_DNS_API_TOKEN lacks Zone/DNS/Edit on the zone containing"
    fail "     ${TLS_DOMAINS[0]}, or that zone is not on this Cloudflare account."
    fail "  2. The names above are not in a zone this account can write to at all."
    fail "     DNS-01 needs to create _acme-challenge.<name> TXT records."
    fail "  Re-run with ACME_DEBUG=2 for the client's own trace."
    return 1
  fi

  tls_install
}

# Let's Encrypt validates the contact address against the public suffix list and
# rejects reserved domains, so a placeholder fails with
# urn:ietf:params:acme:error:invalidContact -- after the account key has been
# created, and in a form which does not say that the email address is at fault.
#
# The address is worth having in any case: it is the only warning which arrives
# before a certificate expires, and an expired SMTP certificate presents as
# senders quietly downgrading to plaintext rather than as an error here.
tls_check_contact_email() {
  local e=$ACME_CONTACT_EMAIL
  if [[ ! $e =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]{2,}$ ]]; then
    die "ACME_CONTACT_EMAIL='$e' is not an email address."
  fi
  case ${e##*@} in
    example.com|example.org|example.net|example.invalid|localhost|local|test|invalid)
      die "ACME_CONTACT_EMAIL uses '${e##*@}', which Let's Encrypt rejects as a contact domain. Use a real one."
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# renew

tls_renew() {
  local force=false
  while (($#)); do
    case $1 in
      --staging) TLS_CA="$ACME_CA_STAGING"; shift ;;
      --force)   force=true; shift ;;
      -h|--help) tls_usage; return 0 ;;
      *) die "tls renew: unknown option '$1'" ;;
    esac
  done

  tls_prepare
  tls_load_domains

  # The ACME state directory that covers every currently required name. For a
  # plainly-issued certificate this is usually the first config-derived name. For
  # a wildcard issue the state lives under the apex (thefizzylab.nz) while the
  # config names are the MX hostnames (mx.thefizzylab.nz), so we cannot assume
  # the directory name equals TLS_DOMAINS[0].
  local primary=""
  local d
  for d in "$ACME_DIR"/*/; do
    [[ -d $d ]] || continue
    local cand="${d%/}"; cand="${cand##*/}"
    local all_covered=true n san
    local sans
    sans="$(tls_cert_sans "$d/fullchain.cer")"
    [[ -n $sans ]] || continue
    for n in ${TLS_DOMAINS[@]+"${TLS_DOMAINS[@]}"}; do
      local covered=false
      for san in $sans; do
        if tls_san_covers "$san" "$n"; then covered=true; break; fi
      done
      if [[ $covered != true ]]; then all_covered=false; break; fi
    done
    if [[ $all_covered == true ]]; then primary="$cand"; break; fi
  done

  # Distinguished from a renewal failure because the two need different
  # responses: this one is "run tls issue", the other is "read the log". Without
  # the check, a timer firing on a host which never issued would report an acme.sh
  # error about a domain it has no configuration for.
  if [[ -z $primary ]]; then
    die "no certificate has ever been issued that covers ${TLS_DOMAINS[*]}. Run ./deploy.sh tls issue first."
  fi

  step "Renewing the certificate for ${TLS_DOMAINS[*]}"

  # A renewal renews the certificate as it stands. It does not notice that
  # DNS_MX_RECORDS gained a name since issuance, and the result is a valid,
  # trusted certificate which no longer covers one of the names remote servers are
  # told to connect to -- reported nowhere here, and refused at the sender.
  local issued missing=() n san
  issued="$(tls_cert_sans "$(tls_cert_source "$primary")")"
  if [[ -n $issued ]]; then
    for n in ${TLS_DOMAINS[@]+"${TLS_DOMAINS[@]}"}; do
      local covered=false
      for san in $issued; do
        if tls_san_covers "$san" "$n"; then covered=true; break; fi
      done
      [[ $covered == true ]] || missing+=("$n")
    done
    if ((${#missing[@]})); then
      warn "the installed certificate does not cover: ${missing[*]}"
      warn "  renewal will not add them. ./deploy.sh tls issue re-issues for the"
      warn "  current name set -- subject to the duplicate-certificate limit."
    fi
  else
    warn "could not read the SAN list from the installed certificate; name coverage unchecked"
  fi

  # Only the primary name is passed. --renew takes a certificate name, not a name
  # set: acme.sh reads the subject alternative names back out of the stored
  # per-domain configuration and replays them, and any further -d it is given is
  # accepted and then ignored. Passing the whole list would read as though it
  # described what gets renewed, when what actually gets renewed is decided by
  # element 0 alone -- the gap the SAN check above exists to close.
  local -a args=(--renew --server "$TLS_CA" -d "$primary")
  if [[ $force == true ]]; then args+=(--force); fi
  if [[ -n ${ACME_DEBUG:-} ]]; then args+=(--debug "$ACME_DEBUG"); fi

  local rc=0
  run_acme ${args[@]+"${args[@]}"} || rc=$?

  # Exit 2 is acme.sh's RENEW_SKIP, and it means "nothing was done", not "something
  # went wrong". With a 90-day certificate and ACME_RENEW_DAYS=30 that is the
  # expected outcome for roughly two thirds of a twice-daily schedule, so
  # reporting it as a failure would mark the systemd unit failed twice a day for
  # two months running -- which is how an operator learns to ignore the one alert
  # that matters, the genuine failure at the end of the window.
  #
  # Safe to read as "not due yet" rather than needing further discrimination:
  # the other path returning 2 is "not an issued domain", which the directory
  # check above already turns into its own message before acme.sh is reached, and
  # the client prints its own reason on the line before it exits. --force bypasses
  # the date check entirely, so a forced run cannot land here.
  if ((rc == 2)); then
    ok "not due for renewal; the installed certificate is unchanged"
    return 0
  elif ((rc != 0)); then
    fail "renewal failed (exit $rc). The existing certificate is untouched."
    fail "  Re-run with ACME_DEBUG=2 for the client's own trace."
    return 1
  fi

  tls_install
}

# ---------------------------------------------------------------------------
# install
#
# Copy the issued pair out of the ACME state directory and into ./config, which is
# where the schema defaults point and which is already mounted read-only into
# every Postal container.
#
# The copy happens on the host rather than by mounting ./config into the client,
# for two reasons. The client holds a Cloudflare DNS-edit token and ./config holds
# the DKIM signing key, so giving it write access there couples two unrelated
# credentials. And the client runs as root, so anything it writes is root-owned
# and unreadable by uid 999 -- the chown has to happen out here.

tls_install_cmd() {
  while (($#)); do
    case $1 in
      --staging) TLS_CA="$ACME_CA_STAGING"; shift ;;
      -h|--help) tls_usage; return 0 ;;
      *) die "tls install: unknown option '$1'" ;;
    esac
  done
  tls_prepare
  tls_load_domains
  tls_install
}

tls_install() {
  local primary="${TLS_DOMAINS[0]}"
  if [[ ! -d "$ACME_DIR/$primary" ]]; then
    die "nothing has been issued for $primary, so there is nothing to install"
  fi

  step "Installing into config/"

  # Fingerprinted before and after, because the answer decides whether the smtp
  # container has to be recreated -- and a recreate drops in-flight connections,
  # which is not worth doing twice in a row for a certificate that did not change.
  local before="" after=""
  if [[ -f $TLS_CERT ]]; then
    before="$(openssl x509 -in "$TLS_CERT" -noout -fingerprint -sha256 2>/dev/null || true)"
  fi

  # Always run explicitly rather than relying on the paths acme.sh recorded at
  # issue time. Those are stored in the per-domain configuration and a renewal
  # does replay them, but depending on that makes this step's correctness a
  # function of what some earlier invocation happened to pass.
  local -a args=(
    --install-cert
    --server "$TLS_CA"
    --key-file "/acme.sh/$ACME_INSTALL_SUBDIR/smtp.key"
    --fullchain-file "/acme.sh/$ACME_INSTALL_SUBDIR/smtp.cert"
  )
  local d
  for d in ${TLS_DOMAINS[@]+"${TLS_DOMAINS[@]}"}; do args+=(-d "$d"); done

  if ! run_acme ${args[@]+"${args[@]}"}; then
    die "the client failed to install the certificate from its own state directory"
  fi

  if [[ ! -s $ACME_INSTALL_DIR/smtp.cert || ! -s $ACME_INSTALL_DIR/smtp.key ]]; then
    die "the client reported success but wrote nothing usable to $ACME_INSTALL_DIR"
  fi

  # Copied rather than moved: the state directory is the source of truth acme.sh
  # renews from, and emptying it would make the next renewal a re-issue.
  install -m 644 "$ACME_INSTALL_DIR/smtp.cert" "$TLS_CERT"
  install -m 600 "$ACME_INSTALL_DIR/smtp.key" "$TLS_KEY"

  after="$(openssl x509 -in "$TLS_CERT" -noout -fingerprint -sha256 2>/dev/null || true)"
  local chain chain_word="certificates"
  chain="$(tls_cert_chain_count "$TLS_CERT")"
  if [[ ${chain:-0} == 1 ]]; then chain_word="certificate"; fi
  ok "config/smtp.cert (${chain:-0} $chain_word in the chain)"
  ok "config/smtp.key (mode 600)"

  # Readability decides whether TLS gets switched on at all. The dangerous
  # combination is tls_enabled true with a key the process cannot read: the server
  # answers "220 Ready to start TLS" and then the handshake raises, which server.rb
  # logs at debug level before dropping the connection. tls_enabled false at least
  # answers "502 TLS not available", which a sending server handles by falling
  # back to plaintext and continuing to deliver.
  local readable=true
  ensure_owned_by_postal "$TLS_CERT" || readable=false
  ensure_owned_by_postal "$TLS_KEY" || readable=false
  if [[ $readable != true ]]; then
    warn "uid $POSTAL_UID cannot read the installed files, so TLS is NOT being enabled."
    warn "  Fix the ownership printed above, then re-run:  ./deploy.sh tls install"
    return 1
  fi

  local was_enabled="${SMTP_SERVER_TLS_ENABLED:-false}"
  env_set SMTP_SERVER_TLS_ENABLED true
  ok "SMTP_SERVER_TLS_ENABLED=true in .env"

  if [[ $was_enabled == true && -n $after && "$before" == "$after" ]]; then
    info "the installed certificate is unchanged, so nothing is restarted"
  else
    tls_reload_smtp
  fi
  return 0
}

# ---------------------------------------------------------------------------
# import
#
# Install an already-obtained certificate (for example a wildcard issued
# elsewhere) into config/smtp.cert and config/smtp.key, enable TLS and recreate
# the smtp container. Shares the install semantics of tls_install: owned by
# uid 999, fullchain leaf-first, and only enabling TLS once the files are in
# place and readable.

tls_import_cmd() {
  local cert="" key=""
  while (($#)); do
    case $1 in
      -h|--help) tls_usage; return 0 ;;
      --) shift; break ;;
      -*) die "tls import: unknown option '$1'" ;;
      *)
        if [[ -z $cert ]]; then cert=$1
        elif [[ -z $key ]]; then key=$1
        else die "tls import: too many arguments"; fi
        shift
        ;;
    esac
  done
  [[ -n $cert && -n $key ]] || die "tls import requires CERT KEY paths"
  tls_prepare
  tls_import "$cert" "$key"
}

tls_import() {
  local cert=$1 key=$2
  step "Importing certificate into config/"
  [[ -f $cert ]] || die "certificate file not found: $cert"
  [[ -f $key ]] || die "private key file not found: $key"
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "$cert is not a valid PEM certificate"
  openssl pkey -in "$key" -noout >/dev/null 2>&1 || die "$key is not a valid PEM private key"

  local cm km
  cm="$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl sha256)"
  km="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256)"
  if [[ -n $cm && -n $km && $cm != "$km" ]]; then
    warn "the private key does not match the certificate's public key."
  fi

  local chain
  chain="$(tls_cert_chain_count "$cert")"
  if (( chain < 2 )); then
    warn "the certificate file contains only 1 certificate (no intermediate)."
    warn "  Provide a fullchain (leaf first, then intermediates) or ./deploy.sh doctor"
    warn "  will report the TLS chain as a failure."
  fi

  local before="" after=""
  if [[ -f $TLS_CERT ]]; then
    before="$(openssl x509 -in "$TLS_CERT" -noout -fingerprint -sha256 2>/dev/null || true)"
  fi

  install -m 644 "$cert" "$TLS_CERT"
  install -m 600 "$key" "$TLS_KEY"
  after="$(openssl x509 -in "$TLS_CERT" -noout -fingerprint -sha256 2>/dev/null || true)"

  ok "config/smtp.cert installed (${chain:-0} $([ "${chain:-0}" = 1 ] && echo certificate || echo certificates) in the chain)"
  ok "config/smtp.key installed (mode 600)"

  local readable=true
  ensure_owned_by_postal "$TLS_CERT" || readable=false
  ensure_owned_by_postal "$TLS_KEY" || readable=false
  if [[ $readable != true ]]; then
    warn "uid $POSTAL_UID cannot read the installed files, so TLS is NOT being enabled."
    warn "  Fix the ownership printed above, then re-run:  ./deploy.sh tls import $cert $key"
    return 1
  fi

  local was_enabled="${SMTP_SERVER_TLS_ENABLED:-false}"
  env_set SMTP_SERVER_TLS_ENABLED true
  ok "SMTP_SERVER_TLS_ENABLED=true in .env"

  if [[ $was_enabled == true && -n $after && "$before" == "$after" ]]; then
    info "the installed certificate is unchanged, so nothing is restarted"
  else
    tls_reload_smtp
  fi
  log ""
  log "  Next:  ./deploy.sh status"
  log "         ./deploy.sh doctor"
  return 0
}

# Recreate the smtp container rather than restarting it.
#
# `docker compose restart` reuses the existing container and therefore the
# environment it was created with, so a change to SMTP_SERVER_TLS_ENABLED in .env
# would never reach the process -- it would come up with TLS off while .env said
# on, and doctor reading .env would agree with it. Only a recreate picks the value
# up. The certificate itself would survive a plain restart, since it is read from
# the mounted file when the process starts, but the flag and the file have to
# arrive together.
#
# This drops in-flight SMTP connections, and there is no way around it:
# SMTPServer::Server memoizes the parsed certificate on the class and traps only
# TERM and INT, so there is no reload. A sender whose connection is dropped during
# a handshake retries, which is the normal outcome of a mail server restart.
tls_reload_smtp() {
  if ! service_running smtp; then
    info "smtp is not running; ./deploy.sh up will start it with the new certificate"
    return 0
  fi
  warn "recreating the smtp container, which drops in-flight SMTP connections"
  compose up -d --no-deps smtp >/dev/null
  ok "smtp recreated"
  return 0
}

# ---------------------------------------------------------------------------
# status

tls_status() {
  # Parsed before tls_prepare, like every other subcommand here, so that the help
  # is readable on a host which has not run init yet and cannot be read at all
  # once it has. `status` takes no options of its own; rejecting an unknown one
  # rather than ignoring it is what stops `tls status --staging` from looking like
  # it did something.
  while (($#)); do
    case $1 in
      -h|--help) tls_usage; return 0 ;;
      *) die "tls status: unknown option '$1'" ;;
    esac
  done

  tls_prepare
  tls_load_domains

  step "SMTP TLS"
  log "  required by the current configuration: ${TLS_DOMAINS[*]}"
  log "  SMTP_SERVER_TLS_ENABLED:               ${SMTP_SERVER_TLS_ENABLED:-false}"

  if [[ ! -f $TLS_CERT ]]; then
    warn "no certificate at $TLS_CERT"
    info "./deploy.sh tls issue   (needs CLOUDFLARE_DNS_API_TOKEN and ACME_CONTACT_EMAIL)"
    return 0
  fi

  local subject issuer notbefore notafter chain chain_word="certificates"
  subject="$(openssl x509 -in "$TLS_CERT" -noout -subject 2>/dev/null | sed 's/^subject=[[:space:]]*//')"
  issuer="$(tls_cert_issuer)"
  notbefore="$(openssl x509 -in "$TLS_CERT" -noout -startdate 2>/dev/null | sed 's/^notBefore=//')"
  notafter="$(openssl x509 -in "$TLS_CERT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  chain="$(tls_cert_chain_count "$TLS_CERT")"
  if [[ ${chain:-0} == 1 ]]; then chain_word="certificate"; fi

  log "  subject:  $subject"
  log "  issuer:   $issuer"
  log "  valid:    $notbefore  ->  $notafter"
  log "  chain:    ${chain:-0} $chain_word"
  log "  names:    $(tls_cert_sans "$TLS_CERT" | tr '\n' ' ')"

  if [[ $(tls_is_self_signed) == yes ]]; then
    warn "this certificate is self-signed -- no remote server will trust it"
  fi

  # A leaf-only file is the other easy mistake, and it is not caught by any
  # validation of the certificate itself. server.rb assigns tls_certificates[0]
  # to the context and tls_certificates[1..] to extra_chain_cert, having scanned
  # every PEM block in the file in order, so a file holding only the leaf gives an
  # empty extra_chain_cert and a peer which does not already have the intermediate
  # cached cannot build a path to a trust anchor. Let's Encrypt's intermediate is
  # widely cached, which is what makes this appear to work and then fail for
  # whichever sender lacks it.
  if [[ ${chain:-0} -lt 2 ]]; then
    warn "the chain holds only ${chain:-0} $chain_word; the intermediate is missing"
    warn "  ./deploy.sh tls install   reinstalls the full chain from the client's state"
  fi

  if [[ ! -f $TLS_KEY ]]; then
    fail "$TLS_KEY is missing while the certificate is present"
    fail "  STARTTLS is advertised on a handshake which cannot complete"
    return 0
  fi

  tls_check_key_matches_cert
  tls_check_name_coverage
  tls_check_expiry "$TLS_CERT"

  if service_running smtp; then
    tls_report_live_probe
  else
    info "smtp is not running, so the handshake was not probed"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Verdicts
#
# Each of these prints one token and nothing else. They are separate from the
# reporting below them because two callers want different idioms: `tls status`
# prints and always exits 0, while doctor counts pass/warn/fail and exits
# non-zero on a failure. Sharing the openssl invocations rather than the output is
# what keeps the two from drifting into checking subtly different things.

# How many PEM blocks the certificate file holds. Two or more means the
# intermediate is being presented.
tls_cert_chain_count() {
  local f=$1 n
  [[ -f $f ]] || { printf '0'; return 0; }
  # Captured rather than short-circuited. `grep -c` prints its count and then
  # exits 1 when that count is zero, so `grep -c ... || printf 0` emits both --
  # and a two-line answer reaches the `[[ $count -ge 2 ]]` tests in doctor and in
  # tls status as an arithmetic error rather than as a number.
  n="$(grep -c 'BEGIN CERTIFICATE' "$f" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
  return 0
}

# Whether the private key belongs to the certificate: yes, no, or unparsable.
#
# Compared by public key rather than by modulus, which is RSA-only and would
# report a false mismatch for an ECDSA certificate.
#
# Each side is checked for having parsed before the two are hashed. Piping a
# failed openssl into `openssl sha256` hashes the empty input and succeeds, so
# testing the output for emptiness is not enough: two files which are not a
# certificate and not a key at all produce the same hash and compare equal,
# which reports a match for the one case where there is nothing to match.
tls_key_matches_cert() {
  local a b
  a="$(openssl x509 -in "$TLS_CERT" -noout -pubkey 2>/dev/null)" || a=""
  b="$(openssl pkey -in "$TLS_KEY" -pubout 2>/dev/null)" || b=""
  if [[ -z $a || -z $b ]]; then
    printf 'unparsable'
    return 0
  fi
  a="$(printf '%s' "$a" | openssl sha256 2>/dev/null)" || a=""
  b="$(printf '%s' "$b" | openssl sha256 2>/dev/null)" || b=""
  if [[ -z $a || -z $b ]]; then
    printf 'unparsable'
  elif [[ $a == "$b" ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
  return 0
}

# yes when subject and issuer are the same string, which is what a self-signed
# certificate looks like. script/generate_tls_certificate.rb produces exactly
# that, at exactly the filename this deployment uses, with exactly the permissions
# -- so nothing else here would object to one being left behind.
tls_is_self_signed() {
  local subject issuer
  subject="$(openssl x509 -in "$TLS_CERT" -noout -subject 2>/dev/null | sed 's/^subject=[[:space:]]*//')"
  issuer="$(openssl x509 -in "$TLS_CERT" -noout -issuer 2>/dev/null | sed 's/^issuer=[[:space:]]*//')"
  if [[ -z $subject || -z $issuer ]]; then
    printf 'unknown'
  elif [[ $subject == "$issuer" ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
  return 0
}

# The certificate's issuer as a printable string, for reporting only.
tls_cert_issuer() {
  openssl x509 -in "$TLS_CERT" -noout -issuer 2>/dev/null | sed 's/^issuer=[[:space:]]*//'
  return 0
}

# Expiry in bands rather than against one threshold. 21 days is where action
# becomes worth taking: with a 30-day renewal window, a certificate inside 21 days
# has already failed to renew at least once, and the reason is worth finding
# before it becomes an outage.
#
#   expired | week | three-weeks | ok | unreadable
tls_expiry_verdict() {
  local f=$1
  if ! openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1; then
    if openssl x509 -in "$f" -noout -enddate >/dev/null 2>&1; then
      printf 'expired'
    else
      printf 'unreadable'
    fi
    return 0
  fi
  if ! openssl x509 -in "$f" -noout -checkend $((7 * 86400)) >/dev/null 2>&1; then
    printf 'week'; return 0
  fi
  if ! openssl x509 -in "$f" -noout -checkend $((21 * 86400)) >/dev/null 2>&1; then
    printf 'three-weeks'; return 0
  fi
  printf 'ok'
  return 0
}

# Whether a SAN covers a required name. A literal `*.domain` SAN covers any
# subdomain of domain (the apex itself is normally a separate SAN). Exact match
# covers the name itself.
tls_san_covers() {
  local san=$1 required=$2
  if [[ $san == "$required" ]]; then return 0; fi
  if [[ $san == \*.* ]]; then
    local base="${san#\*.}"
    if [[ $required == "$base" ]]; then return 0; fi
    if [[ $required == *."$base" ]]; then return 0; fi
  fi
  return 1
}

# The required names the certificate does not cover, one per line. Empty output
# means full coverage, or that there was nothing to compare against -- callers
# distinguish those by checking whether the certificate has any SAN at all.
tls_missing_names() {
  local sans n san
  sans="$(tls_cert_sans "$TLS_CERT")"
  if [[ -z $sans ]]; then return 0; fi
  for n in ${TLS_DOMAINS[@]+"${TLS_DOMAINS[@]}"}; do
    local covered=false
    for san in $sans; do
      if tls_san_covers "$san" "$n"; then covered=true; break; fi
    done
    if [[ $covered != true ]]; then printf '%s\n' "$n"; fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# status reporting

tls_check_key_matches_cert() {
  case "$(tls_key_matches_cert)" in
    yes) ok "the private key matches the certificate" ;;
    no)
      fail "the private key does NOT match the certificate"
      fail "  every STARTTLS handshake will fail. ./deploy.sh tls install"
      ;;
    *) warn "the certificate or the key could not be parsed, so they were not compared" ;;
  esac
  return 0
}

tls_check_name_coverage() {
  local sans missing
  sans="$(tls_cert_sans "$TLS_CERT")"
  if [[ -z $sans ]]; then
    warn "the certificate has no Subject Alternative Names"
    warn "  peers match on SAN, not on the subject CN, so nothing will accept it"
    return 0
  fi
  missing="$(tls_missing_names)"
  if [[ -n $missing ]]; then
    fail "the certificate does not cover: $(printf '%s' "$missing" | tr '\n' ' ')"
    fail "  ./deploy.sh tls issue   re-issues for the current name set"
  else
    ok "the certificate covers every required name"
  fi
  return 0
}

tls_check_expiry() {
  local f=$1
  case "$(tls_expiry_verdict "$f")" in
    expired)
      fail "the certificate has EXPIRED"
      fail "  senders which enforce MTA-STS will refuse to deliver here"
      ;;
    week)
      fail "the certificate expires within 7 days"
      fail "  ./deploy.sh tls renew --force"
      ;;
    three-weeks)
      warn "the certificate expires within 21 days, so a renewal has already been missed"
      warn "  ./deploy.sh tls renew --force, then check the timer"
      ;;
    ok) ok "the certificate is valid for more than 21 days" ;;
    *) fail "openssl could not read $f" ;;
  esac
  return 0
}

# Perform a real STARTTLS handshake against the published port and validate the
# presented chain against this host's trust store.
#
# This is the only check which answers the question anyone actually cares about,
# and it earns its place: server.rb rescues OpenSSL::SSL::SSLError during
# negotiation and logs "SSL Negotiation Failed" at debug level, which is off in
# production. A certificate every remote server rejects therefore produces no
# output here at all -- the connections just fail, at the sender.
tls_probe_live() {
  local host=${1:-127.0.0.1} port=${2:-25} sni=${3:-$POSTAL_SMTP_HOSTNAME}
  local out="" rc=0
  local -a run=(openssl s_client -starttls smtp -connect "$host:$port"
                -servername "$sni" -verify_return_error)

  # Bounded, because a port which silently drops packets would otherwise hang the
  # caller for as long as openssl's own defaults allow.
  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout 25 "${run[@]}" </dev/null 2>&1)" || rc=$?
  else
    out="$("${run[@]}" </dev/null 2>&1)" || rc=$?
  fi

  if [[ -z $out ]]; then
    printf 'unreachable'
  elif ! printf '%s' "$out" | grep -q 'BEGIN CERTIFICATE'; then
    printf 'nostarttls'
  else
    local code
    code="$(printf '%s\n' "$out" | sed -n 's/.*Verify return code: //p' | tail -n1)"
    if [[ $rc -eq 0 && $code == "0 (ok)"* ]]; then
      printf 'ok'
    else
      printf 'untrusted|%s' "${code:-unknown, openssl exited $rc}"
    fi
  fi
  return 0
}

tls_report_live_probe() {
  local verdict detail
  verdict="$(tls_probe_live)"
  case $verdict in
    ok)
      ok "a real STARTTLS handshake on port 25 verified against this host's trust store"
      ;;
    nostarttls)
      fail "port 25 completed no TLS handshake and presented no certificate"
      fail "  SMTP_SERVER_TLS_ENABLED is ${SMTP_SERVER_TLS_ENABLED:-false}; if it is"
      fail "  true, the smtp container was not recreated after it was set."
      ;;
    unreachable)
      warn "nothing answered a STARTTLS probe on 127.0.0.1:25"
      ;;
    untrusted\|*)
      detail="${verdict#untrusted|}"
      fail "the presented certificate did not verify: $detail"
      fail "  This is what a remote sender enforcing MTA-STS sees, and it is the"
      fail "  failure the application never reports: server.rb logs a negotiation"
      fail "  error at debug level, which is off in production."
      ;;
    *)
      warn "unrecognised probe result: $verdict"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------

tls_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh tls SUBCOMMAND [options]

A publicly trusted certificate for inbound SMTP, issued by Let's Encrypt with a
DNS-01 challenge answered through the Cloudflare API.

  issue [--staging] [--wildcard DOMAIN]
                      Obtain a certificate covering POSTAL_SMTP_HOSTNAME and
                      every name in DNS_MX_RECORDS, install it into config/ and
                      switch SMTP_SERVER_TLS_ENABLED on. --staging uses the
                      Let's Encrypt test CA: it proves the DNS-01 flow without
                      spending production rate limit, and produces a certificate
                      nobody trusts. --wildcard DOMAIN issues a wildcard for
                      DOMAIN and its apex (e.g. --wildcard example.com issues
                      example.com and *.example.com) using DNS-01.
  renew [--force]     Renew if inside the window set at issue time, then install
                      and recreate the smtp container only if the certificate
                      actually changed. Idempotent, and safe from a timer; exits
                      non-zero only on a real failure.
  install             Re-copy from the client's state directory, fix ownership,
                      switch TLS on and recreate smtp. Use after a chown, or to
                      recover config/ from a backup without re-issuing.
  import CERT KEY     Install an already-obtained certificate (for example a
                      wildcard issued elsewhere) into config/smtp.cert and
                      config/smtp.key, switch TLS on and recreate smtp. Provide
                      a fullchain, leaf first. Imported certificates are not
                      renewed by this tool.
  status              What is installed: subject, issuer, SAN coverage against
                      the names this configuration needs, chain length, days to
                      expiry, whether the key matches, and a real STARTTLS
                      handshake against port 25.

Required in .env
  CLOUDFLARE_DNS_API_TOKEN   An API token with Zone / DNS / Edit on the zone
                             containing the names above, and nothing else. Not
                             the global API key.
  ACME_CONTACT_EMAIL         A real address. Let's Encrypt validates it and
                             rejects reserved domains; it is also the only
                             warning which arrives before a certificate expires.

Renewal has to be driven from the host, because the SMTP server reads its
certificate once at process start and has no reload signal. Install a timer:

  # /etc/systemd/system/postal-tls.service
  [Unit]
  Description=Renew the Postal SMTP certificate
  [Service]
  Type=oneshot
  User=root
  ExecStart=/opt/postal/deploy/deploy.sh tls renew

  # /etc/systemd/system/postal-tls.timer
  [Unit]
  Description=Renew the Postal SMTP certificate twice daily
  [Timer]
  OnCalendar=*-*-* 03,15:20:00
  Persistent=true
  [Install]
  WantedBy=timers.target

Twice daily is Let's Encrypt's own recommendation, not caution: the default 30-day
window on a 90-day certificate is about 60 attempts before expiry, and a renewal
which fails on every one of them is a problem worth noticing well before the
certificate does.

What this does and does not achieve is at the top of lib/tls.sh and in
doc/deployment.md. The short version: inbound mail is opportunistic, so a
self-signed certificate already works for it. A trusted certificate is what
MTA-STS enforcement and mail-client submission require.
USAGE
}
