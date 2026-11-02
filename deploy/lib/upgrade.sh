#!/usr/bin/env bash
# ./deploy.sh upgrade | rollback
#
# Both move this checkout to another revision and then rebuild. The deployment
# model is that the host builds from a tag, so the tag is the unit of upgrade and
# of rollback, and the revision currently running is recorded in .upgrade-state so
# that "go back" does not depend on anyone remembering where they came from.
#
# A note on something that looks wrong but is not. `git checkout` rewrites the
# very scripts which are executing. This is safe for two independent reasons, and
# it is worth knowing both before changing this file. Bash parses a complete
# function body before running any of it, so once deploy.sh has sourced lib/*.sh
# every function below is already in memory and the files on disk are irrelevant
# to it. And git replaces a file by writing a temporary one and renaming it over
# the target, so the inode bash holds open is untouched -- verified by watching
# the inode change mid-execution while the script ran on to completion. Rewriting
# a running script in place, with the same inode, does corrupt it.
#
# The phases after the checkout are still delegated to the newly checked out
# deploy.sh as child processes rather than run from the functions in memory. That
# is not about safety but about correctness: the new revision may have changed
# the compose topology, the configuration schema or the migration steps, and it
# is the new revision's tooling which should bring up the new revision's stack.

UPGRADE_STATE="$DEPLOY_DIR/.upgrade-state"

upgrade_cmd() {
  local target="" no_backup=false no_migrate=false

  while (($#)); do
    case $1 in
      --no-backup)  no_backup=true; shift ;;
      --no-migrate) no_migrate=true; shift ;;
      -h|--help)    upgrade_usage; return 0 ;;
      -*)           die "upgrade: unknown option '$1'" ;;
      *)            target=$1; shift ;;
    esac
  done

  require_cmd git
  require_cmd docker
  load_env

  upgrade_require_clean

  if [[ -z $target ]]; then
    upgrade_list_tags
    die "upgrade needs a tag. ./deploy.sh upgrade api-v1.0.1"
  fi

  step "Fetching from origin"
  # --tags rather than a plain fetch: the deployment model is tags, and a plain
  # fetch of a branch does not necessarily bring the one being asked for.
  git -C "$REPO_ROOT" fetch --tags --force origin 2>&1 | sed 's/^/  /' || true

  if ! git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$target" >/dev/null; then
    # Also accept a commit or branch, so that an urgent fix can be deployed from
    # a revision which has not been tagged yet. Recorded as such, because an
    # untagged deployment is one that cannot be reproduced later.
    if git -C "$REPO_ROOT" rev-parse -q --verify "$target^{commit}" >/dev/null; then
      warn "'$target' is not a tag. Deploying from it anyway, but it will not be"
      warn "reproducible later the way a tag is."
    else
      upgrade_list_tags
      die "'$target' is not a tag, branch or commit in this repository"
    fi
  fi

  local from from_desc to_desc
  from="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  from_desc="$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || echo "$from")"
  to_desc="$(git -C "$REPO_ROOT" describe --tags --always "$target" 2>/dev/null || echo "$target")"

  if [[ $from == "$(git -C "$REPO_ROOT" rev-parse "$target^{commit}")" ]]; then
    ok "already at $to_desc, nothing to do"
    log ""
    log "  To rebuild the image from this revision anyway: ./deploy.sh build"
    return 0
  fi

  step "Upgrading ${from_desc} -> ${to_desc}"

  # Taken before anything is changed, so that the archive describes the revision
  # which is currently serving mail rather than the one about to.
  if [[ $no_backup == true ]]; then
    warn "--no-backup given. If the migration below fails there is no way back"
    warn "except the backups you already have."
  else
    log ""
    "$DEPLOY_DIR/deploy.sh" backup --label "pre-upgrade-${to_desc//[^A-Za-z0-9._-]/-}"
  fi

  step "Checking out $target"
  # No --force: the tree was verified clean above, and a forced checkout would
  # discard changes made since that check without saying so.
  if ! git -C "$REPO_ROOT" checkout --quiet "$target"; then
    die "git checkout $target failed. The tree is still at $from_desc."
  fi

  # Recorded before the phases which can fail, so that `./deploy.sh rollback`
  # knows where to go back to even if the build never completes.
  upgrade_write_state "$from" "$from_desc" "$target" "$to_desc"

  # Deliberately detached from this script's own failure handling: each phase is a
  # child process running the new revision's code, and the first one to fail
  # stops the sequence.
  if ! upgrade_phase build; then
    upgrade_failed "$from_desc" "$to_desc" "build"
  fi

  if [[ $no_migrate == true ]]; then
    info "skipping migrations (--no-migrate)"
  elif ! upgrade_phase migrate; then
    upgrade_failed "$from_desc" "$to_desc" "migrate"
  fi

  if ! upgrade_phase up; then
    upgrade_failed "$from_desc" "$to_desc" "up"
  fi

  # The new revision may require variables this installation has never had. Asked
  # after `up` rather than before, because compose has by then already reported
  # any it marks required, and the ones worth surfacing here are the optional ones
  # whose absence is silent.
  upgrade_check_env

  step "Upgraded to $to_desc"
  ok "was $from_desc, recorded in ${UPGRADE_STATE##*/}"
  log ""
  log "  ./deploy.sh doctor     verify the deployment"
  log "  ./deploy.sh rollback   return to $from_desc"
  return 0
}

# Run one phase using the checked out deploy.sh, which is the new revision's.
upgrade_phase() {
  local phase=$1
  log ""
  step "Phase: $phase"
  # The interpreter is named rather than relying on the executable bit, because
  # that bit is not preserved by every way this repository gets onto a host.
  bash "$DEPLOY_DIR/deploy.sh" "$phase"
}

upgrade_failed() {
  local from_desc=$1 to_desc=$2 phase=$3
  log ""
  fail "the '$phase' phase failed. The working tree is at $to_desc."
  log ""
  log "  The stack is still whatever the previous phase left running. To go back:"
  log ""
  log "    ./deploy.sh rollback            # returns to $from_desc"
  log ""
  log "  If a migration was applied before the failure, rolling the code back does"
  log "  not roll the schema back. Restore the pre-upgrade backup instead:"
  log ""
  log "    ./deploy.sh backups"
  log "    ./deploy.sh restore <the pre-upgrade-$to_desc archive>"
  die "upgrade stopped at '$phase'"
}

# Refuse to move revisions with uncommitted changes. Git will happily check out
# over them or refuse part way through, and either outcome leaves an installation
# whose running code no longer corresponds to anything.
upgrade_require_clean() {
  local dirty
  dirty="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | grep -c . || true)"
  if [[ ${dirty:-0} -gt 0 ]]; then
    git -C "$REPO_ROOT" status --short | sed 's/^/    /'
    die "$dirty path(s) differ from HEAD. Commit or stash them first."
  fi
  return 0
}

upgrade_list_tags() {
  log ""
  log "  Tags in this repository, newest first:"
  git -C "$REPO_ROOT" tag --list --sort=-v:refname 2>/dev/null |
    head -n 15 | sed 's/^/    /'
  log ""
  log "  Currently at: $(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || echo unknown)"
  return 0
}

upgrade_write_state() {
  local from=$1 from_desc=$2 to=$3 to_desc=$4
  {
    printf 'from=%s\n' "$from"
    printf 'from_desc=%s\n' "$from_desc"
    printf 'to=%s\n' "$to"
    printf 'to_desc=%s\n' "$to_desc"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$UPGRADE_STATE"
  chmod 600 "$UPGRADE_STATE"
  return 0
}

# A new revision's .env.example may introduce variables this installation has
# never had. Compose reports the ones it marks `:?` loudly; the rest are silent,
# and a silently absent optional value is how an installation ends up running
# with a schema default nobody chose.
upgrade_check_env() {
  [[ -f $ENV_EXAMPLE && -f $ENV_FILE ]] || return 0

  local missing
  missing="$(comm -23 \
    <(sed -n 's/^\([A-Z0-9_][A-Z0-9_]*\)=.*/\1/p' "$ENV_EXAMPLE" | sort -u) \
    <(sed -n 's/^\([A-Z0-9_][A-Z0-9_]*\)=.*/\1/p' "$ENV_FILE" | sort -u))"

  if [[ -n ${missing// /} ]]; then
    log ""
    warn "the new revision's .env.example defines variables .env does not have:"
    while read -r v; do
      [[ -n $v ]] || continue
      warn "  $v"
    done <<<"$missing"
    warn "Review them and add any that apply. ./deploy.sh init fills in the"
    warn "secrets among them without touching existing values."
  fi
  return 0
}

upgrade_usage() {
  cat <<'USAGE'
Usage: ./deploy.sh upgrade TAG [--no-backup] [--no-migrate]

Moves this checkout to TAG, then builds, migrates and restarts using the newly
checked out deploy.sh. Takes a backup labelled pre-upgrade first.

With no TAG, lists the tags available and stops: a mail server should not be
moved to an unspecified "latest".

  --no-backup     Skip the pre-upgrade backup.
  --no-migrate    Build and restart without migrating. Use when the target is
                  known not to contain migrations.

Usage: ./deploy.sh rollback [TAG] [--no-build]

Returns to the revision recorded by the last upgrade, or to TAG if given, and
restarts. Does not migrate, and therefore does not undo any migration the
upgrade applied -- MariaDB has no down migrations. If the upgrade did migrate and
the new schema is the problem, restore the pre-upgrade backup instead:

    ./deploy.sh backups
    ./deploy.sh restore <archive>

  --no-build   Reuse the image already tagged for that revision. Only correct if
               it was built before, which POSTAL_IMAGE_TAG is what makes possible.
USAGE
}

# ---------------------------------------------------------------------------

rollback_cmd() {
  local target="" no_build=false

  while (($#)); do
    case $1 in
      --no-build) no_build=true; shift ;;
      -h|--help)  upgrade_usage; return 0 ;;
      -*)         die "rollback: unknown option '$1'" ;;
      *)          target=$1; shift ;;
    esac
  done

  require_cmd git
  require_cmd docker
  load_env

  local from_desc=""
  if [[ -z $target ]]; then
    [[ -f $UPGRADE_STATE ]] ||
      die "no ${UPGRADE_STATE##*/} and no tag given. ./deploy.sh rollback api-v1.0.0"
    # Read with sed rather than sourced: the file is written by this script, but
    # sourcing anything from a state file is a habit worth not having.
    target="$(sed -n 's/^from=//p' "$UPGRADE_STATE" | tail -n1)"
    from_desc="$(sed -n 's/^from_desc=//p' "$UPGRADE_STATE" | tail -n1)"
    [[ -n $target ]] || die "$UPGRADE_STATE has no 'from=' line"
  fi

  upgrade_require_clean

  local current
  current="$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || echo unknown)"

  if ! git -C "$REPO_ROOT" rev-parse -q --verify "$target^{commit}" >/dev/null; then
    die "'$target' is not a known revision. git fetch --tags may be needed."
  fi

  step "Rolling back ${current} -> ${from_desc:-$target}"

  warn "This does not undo any migration the upgrade applied. If the schema is"
  warn "the problem, ./deploy.sh restore the pre-upgrade backup instead."

  git -C "$REPO_ROOT" checkout --quiet "$target" ||
    die "git checkout $target failed. Still at $current."

  # The state file now describes the upgrade that is being undone. Removed rather
  # than rewritten, so that a second `rollback` with no argument asks for a tag
  # instead of appearing to go back somewhere it already went.
  rm -f "$UPGRADE_STATE"

  if [[ $no_build == true ]]; then
    info "--no-build given, reusing the existing image"
    if ! upgrade_phase up; then
      upgrade_failed "$current" "$target" "up"
    fi
  else
    if ! upgrade_phase build; then
      upgrade_failed "$current" "$target" "build"
    fi
    if ! upgrade_phase up; then
      upgrade_failed "$current" "$target" "up"
    fi
  fi

  step "Rolled back to $(git -C "$REPO_ROOT" describe --tags --always)"
  log ""
  log "  ./deploy.sh doctor   verify the deployment"
  return 0
}
