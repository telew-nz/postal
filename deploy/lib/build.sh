#!/usr/bin/env bash
# ./deploy.sh build -- build the application image from this checkout.
#
# Uses the upstream Dockerfile's `full` target. Dockerfile.production is not
# involved: its whole purpose is to undo CRLF damage in a Windows working tree,
# and its own header says that on a Linux checkout the normalization is a no-op
# which makes it equivalent to `--target full`. Building through it here would
# add a stage that exists only to fix a problem this host does not have.

build_cmd() {
  local allow_dirty=false
  local no_cache=false

  while (($#)); do
    case $1 in
      --allow-dirty) allow_dirty=true; shift ;;
      --no-cache)    no_cache=true; shift ;;
      -h|--help)     build_usage; return 0 ;;
      *)             die "build: unknown option '$1'" ;;
    esac
  done

  require_cmd docker
  require_cmd git

  load_env
  need_env POSTAL_IMAGE

  local version branch commit
  version="$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || echo unknown)"
  branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

  build_check_clean "$allow_dirty"

  step "Building $POSTAL_IMAGE from $commit"
  info "version=$version branch=$branch"

  # --target full is the default, and stated anyway: the alternative target `ci`
  # skips asset compilation, and an image built with it serves a web UI with no
  # stylesheet. That is a silent difference rather than an error, so the target
  # is worth spelling out at the point where it is chosen.
  local -a args=(
    build
    --target full
    --build-arg "VERSION=$version"
    --build-arg "BRANCH=$branch"
    -t "$POSTAL_IMAGE"
  )
  [[ $no_cache == true ]] && args+=(--no-cache)

  docker "${args[@]}" "$REPO_ROOT"

  # A second, versioned tag. This is what makes `./deploy.sh rollback` have
  # something to roll back to: POSTAL_IMAGE is the mutable name the compose file
  # references, and without a versioned tag alongside it every build destroys the
  # previous image's only reference.
  if [[ -n ${POSTAL_IMAGE_TAG:-} ]]; then
    docker tag "$POSTAL_IMAGE" "$POSTAL_IMAGE_TAG"
    ok "also tagged $POSTAL_IMAGE_TAG"
  fi

  local id size
  id="$(docker image inspect "$POSTAL_IMAGE" --format '{{.Id}}' 2>/dev/null | cut -c8-19)"
  size="$(docker image inspect "$POSTAL_IMAGE" --format '{{.Size}}' 2>/dev/null)"
  ok "built $POSTAL_IMAGE (${id:-?}, $(( ${size:-0} / 1048576 )) MB)"

  # Recorded against the image, so that `docker images` answers the question an
  # operator will otherwise have to ask git: which revision is actually running.
  docker image inspect "$POSTAL_IMAGE" --format '{{.Id}}' >/dev/null 2>&1 &&
    info "revision $commit is in the image as VERSION=$version"

  return 0
}

build_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh build [--no-cache] [--allow-dirty]

Builds the Postal image from the current checkout using the upstream Dockerfile's
`full` target, tagged as POSTAL_IMAGE from .env.

  --no-cache      Ignore cached layers. Slow, but the only way to be sure a
                  change to a COPYied file was picked up.
  --allow-dirty   Build even though the working tree has uncommitted changes.
USAGE
}

# An image built from an uncommitted tree cannot be identified afterwards: there
# is no revision to check out, nothing to roll back to, and no way to tell two
# builds of the same tag apart. That is the exact situation this deployment
# tooling exists to avoid, so it is refused by default rather than warned about.
build_check_clean() {
  local allow=$1
  local dirty

  dirty="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | grep -c . || true)"

  [[ $dirty -eq 0 ]] && { ok "working tree is clean"; return 0; }

  warn "$dirty path(s) differ from HEAD."
  if [[ $allow == true ]]; then
    warn "--allow-dirty given, building anyway. The image will not correspond to"
    warn "any commit, so it cannot be reproduced or rolled back to."
    return 0
  fi

  log ""
  log "  Commit them, or re-run with --allow-dirty to build anyway:"
  log "    git status --short"
  log "    ./deploy.sh build --allow-dirty"
  die "refusing to build an unidentifiable image"
}
