#!/usr/bin/env bash
# Command dispatch. Sourced by deploy.sh along with everything else, so that the
# whole of it is parsed into memory before any of it runs.
#
# main ends with `exit` rather than `return`. That is deliberate and it is the
# other half of what makes `./deploy.sh upgrade` safe: with main exiting from
# inside a function, bash never has to read another byte of deploy.sh after the
# point where a `git checkout` may have replaced it.

main() {
  local cmd=${1:-help}
  if (($#)); then shift; fi

  local status=0

  # No `|| status=$?` on the esac below. It reads as if it only catches the
  # unknown command, but a case statement on the left of || suspends errexit for
  # all of it, so every command in the dispatch ran with set -e disabled: `up`
  # printed "Next: ./deploy.sh admin" over an unhealthy container and exited 0,
  # and `doctor` printed eleven failures and exited 0 despite doctor_summary
  # returning 1 and its own usage promising it can gate a release. die was
  # unaffected because it exits rather than returns, which is why this survived
  # review. A failing command now propagates; the exit carries only the
  # unknown-command status, which is set by assignment and so never trips.
  case $cmd in
    # Setup
    init)      init_cmd "$@" ;;
    build)     build_cmd "$@" ;;
    migrate)   migrate_cmd "$@" ;;
    admin)     admin_cmd "$@" ;;
    ip)        ip_cmd "$@" ;;

    # Lifecycle
    up)        up_cmd "$@" ;;
    down)      down_cmd "$@" ;;
    restart)   restart_cmd "$@" ;;
    ps)        ps_cmd "$@" ;;
    logs)      logs_cmd "$@" ;;
    exec)      exec_cmd "$@" ;;
    status)    status_cmd "$@" ;;

    # Verification and reporting
    dns)       dns_cmd "$@" ;;
    cloudflare) cf_cmd "$@" ;;
    tls)       tls_cmd "$@" ;;
    doctor)    doctor_cmd "$@" ;;
    onboard)   onboard_cmd "$@" ;;
    teardown)  teardown_cmd "$@" ;;
    mta-sts)  mta_sts_cmd "$@" ;;
    rspamd)    rspamd_cmd "$@" ;;

    # Data
    backup)    backup_cmd "$@" ;;
    backups)   backups_cmd "$@" ;;
    restore)   restore_cmd "$@" ;;

    # Releases
    upgrade)   upgrade_cmd "$@" ;;
    rollback)  rollback_cmd "$@" ;;

    # Destructive, and therefore not in the group above
    reset)     reset_cmd "$@" ;;

    version)   main_version ;;
    help|-h|--help) main_usage ;;

    *)
      printf 'deploy.sh: unknown command "%s"\n\n' "$cmd" >&2
      main_usage >&2
      status=2
      ;;
  esac

  exit "$status"
}

main_version() {
  local rev=""
  if command -v git >/dev/null 2>&1; then
    rev="$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || true)"
  fi
  log "Postal deployment tooling"
  log "  checkout  ${rev:-unknown}"
  log "  image     ${POSTAL_IMAGE:-unset (run ./deploy.sh init)}"
  log "  project   $COMPOSE_PROJECT"
  return 0
}

main_usage() {
  cat <<USAGE
./deploy.sh -- deploy and operate this Postal installation

Usage: ./deploy.sh COMMAND [options]

Setup, in the order a new installation needs them
  init [--domain example.com]   Create .env, generate the secrets and the DKIM
                                signing key, render the database grants.
  build                         Build the image from this checkout.
  migrate                       Create the schema and migrate every message
                                database.
  up                            Start the stack and wait for it to be healthy.
  admin                         Create the administrator and the first API token.
  dns                           Print every DNS record to publish.
  cloudflare provision|dns|tunnel|status
                                Provision the Cloudflare DNS records and the
                                tunnel and the web hostname route via the API.
  tls issue|renew|status        A Let's Encrypt certificate for inbound SMTP,
                                validated by DNS-01 through the Cloudflare API.
  onboard --domain client.com    Automate the full client-onboarding flow and
                                print the delivered API key.
  teardown --domain client.com   Cleanly remove the domain, its Cloudflare DNS
                                records, and optionally the server/org.
  mta-sts                       Write the MTA-STS policy and enable it.
  rspamd                        Enable rspamd and render per-domain spam rules.
  doctor                        Verify the deployment by observing it.

Operating
  down | restart | ps | logs | exec | status
  backup [--label NAME]         Archive the databases, config/ and .env.
  backups                       List the archives.
  restore FILE                  Load one back.
  upgrade TAG                   Move to TAG, then build, migrate and restart.
  rollback [TAG]                Return to the revision the last upgrade left.
  reset                         Delete the stack and its database volume.

Run \`./deploy.sh COMMAND --help\` for any command's own options.

The full runbook, including the Cloudflare Tunnel setup, the security posture and
the deliverability requirements, is in doc/deployment.md.
USAGE
  return 0
}
