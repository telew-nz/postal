#!/usr/bin/env bash
# Shared helpers for deploy.sh. Not executable on its own.
#
# Sourced after deploy.sh has already set -euo pipefail, so nothing here needs
# to repeat it.

# Absolute path to this directory, and to the repository root above it. Resolved
# rather than assumed, because deploy.sh has to work from any working directory:
# a systemd unit, a CI job and a human at a shell will each be somewhere
# different, and every relative path below -- the compose file, ./config, the
# Dockerfile build context -- depends on getting this right.
DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd -- "$DEPLOY_DIR/.." && pwd)"

COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yml"
COMPOSE_DEBUG_FILE="$DEPLOY_DIR/docker-compose.debug.yml"
ENV_FILE="${POSTAL_ENV_FILE:-$DEPLOY_DIR/.env}"
ENV_EXAMPLE="$DEPLOY_DIR/.env.example"
CONFIG_DIR="$DEPLOY_DIR/config"
DB_INIT_DIR="$DEPLOY_DIR/database/init"
SIGNING_KEY="$CONFIG_DIR/signing.key"
BACKUP_DEFAULT_DIR="$DEPLOY_DIR/backups"

# Passed to compose as --project-name rather than left to be derived from the
# directory name, which is compose's default. The checkout location is not part of
# this installation's identity: without a fixed name, checking out at
# /srv/postal instead of /opt/postal silently changes the volume names, and the
# stack comes up healthy and empty because the database it just created is not
# the one that was there before.
COMPOSE_PROJECT="${POSTAL_COMPOSE_PROJECT:-postal}"

# The image's unprivileged user. Dockerfile creates it with an explicit uid, and
# files the container has to read -- the DKIM signing key above all -- need to be
# readable by it.
POSTAL_UID=999

# Set by load_env. Kept as a global because the worker profile choice has to be
# made before compose is invoked, and reading it out of the environment twice
# invites the two reads to disagree.
WORKER_PROFILE=""

# Set by `up --without-tunnel` and honoured by compose below. Empty means the
# tunnel profile is activated, which is the normal case.
NO_TUNNEL=""

# ---------------------------------------------------------------------------
# Output

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""
fi

log()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$C_BOLD$*$C_RESET"; }
ok()   { printf '  %sok%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '  %s--%s   %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn() { printf '  %swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# Print an error and stop. Used for anything the operator has to fix by hand, so
# that the message is the last thing on screen rather than being buried above a
# stack trace.
die() {
  printf '\n%sdeploy.sh:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 ||
    die "$1 is required but was not found on PATH."
}

# ---------------------------------------------------------------------------
# Environment

# Load .env into the shell. Compose reads the same file on its own, from the
# project directory, so this is for the parts deploy.sh itself has to decide --
# which worker profile to activate, which image tag to build.
load_env() {
  [[ -f $ENV_FILE ]] ||
    die "no .env in $DEPLOY_DIR. Run ./deploy.sh init first."

  # `set -a` exports everything the file assigns, so child processes -- compose
  # included -- see the same values this script does.
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  # The worker profile is the one decision here which cannot be left to compose.
  # Both variants exist in the file and exactly one may run; if neither profile
  # were activated the stack would come up healthy with no process draining
  # queued_messages, and mail would simply accumulate with nothing to indicate
  # why.
  if [[ ${POSTAL_USE_IP_POOLS:-false} == "true" ]]; then
    WORKER_PROFILE="worker-hostnet"
  else
    WORKER_PROFILE="worker-bridge"
  fi
}

# Fail unless a variable is set and non-empty. Compose does the same with its
# `:?` syntax, but that reports the failure only once compose is invoked, which
# for the setup steps is several database operations later.
need_env() {
  local missing=()
  local v
  for v in "$@"; do
    [[ -n ${!v:-} ]] || missing+=("$v")
  done
  if ((${#missing[@]})); then
    die "missing required value(s) in .env: ${missing[*]}"
  fi
}

# Generate a value suitable for a secret.
random_hex() {
  openssl rand -hex "${1:-32}"
}

# Read a value from .env without loading the whole file into the environment.
# Used by init, which has to work before .env is complete.
env_get() {
  [[ -f $ENV_FILE ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}

# Set or replace a value in .env, preserving everything else and the file's
# comments. Written with LF endings: a stray carriage return ends up inside the
# value on some shells, which is invisible and then breaks authentication.
env_set() {
  local key=$1 value=$2 tmp
  tmp="$(mktemp)"
  if [[ -f $ENV_FILE ]] && grep -q "^${key}=" "$ENV_FILE"; then
    sed "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" >"$tmp"
  else
    cat "$ENV_FILE" >"$tmp" 2>/dev/null || : >"$tmp"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  printf '%s' "$(cat "$tmp")" >"$ENV_FILE"
  printf '\n' >>"$ENV_FILE"
  rm -f "$tmp"
  chmod 600 "$ENV_FILE"
}

# ---------------------------------------------------------------------------
# Compose

# Every compose invocation goes through here so that the file, the project
# directory and the worker profile are consistent. Building the argument list in
# one place is what stops `up` and `ps` from disagreeing about which services
# exist -- a disagreement which shows up as a container that looks orphaned.
compose() {
  local -a args=(
    -f "$COMPOSE_FILE"
    --project-name "$COMPOSE_PROJECT"
    --project-directory "$DEPLOY_DIR"
  )

  # Both profiles are passed explicitly rather than left to COMPOSE_PROFILES in
  # the environment. The alternative is a stack whose shape depends on how it was
  # invoked, and a worker that is absent because a profile was not set produces no
  # error at all: mail simply accumulates in queued_messages.
  if [[ -n $WORKER_PROFILE ]]; then
    args+=(--profile "$WORKER_PROFILE")
  fi
  if [[ -z $NO_TUNNEL ]]; then
    args+=(--profile tunnel)
  fi

  [[ -n ${DEPLOY_DEBUG:-} ]] && args+=(-f "$COMPOSE_DEBUG_FILE")
  docker compose "${args[@]}" "$@"
}

# Compose including the one-shot setup profile.
compose_setup() {
  compose --profile setup "$@"
}

# Run a one-shot command in the bootstrap container. Used for migrations, the
# rails runner calls, and anything else that needs the application's own
# environment rather than a shell on the host.
#
# --no-deps is deliberately absent. bootstrap depends_on mariadb with
# condition: service_healthy, so compose starts the database and waits for it,
# which is what every command here needs: a migration run against an absent
# database fails with a connection error that reads like a schema problem.
#
# -T disables pseudo-TTY allocation, because the marker lines these commands
# print have to be captured and parsed. A TTY interleaves them with progress
# output and adds carriage returns to the captured text.
run_bootstrap() {
  compose_setup run --rm -T bootstrap "$@"
}

# Forward variables from the shell environment into the bootstrap container.
# Compose only passes what the service definition lists, and the setup steps need
# values which are secrets -- the administrator password above all -- so they live
# in .env and are named explicitly at the call site rather than in the compose
# file, which is committed.
#
#   bootstrap_run POSTAL_ADMIN_EMAIL POSTAL_ADMIN_PASSWORD -- \
#     bundle exec rails runner /deploy-lib/ensure_admin.rb
bootstrap_run() {
  local -a envs=()
  while (($#)) && [[ $1 != "--" ]]; do
    envs+=(-e "$1")
    shift
  done
  # Consume the -- separator, if one was given.
  if (($#)); then shift; fi
  # The `${arr[@]+...}` form is not decoration: a bare "${envs[@]}" on an empty
  # array is an unbound variable error under `set -u` before bash 4.4, and a
  # deployment tool should not depend on which bash the host happens to have.
  compose_setup run --rm -T ${envs[@]+"${envs[@]}"} bootstrap "$@"
}

# True when the given compose service has a running container.
service_running() {
  local state
  state="$(compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -c . || true)"
  [[ $state -gt 0 ]] || return 1
  compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx "$1"
}

# The container name of a running service, so that `docker exec` can be used
# without compose. Compose run/exec would also work but re-resolves the project
# on every call, which is slow in a loop and obscures which container answered.
container_of() {
  compose ps --status running --format '{{.ID}} {{.Service}}' 2>/dev/null |
    awk -v want="$1" '$2 == want { print $1; exit }'
}

# ---------------------------------------------------------------------------
# Parsing the marker lines
#
# The ruby helpers in this directory print one JSON object prefixed with a
# marker, which keeps the result separable from the Rails log output that
# surrounds it. These extract scalars from it.
#
# Deliberately not a JSON parser: jq is not a prerequisite anyone should have to
# install to deploy a mail server, and every value extracted here is a flat
# scalar produced by a script in this directory, so its shape is known. Nothing
# here addresses a nested object, and the helpers are written so that no nested
# key collides with a scalar one.

# A string field: "key":"value". Empty for null and for absent keys.
json_get() {
  local json=$1 key=$2
  printf '%s' "$json" | sed -n "s/.*\"${key}\":\"\([^\"]*\)\".*/\1/p" | head -n1
}

# A non-string field: number, true, false or null. The value keeps its quotes if
# it is a string, so prefer json_get for those.
json_get_raw() {
  local json=$1 key=$2
  printf '%s' "$json" | sed -n "s/.*\"${key}\":\([^,}]*\).*/\1/p" | head -n1
}

# The marker line itself, from output which also contains Rails logging.
marker_line() {
  local marker=$1
  sed -n "s/^.*${marker} //p" | tail -n1
}

# Every line carrying a marker, in order. Used by doctor, which reports a list of
# facts rather than one result.
#
# The trailing space in the pattern is what makes the prefixes unambiguous:
# `marker_lines POSTAL_DOCTOR` does not match a POSTAL_DOCTOR_IP line, because
# there the marker is followed by an underscore rather than a space.
marker_lines() {
  local marker=$1
  sed -n "s/^.*${marker} //p"
}

# ---------------------------------------------------------------------------
# The pinned network

# The subnet of the compose network, from its ipam block. It is named in three
# places which have to agree: here, postal.trusted_proxies, and the address
# cloudflared is given. A drift between the first two is invisible until
# request.ip starts recording the tunnel's address instead of the client's, so
# both `up` and `doctor` compare them -- and they read them through these two
# functions so that the comparison is the same comparison.
compose_subnet() {
  sed -n 's/^[[:space:]]*- subnet:[[:space:]]*//p' "$COMPOSE_FILE" | head -n1
}

# The first entry of postal.trusted_proxies, read from the committed YAML rather
# than from a running container, because `up` needs it before anything exists.
# Parsed with awk rather than a sed range because a range would also pick up any
# other `- ` item that happens to follow.
config_trusted_proxy() {
  awk '
    /^  trusted_proxies:/      { want = 1; next }
    want && /^[^[:space:]]/    { exit }
    want && /^[[:space:]]*-/   { sub(/^[[:space:]]*-[[:space:]]*/, ""); print; exit }
  ' "$CONFIG_DIR/postal.yml"
}

# ---------------------------------------------------------------------------
# API

# Base URL for the management API. Defaults to the public hostname, which is the
# path a real client takes and therefore the one worth testing: it exercises the
# tunnel, HostAuthorization and trusted_proxies as well as the application.
# Override to probe the origin directly while diagnosing.
api_base_url() {
  if [[ -n ${POSTAL_API_BASE_URL:-} ]]; then
    printf '%s' "$POSTAL_API_BASE_URL"
  else
    printf 'https://%s' "${POSTAL_WEB_HOSTNAME:?POSTAL_WEB_HOSTNAME is not set}"
  fi
}

# Call the API. The body goes to stdout; the status code lands in API_STATUS so
# that a caller can distinguish 401 MissingAPIKey from 401 InvalidAPIKey by
# reading the body without losing the code.
#
#   api_request GET /api/v2/me
#   api_request POST /api/v2/tokens "$json_body"
API_STATUS=0
api_request() {
  local method=$1 path=$2 body=${3:-}
  local token=${POSTAL_API_TOKEN:-}
  local -a args=(-sS -o /dev/stdout -w '\n%{http_code}' -X "$method"
                 -H 'Accept: application/json' --max-time 30)

  # The header is X-Postal-API-Key. `Authorization: Bearer` is not accepted: it
  # is not read at all, and a request carrying only that header is answered 401
  # MissingAPIKey rather than InvalidAPIKey.
  [[ -n $token ]] && args+=(-H "X-Postal-API-Key: $token")

  if [[ -n $body ]]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi

  local out
  # `|| true` because curl exits non-zero on 4xx with --fail, and on any HTTP
  # error without it; here a 401 is a result to report, not a failure to abort on.
  out="$(curl "${args[@]}" "$(api_base_url)$path" 2>/dev/null || true)"
  API_STATUS="$(printf '%s' "$out" | tail -n1)"
  printf '%s' "$out" | sed '$d'
}

# ---------------------------------------------------------------------------
# Preflight

# Fail unless the application image exists locally. Every command except `build`
# needs it, and the failure compose produces without this check is
# "failed to resolve reference ... not found", which does not say that the fix is
# to run ./deploy.sh build first.
require_image() {
  local image=${1:-${POSTAL_IMAGE:-postal:local}}
  docker image inspect "$image" >/dev/null 2>&1 && return 0
  die "image '$image' is not present. Run ./deploy.sh build first."
}

# Fail unless the signing key is readable by the container's uid. The DKIM key is
# the one file whose permissions are load-bearing and whose failure is silent:
# ./config is mounted read-only, the container runs as uid 999, and a key it
# cannot read produces mail which is delivered but does not verify -- visible
# only to the recipient's mail server.
require_signing_key() {
  [[ -f $SIGNING_KEY ]] ||
    die "$SIGNING_KEY is missing. Run ./deploy.sh init first."

  if [[ $(id -u) -ne 0 ]] && ! stat -c '%u' "$SIGNING_KEY" 2>/dev/null | grep -qx "$POSTAL_UID"; then
    warn "$SIGNING_KEY is not owned by uid $POSTAL_UID, which the container runs as."
    warn "DKIM signing will fail until it is:  sudo chown $POSTAL_UID:$POSTAL_UID $SIGNING_KEY"
  fi
}
