#!/usr/bin/env bash
# master-standup.sh -- stand up the full stack from a fresh checkout.
#
# Runs the known-good deployment sequence end to end: init, Cloudflare
# provisioning, build, migrate, up, admin, doctor.
#
# Prerequisites:
#   - /opt/postal exists (run master-destroy.sh, or clone, first).
#   - /opt/postal/deploy/.env is seeded with at least the site values and
#     CLOUDFLARE_API_TOKEN (the Cloudflare key). init fills the remaining
#     secrets; cloudflare keys copies the unified key to the DNS field.
#
# Usage (as root):
#   sudo bash master-standup.sh                    # use .env as-is
#   sudo bash master-standup.sh --domain example.com  # derive dns.* names
#
# Env overrides: POSTAL_REPO_DIR.

set -euo pipefail

REPO_DIR="${POSTAL_REPO_DIR:-/opt/postal}"
DEPLOY="$REPO_DIR/deploy"
DOMAIN=""

while (($#)); do
  case $1 in
    --domain) DOMAIN=${2:?--domain needs a value}; shift 2 ;;
    -h|--help)
      echo "Usage: master-standup.sh [--domain example.com]"
      echo "Brings up the full stack from a seeded /opt/postal/deploy/.env."
      exit 0 ;;
    *) echo "master-standup: unknown option '$1'" >&2; exit 2 ;;
  esac
done

[[ -d $DEPLOY ]] || { echo "$DEPLOY not found; run master-destroy.sh (or clone) first" >&2; exit 1; }
cd "$DEPLOY"
[[ -f .env ]] || { echo ".env is missing in $DEPLOY." >&2; echo "Seed it with the site values and CLOUDFLARE_API_TOKEN, then re-run." >&2; exit 1; }

run() {
  echo
  echo "==> $*"
  "$@"
}

if [[ -n $DOMAIN ]]; then
  run ./deploy.sh init --domain "$DOMAIN" \
    || { echo "init reported missing values; edit .env and re-run" >&2; exit 1; }
else
  run ./deploy.sh init \
    || { echo "init reported missing values; edit .env and re-run" >&2; exit 1; }
fi

# Copy the unified API token into the DNS key field so tls can use the same key.
run ./deploy.sh cloudflare keys || true

# DNS records + tunnel + web hostname. This also writes the real connector
# token to CLOUDFLARE_TUNNEL_TOKEN.
run ./deploy.sh cloudflare provision

run ./deploy.sh build
run ./deploy.sh migrate
run ./deploy.sh up
run ./deploy.sh admin
run ./deploy.sh doctor

echo
echo "standup complete."
echo "Domains that need records: run ./deploy.sh dns and ./deploy.sh cloudflare zone add <client>"
