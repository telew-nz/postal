#!/usr/bin/env bash
# master-standup.sh -- stand up the full stack from a fresh checkout.
#
# Runs the known-good deployment sequence end to end: prechecks, init,
# Cloudflare provisioning, build, migrate, up, admin, doctor.
#
# --cold additionally performs a clean-slate precheck before anything runs: it
# detects and removes any existing postal containers and volumes (including the
# MariaDB volume), so the stack starts genuinely fresh. It does not delete the
# checkout or .env.
#
# Prerequisites:
#   - /opt/postal exists (run master-destroy.sh, or clone, first).
#   - /opt/postal/deploy/.env is seeded with at least the site values and
#     CLOUDFLARE_API_TOKEN (the Cloudflare key). init fills the remaining
#     secrets; cloudflare keys copies the unified key to the DNS field.
#
# Usage (as root):
#   sudo bash master-standup.sh                      # as-is
#   sudo bash master-standup.sh --domain example.com # derive dns.* names
#   sudo bash master-standup.sh --cold --yes         # remove stale containers/volumes, no prompt
#
# Env overrides: POSTAL_REPO_DIR.

set -euo pipefail

REPO_DIR="${POSTAL_REPO_DIR:-/opt/postal}"
DEPLOY="$REPO_DIR/deploy"
DOMAIN=""
COLD=false
YES=false

usage() {
  cat <<EOF
Usage: master-standup.sh [--domain example.com] [--cold] [--yes]

  --domain example.com  Derive the dns.* names from this domain (passed to init).
  --cold                Precheck and remove stale postal containers/volumes before
                        bringing the stack up fresh.
  --yes                 Skip the confirmation prompt for --cold.
EOF
}

die() { echo "error: $*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --domain) DOMAIN=${2:?--domain needs a value}; shift 2 ;;
    --cold)   COLD=true; shift ;;
    --yes)    YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root (sudo)"

precheck_tools() {
  local missing=()
  command -v docker    >/dev/null 2>&1 || missing+=(docker)
  command -v git       >/dev/null 2>&1 || missing+=(git)
  command -v openssl   >/dev/null 2>&1 || missing+=(openssl)
  command -v curl      >/dev/null 2>&1 || missing+=(curl)
  if ((${#missing[@]})); then die "missing tools: ${missing[*]}"; fi
  docker info >/dev/null 2>&1 || die "docker daemon is not running"
  echo "  tools ok (docker, git, openssl, curl); daemon up"
}

precheck_cold() {
  echo "==> Cold-start prechecks"
  local -a ctr=() vols=()
  local v

  # Pull the compose project down first, including its volumes. This is what
  # removes the volume in the common case, so the manual sweeps below are only
  # for things the compose project did not own.
  if [[ -d $DEPLOY ]]; then
    ( cd "$DEPLOY" && docker compose down -v --remove-orphans 2>/dev/null || true )
  fi

  # Re-detect what remains after the compose project is gone.
  mapfile -t ctr < <(docker ps -aq -f name=postal 2>/dev/null || true)
  while IFS= read -r v; do [[ -n $v ]] && vols+=("$v"); done \
    < <(docker volume ls -q 2>/dev/null | grep '^postal_' || true)

  if [[ ${#ctr[@]} -eq 0 && ${#vols[@]} -eq 0 ]]; then
    echo "  clean: no postal containers or volumes present."
    return 0
  fi

  echo "  found ${#ctr[@]} container(s): ${ctr[*]:-none}"
  echo "  found ${#vols[@]} volume(s):   ${vols[*]:-none}"

  if [[ $YES != true ]]; then
    printf 'Remove them and cold-start? [y/N] '
    read -r ans
    [[ $ans == y || $ans == Y ]] || die "aborted"
  fi

  # Tolerant removals: anything already gone is not an error.
  if ((${#ctr[@]})); then
    docker rm -f "${ctr[@]}" >/dev/null 2>&1 || true
    echo "  removed ${#ctr[@]} container(s)"
  fi
  if ((${#vols[@]})); then
    docker volume rm "${vols[@]}" >/dev/null 2>&1 || true
    echo "  removed ${#vols[@]} volume(s)"
  fi
}

[[ -d $DEPLOY ]] || die "$DEPLOY not found; run master-destroy.sh (or clone) first"
cd "$DEPLOY"
[[ -f .env ]] || die ".env is missing in $DEPLOY. Seed it with the site values and CLOUDFLARE_API_TOKEN, then re-run."

precheck_tools
if [[ $COLD == true ]]; then
  precheck_cold
fi

run() {
  echo
  echo "==> $*"
  "$@"
}

if [[ -n $DOMAIN ]]; then
  run ./deploy.sh init --domain "$DOMAIN" \
    || die "init reported missing values; edit .env and re-run"
else
  run ./deploy.sh init \
    || die "init reported missing values; edit .env and re-run"
fi

# Copy the unified API token into the DNS key field so tls can use the same key.
run ./deploy.sh cloudflare keys || true

# Build first (the image is needed by the bootstrap container for the DKIM
# derivation inside provision), then migrate (which starts and health-checks
# mariadb), then provision so it can resolve the DKIM record and write the
# tunnel token before up.
run ./deploy.sh build
run ./deploy.sh migrate
run ./deploy.sh cloudflare provision
run ./deploy.sh up
run ./deploy.sh admin
run ./deploy.sh doctor

echo
echo "standup complete."
echo "Domains that need records: run ./deploy.sh dns and ./deploy.sh cloudflare zone add <client>"
