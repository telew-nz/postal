# Keeping the fork in sync with upstream

This document is the runbook for the **sync/upstream** branch flow. It is the
other side of the `script/upstream-sync.sh` orchestrator and the agent skill in
`.kilo/agent/sync-upstream.md`.

## Why this flow exists

The fork tracks upstream `postalserver/postal` while carrying two things
upstream does not have: the `/api/v2` management API and the `deploy/`
production bundle. A naive `git merge upstream/main` is dangerous for three
reasons:

- **MariaDB has no down migrations.** A bad merge in `db/` is unrecoverable
  without a backup restore.
- **Config defaults are semantic.** Upstream's DKIM key-rate/rotation work
  (`d96eddb`) and the fork's `dns.*` defaults both live in
  `lib/postal/config_schema.rb`. Taking either side silently drops the other.
- **Rollback needs reproducible tags.** The deploy tooling (`deploy.sh
  upgrade`/`rollback`) depends on clean, tagged history. Rebasing `main`
  breaks that.

So: **never rebase `main`.** All sync work happens on `sync/upstream`, and
`main` changes only by merging a reviewed PR.

## The two remotes

| Remote | Points at | Role |
| --- | --- | --- |
| `origin` | your fork | where you push, CI runs |
| `upstream` | `postalserver/postal` | the canonical source |

The orchestrator auto-detects: it uses `upstream` if present, else falls back
to `origin` when it points at `postalserver/postal` (which is the case in the
working copy where this was built).

## At a glance

```
                     upstream/main
                          |
                          v
  main  ─────────────  sync/upstream   (merged, autofixed tier 1/2)
    \                    /
     \── PR (review) ──/
        v
      main  ──(next sync starts here)
```

## Triggering a sync

Automated (recommended):

- Run the **Upstream sync** workflow from the Actions tab
  (`workflow_dispatch`). It fetches upstream, runs `prepare`, pushes
  `sync/upstream`, and opens a PR.
- An optional weekly schedule does the same. Set `cron: ' '` to disable.

Manual, on a Linux host:

```bash
git fetch upstream main
script/upstream-sync.sh status      # what's pending, read-only
script/upstream-sync.sh prepare     # merge upstream into sync/upstream
script/upstream-sync.sh finish      # commit the autofixes
git push origin sync/upstream
```

## Reading the outcomes

`prepare` writes `sync/last-report.json`. The `status` field is one of:

| Status | Meaning | What happens next |
| --- | --- | --- |
| `clean` | no conflicts | PR is opened; merge after CI + review |
| `conflicts` | conflicts, all within tiers 1–2 | autofixed; PR opened with a note |
| `halted` | at least one tier 3 / unclassified conflict | nothing resolved; **draft PR** labelled `sync-halted`; the run fails so it is visible |

The `conflicts` array lists every conflicted path with its tier and the action
the map assigned. `pending_upstream_commits` lists what is being pulled.

## Conflict tiers

The map is `sync/conflict-tiers.conf` (longest-prefix match, `*` catch-all):

| Tier | Meaning | Handled by |
| --- | --- | --- |
| 0 | no conflict | the script |
| 1 | mechanical/cosmetic (changelog, docs, lockfile, our deploy harness) | the script, sanity-checked |
| 2 | additive, separate concerns (our API serializers/controllers/specs) | the script, then **suite + human review** |
| 3 | semantic high-risk (`config_schema.rb`, `db/**`, `config/application.rb`, `Gemfile`, domain/auth models) | **a human**. Never auto-resolved |

**Default is `stop`.** Anything upstream starts touching that is not classified
pauses the sync. Add a rule only when you understand both sides and can name a
safe action.

## When a sync halts (tier 3)

1. Open the draft PR / read `sync/last-report.json`. The halted paths are
   listed.
2. For each, produce the four-part analysis from the skill: what upstream did,
   what the fork did, why they interact, and the ranked options.
3. Resolve on `sync/upstream` by hand, then re-run `prepare` to confirm
   nothing new halts.
4. If a path is genuinely fork-owned (additive `/api/v2` file upstream will
   never touch), you may move it to tier 1 `ours` in the map, with a comment
   explaining why. Do not do this for shared/semantic files.

Known interaction zones to expect:

- `lib/postal/config_schema.rb` — upstream DKIM work vs fork `dns.*` defaults.
  The danger is silent default drift.
- `db/schema.rb`, `db/migrate/**` — never merge by hand; compare the two
  migration sets and let a human order them.
- `config/routes.rb` — upstream routes vs `/api/v2`; watch for namespace
  collisions and the unauthenticated `GET /spec`.
- `app/models/domain.rb`, `app/models/concerns/has_dns_checks.rb` — DKIM/DNS
  semantics, touched by both sides.

## Before merging a sync PR

- CI is green on the sync branch (the full suite, and the OpenAPI contract
  check — the fork's value is its API).
- `git diff --check` is clean; no stray conflict markers.
- For tier 2 autofixes, a human has eyeballed the diff. The PR note says which
  files were auto-resolved.
- No tier 3 path is unresolved. A `sync-halted` draft is never merged as-is.

## Releasing after a sync

Syncs feed releases, they do not replace them. After a sync PR merges into
`main`, cut the next release tag from `main` per the existing release-please
flow (`release-please-config.json`). Keep the deploy tags (`api-v*`) on
known-good merged states — never on an ad-hoc local branch.

## Rollback of a bad sync

- If the sync PR is not yet merged: delete the `sync/upstream` branch, create
  it fresh from `main`, and re-run. Nothing was ever on `main`.
- If the sync PR was merged and caused a problem: the `main` commit is a
  regular merge and can be reverted like any other — but this does **not**
  undo database migrations. If the problem is schema-related, restore from the
  pre-upgrade backup (`deploy.sh backups` / `deploy.sh restore`) rather than
  relying on a revert.

## Never do this

- Force-push to `main`.
- Rebase `main` onto upstream.
- Auto-merge `db/`, `config/application.rb`, or `Gemfile` conflicts.
- Merge a `sync-halted` draft.
- Open a sync PR from a dirty working tree.
