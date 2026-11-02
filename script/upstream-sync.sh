#!/usr/bin/env bash
#
# Upstream sync orchestrator for the Postal fork.
#
# Runs the `sync/upstream` branch flow: fetch upstream, merge it into a ded
#icated sync branch, classify any conflicts by the tier map in
# sync/conflict-tiers.conf, auto-resolve only what is safe, and emit a
# structured report. It never touches `main` and never rewrites history.
#
# This is the machine half of the flow. The human half is the skill in
# .kilo/agent/sync-upstream.md and the runbook in doc/upstream-sync.md.
#
# Usage:
#   script/upstream-sync.sh status    # read-only: what upstream has, conflicts
#   script/upstream-sync.sh prepare   # merge upstream into sync branch, autofix
#   script/upstream-sync.sh finish    # commit autofixes on the sync branch
#   script/upstream-sync.sh report    # print the last report JSON
#
# Environment / flags:
#   UPSTREAM_REMOTE   remote to treat as upstream (default: `upstream`, else
#                     `origin` if it points at postalserver/postal)
#   SYNC_BRANCH      branch to sync onto (default: sync/upstream)
#   FORK_MAIN        the fork's integration branch (default: main)
#   --no-autofix     never apply tier 1/2 actions; only report
#   --yes            on `finish`, commit without prompting

set -euo pipefail

# Resolve paths relative to the repository root, not the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

TIER_MAP="sync/conflict-tiers.conf"
REPORT_FILE="sync/last-report.json"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }

# Best-effort JSON string escaping. The report is consumed by CI and by humans;
# it does not need to be valid for arbitrary binary data, only for the strings
# git hands us.
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

require_git_tree() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a git repository"
  # The report file is written by this tool itself and is not a reason to
  # refuse a run; everything else counts as a dirty tree.
  local dirty
  dirty=$(git status --porcelain | grep -v 'sync/last-report.json' || true)
  if [ -n "$dirty" ]; then
    die "working tree is dirty; sync requires a clean tree (stash or commit first)"
  fi
}

resolve_remote() {
  if [ -z "${UPSTREAM_REMOTE:-}" ]; then
    if git remote get-url upstream >/dev/null 2>&1; then
      UPSTREAM_REMOTE=upstream
    elif git remote get-url origin | grep -qi 'postalserver/postal'; then
      UPSTREAM_REMOTE=origin
    else
      die "no upstream remote; set UPSTREAM_REMOTE or add one (git remote add upstream https://github.com/postalserver/postal.git)"
    fi
  fi
  git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 \
    || die "remote '$UPSTREAM_REMOTE' does not exist"
  echo "$UPSTREAM_REMOTE"
}

# ---------------------------------------------------------------------------
# Tier map lookup
# ---------------------------------------------------------------------------

# Look up the tier + action for a path. Longest-prefix match over path
# components; `*` is the catch-all. Emits "tier action", both defaulted.
# Returns 0 if the matched rule implies auto-resolution is allowed, 1 if the
# rule is `stop` (or no rule matched the catch-all).
tier_for() {
  local path=$1 tier=2 action=stop best_len=0
  while IFS= read -r line; do
    case "$line" in
      '#'*|'') continue ;;
    esac
    local glob t a
    read -r glob t a <<< "$line"
    [ -n "$t" ] || continue
    case "$glob" in
      '*')
        # Catch-all: matches everything, but only used when no more-specific
        # literal rule has matched (lowest priority regardless of line order).
        if [ "$best_len" -eq 0 ]; then
          tier=$t; action=${a:-stop}
        fi
        ;;
      *)
        # Prefix match on components: the rule matches if the path starts with
        # the glob's leading literal directory (before any ** or *).
        local prefix="${glob%%\**}"
        prefix="${prefix%%\*}"
        prefix="${prefix%/}"
        if [ -n "$prefix" ] && { [ "$path" = "$prefix" ] || [[ "$path" == "$prefix/"* ]]; }; then
          local len=${#prefix}
          if [ "$len" -gt "$best_len" ]; then
            best_len=$len; tier=$t; action=${a:-stop}
          fi
        fi
        ;;
    esac
  done < "$TIER_MAP"
  echo "$tier $action"
  if [ "$action" = stop ] || [ "$tier" = 3 ]; then return 1; else return 0; fi
}

# ---------------------------------------------------------------------------
# Conflict classification and auto-resolution
# ---------------------------------------------------------------------------

classify_conflicts() {
  # For each conflicted path, print:  path<TAB>tier<TAB>action
  local path tier action
  git diff --name-only --diff-filter=U | while IFS= read -r path; do
    read -r tier action <<< "$(tier_for "$path")"
    printf '%s\t%s\t%s\n' "$path" "$tier" "$action"
  done
}

autofix() {
  # Resolve every conflict the tier map allows. Returns 0 if all conflicted
  # paths were resolved, 1 if any remains (tier 3 or `stop`).
  local unresolved=0 path tier action
  while IFS=$'\t' read -r path tier action; do
    [ -n "$path" ] || continue
    case "$action" in
      ours)
        git checkout --ours -- "$path"
        git add -- "$path"
        echo "autofix: ours     $path (tier $tier)"

        ;;
      theirs)
        git checkout --theirs -- "$path"
        git add -- "$path"
        echo "autofix: theirs   $path (tier $tier)"

        ;;
      union)
        case "$path" in
          *.md|*.txt|*.html|*.yml|*.yaml|*.conf)
            # Append upstream's side after a separator. Valid for prose and
            # list-style files only; a non-text file is downgraded to a stop.
            git show ":2:$path" > "$path.ours" 2>/dev/null || true
            git show ":3:$path" > "$path.theirs" 2>/dev/null || true
            if [ -s "$path.ours" ] || [ -s "$path.theirs" ]; then
              cat "$path.ours" > "$path"
              printf '\n--- merged from upstream ---\n' >> "$path"
              cat "$path.theirs" >> "$path"
              rm -f "$path.ours" "$path.theirs"
              git add -- "$path"
              echo "autofix: union    $path (tier $tier)"
            else
              echo "manual:   union-invalid $path"
              unresolved=1
            fi
            ;;
          *)
            echo "manual:   union-not-text $path"
            unresolved=1
            ;;
        esac
        ;;
      *)
        echo "manual:   $path (tier $tier)"
        unresolved=1
        ;;
    esac
  done <<< "$(classify_conflicts)"
  [ "$unresolved" = 0 ]
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

emit_report() {
  # $1 = upstream remote, $2 = upstream ref, $3 = status (clean|conflicts|halted),
  # $4 = requires_human (true/false)
  local remote=$1 ref=$2 status=$3 halted=${4:-false}
  local fork_head upstream_head
  fork_head=$(git rev-parse --short "${FORK_MAIN:-main}" 2>/dev/null || echo unknown)
  upstream_head=$(git rev-parse --short "$remote/$ref" 2>/dev/null || echo unknown)

  local pending="[]"
  if git rev-parse --verify "$remote/$ref" >/dev/null 2>&1; then
    pending=$(git log --oneline --no-decorate "${SYNC_BRANCH:-sync/upstream}..$remote/$ref" \
      | sed 's/^/    "/; s/$/",/' | tr -d '\n')
    pending="${pending%,}"; pending="[$pending]"
  fi

  # Conflict summary: one flat JSON object per conflicted path.
  local conflicts="[]" item first_items=true
  while IFS=$'\t' read -r path tier action; do
    [ -n "$path" ] || continue
    item="{\"path\":\"$(json_escape "$path")\",\"tier\":\"$tier\",\"action\":\"$(json_escape "$action")\"}"
    if [ "$first_items" = true ]; then
      conflicts="[$item]"; first_items=false
    else
      conflicts="${conflicts%]},$item]"
    fi
  done <<< "$(classify_conflicts)"

  {
    echo "{"
    echo "  \"status\": \"$(json_escape "$status")\","
    echo "  \"upstream_remote\": \"$(json_escape "$remote")\","
    echo "  \"upstream_ref\": \"$(json_escape "$ref")\","
    echo "  \"upstream_head\": \"$(json_escape "$upstream_head")\","
    echo "  \"fork_head\": \"$(json_escape "$fork_head")\","
    echo "  \"sync_branch\": \"$(json_escape "${SYNC_BRANCH:-sync/upstream}")\","
    echo "  \"pending_upstream_commits\": $pending,"
    echo "  \"conflicts\": $conflicts,"
    echo "  \"requires_human\": $halted"
    echo "}"
  } > "$REPORT_FILE"
  cat "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_status() {
  local remote ref
  remote=$(resolve_remote)
  ref=${UPSTREAM_REF:-main}
  require_git_tree
  git fetch "$remote" "$ref"
  echo "upstream:   $remote/$ref"
  echo "sync branch: ${SYNC_BRANCH:-sync/upstream} (base: ${FORK_MAIN:-main})"
  echo ""
  echo "pending upstream commits:"
  if git rev-parse --verify "${SYNC_BRANCH:-sync/upstream}" >/dev/null 2>&1; then
    git log --oneline --no-decorate "${SYNC_BRANCH:-sync/upstream}..$remote/$ref" || true
  else
    git log --oneline --no-decorate "${FORK_MAIN:-main}..$remote/$ref" || true
  fi
}

cmd_prepare() {
  local remote ref base
  remote=$(resolve_remote)
  ref=${UPSTREAM_REF:-main}
  base=${FORK_MAIN:-main}
  require_git_tree

  git fetch "$remote" "$ref"

  # Ensure the sync branch exists and is based on the fork's integration branch.
  if ! git rev-parse --verify "${SYNC_BRANCH:-sync/upstream}" >/dev/null 2>&1; then
    git switch -c "${SYNC_BRANCH:-sync/upstream}" "$base" || die "could not create ${SYNC_BRANCH:-sync/upstream} from $base"
  else
    git switch "${SYNC_BRANCH:-sync/upstream}" || die "could not switch to ${SYNC_BRANCH:-sync/upstream}"
  fi

  # Merge upstream. A clean merge (tier 0) is the happy path.
  if git merge --no-edit "$remote/$ref" >/dev/null 2>&1; then
    emit_report "$remote" "$ref" clean false
    echo ""
    echo "sync clean: $remote/$ref merged into ${SYNC_BRANCH:-sync/upstream}."
    echo "next: script/upstream-sync.sh finish, then open a PR."
    return 0
  fi
  echo "merge produced conflicts; classifying by tier map..."

  if [ "${NO_AUTOFIX:-0}" = 1 ]; then
    echo "autofix disabled by --no-autofix."
    emit_report "$remote" "$ref" conflicts true
    return 1
  fi

  if autofix; then
    emit_report "$remote" "$ref" conflicts false
    echo ""
    echo "all conflicts within allowed tiers are resolved on ${SYNC_BRANCH:-sync/upstream}."
    echo "next: script/upstream-sync.sh finish, then a human reviews the suite + PR."
  else
    emit_report "$remote" "$ref" halted true
    echo ""
    echo "sync HALTED: one or more conflicts are tier 3 / unclassified and were NOT touched."
    echo "resolve them by hand on ${SYNC_BRANCH:-sync/upstream}, or see doc/upstream-sync.md."
    return 1
  fi
}

cmd_finish() {
  local branch
  branch=${SYNC_BRANCH:-sync/upstream}
  require_git_tree || true
  git switch "$branch" || die "not on $branch"

  # Refuse to commit unresolved conflicts.
  if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
    die "unresolved conflicts remain; resolve them first"
  fi
  if [ -z "$(git status --porcelain)" ]; then
    echo "nothing to commit; the sync branch is already clean."
    return 0
  fi

  if [ "${YES:-0}" != 1 ]; then
    read -r -p "Commit autofixes on $branch? [y/N] " ans || true
    case "$ans" in
      y|Y) ;;
      *) echo "aborted."; return 1 ;;
    esac
  fi

  git add -A
  git commit -m "chore(sync): merge upstream into $branch [auto]
 
Applied tier 1/2 autofixes from the conflict map. See sync/last-report.json
and the upstream-sync skill for what was merged and what needs review." || \
    echo "nothing to commit; already clean."
}

cmd_report() {
  [ -f "$REPORT_FILE" ] || die "no report yet; run prepare first"
  cat "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

COMMAND=${1:-status}
shift || true

NO_AUTOFIX=0
YES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-autofix) NO_AUTOFIX=1 ;;
    --yes) YES=1 ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

case "$COMMAND" in
  status)   cmd_status ;;
  prepare)  cmd_prepare ;;
  finish)   cmd_finish ;;
  report)   cmd_report ;;
  *) die "unknown command: $COMMAND (expected status|prepare|finish|report)" ;;
esac
