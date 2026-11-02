#!/usr/bin/env bash
#
# Builds and opens/updates the upstream-sync PR from the orchestrator's report.
# Kept out of the workflow YAML so the quoting and heredoc handling live in a
# file that can be exercised directly.
#
# Usage:
#   script/upstream-sync-pr.sh <clean|conflicts|halted> <branch> <report> <human>
#
# Requires `gh` authenticated (the workflow passes GH_TOKEN). Best-effort:
# if PR creation fails because one exists, it edits the existing PR instead.

set -euo pipefail

STATUS=${1:-}
BRANCH=${2:-sync/upstream}
REPORT=${3:-sync/last-report.json}
HUMAN=${4:-false}

if [ -z "$STATUS" ]; then
  echo "usage: upstream-sync-pr.sh <clean|conflicts|halted> <branch> <report> <human>" >&2
  exit 1
fi
if [ ! -f "$REPORT" ]; then
  echo "error: report not found: $REPORT" >&2
  exit 1
fi

BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT

if [ "$STATUS" = halted ]; then
  {
    echo "**Upstream sync HALTED - tier 3 / unclassified conflicts.**"
    echo ""
    echo "The orchestrator refused to auto-resolve these. Handle them on"
    echo "$BRANCH per doc/upstream-sync.md, then re-run prepare."
    echo ""
  } > "$BODY"
  head -60 "$REPORT" >> "$BODY"
  gh pr create \
    --base main \
    --head "$BRANCH" \
    --draft \
    --title "sync: HALTED - needs manual resolution" \
    --body-file "$BODY" \
    2>/dev/null || true
else
  {
    echo "Automated upstream sync via script/upstream-sync.sh."
    echo ""
    echo "**Status:** $STATUS"
    echo "**Requires human:** $HUMAN"
    echo ""
    echo "Report snapshot:"
  } > "$BODY"
  sed -n '1,40p' "$REPORT" >> "$BODY"
  {
    echo ""
    echo "> This PR is generated. Merge it only after CI is green and a human"
    echo "> has reviewed the diff. Tier 3 conflicts never arrive here: if this"
    echo "> PR exists, the sync was safe to merge."
  } >> "$BODY"
  gh pr create \
    --base main \
    --head "$BRANCH" \
    --title "chore(sync): merge upstream into $BRANCH" \
    --body-file "$BODY" \
    2>/dev/null || gh pr edit \
    --body-file "$BODY" \
    2>/dev/null || true
fi
