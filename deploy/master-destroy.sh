#!/usr/bin/env bash
# master-destroy.sh -- tear the deployment down completely and re-clone the
# latest revision. Destructive: stops the stack, removes the containers and the
# MariaDB volume, deletes /opt/postal, then clones it fresh.
#
# Usage (as root):
#   sudo bash master-destroy.sh               # latest api-v* tag
#   sudo bash master-destroy.sh --ref api-v1.5.2
#   sudo bash master-destroy.sh --yes         # skip the typed confirmation
#
# Env overrides: POSTAL_REPO_DIR, POSTAL_REPO_URL.

set -euo pipefail

REPO_DIR="${POSTAL_REPO_DIR:-/opt/postal}"
CLONE_URL="${POSTAL_REPO_URL:-https://github.com/telew-nz/postal.git}"
REF=""
YES=false

while (($#)); do
  case $1 in
    --ref)  REF=${2:?--ref needs a value}; shift 2 ;;
    --yes)  YES=true; shift ;;
    -h|--help)
      echo "Usage: master-destroy.sh [--ref REF] [--yes]"
      echo "Destroys the stack, removes $REPO_DIR, and re-clones $CLONE_URL at"
      echo "REF (default: latest api-v* tag)."
      exit 0 ;;
    *) echo "master-destroy: unknown option '$1'" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }

if [[ -d $REPO_DIR ]]; then
  if [[ $YES != true ]]; then
    printf 'This destroys the stack AND deletes %s. Type "yes" (or the hostname) to continue: ' "$REPO_DIR"
    read -r ans
    [[ $ans == yes || $ans == "$(hostname)" ]] || { echo "aborted." >&2; exit 1; }
  fi

  # Stop and remove the stack from the checkout, if it is still there.
  if [[ -d $REPO_DIR/deploy ]]; then
    ( cd "$REPO_DIR/deploy" && ./deploy.sh down 2>/dev/null || true )
    ( cd "$REPO_DIR/deploy" && docker compose down -v --remove-orphans 2>/dev/null || true )
  fi

  # Remove any remaining postal containers.
  docker rm -f $(docker ps -aq -f name=postal) 2>/dev/null || true

  # Remove the postal data volume and any other postal_* volumes.
  docker volume rm postal_postal-data 2>/dev/null || true
  for v in $(docker volume ls -q | grep '^postal_' || true); do
    docker volume rm "$v" 2>/dev/null || true
  done

  # Leave the directory first so the running copy of this script is not the
  # thing being deleted.
  cd /
  rm -rf "$REPO_DIR"
  echo "destroyed $REPO_DIR"
fi

echo "cloning $CLONE_URL -> $REPO_DIR"
git clone "$CLONE_URL" "$REPO_DIR"
cd "$REPO_DIR"

if [[ -n $REF ]]; then
  git checkout "$REF"
else
  git fetch --tags 2>/dev/null || true
  local_tag="$(git tag -l 'api-v*' | sort -V | tail -n1)"
  if [[ -n $local_tag ]]; then
    git checkout "$local_tag"
  else
    git checkout main
  fi
fi

echo "checkout: $(git describe --tags --always)"
echo "next: sudo bash $REPO_DIR/deploy/master-standup.sh"
