# Skill: upstream sync conflict resolution

You are the agent that keeps the Postal fork aligned with upstream
(`postalserver/postal`) without breaking the fork's `/api/v2` extension and
deployment topology. Load this skill whenever a sync halts (tier 3 / `stop`
conflicts) or a human asks you to drive the sync flow.

## When to use

- The CI workflow `upstream-sync` opened a draft PR labelled `sync-halted`.
- A human says "sync with upstream", "resolve the merge", or "there are
  conflicts with upstream".
- You are asked to review a `sync/upstream` PR before it merges into `main`.

## The non-negotiable rules

These are hard guardrails. Breaking any of them is a production incident:

1. **Never touch `main` directly.** Sync work happens only on the
   `sync/upstream` branch. `main` is changed only by merging a reviewed PR.
2. **Never rewrite history.** No rebase of `main` or of the sync branch, no
   `push --force` to `main`, no amending pushed commits. Rollback for the
   deploy tooling depends on tags and on stable history.
3. **Never auto-resolve a tier 3 conflict.** If a path is tier 3 in
   `sync/conflict-tiers.conf` (or unclassified), you stop and produce a
   report. "Both sides" is not a valid resolution there.
4. **Never merge a schema or migration conflict by hand.** `db/schema.rb` and
   `db/migrate/**` → MariaDB has no down migrations. A bad merge is
   unrecoverable without a backup restore; if you are unsure, stop and ask.
5. **Never change config/application.rb host allowlisting in a way that
   widens `config.hosts`** beyond what the deployment intends.
6. **After any resolution, you must be able to prove the tree is coherent**:
   run the suite and the smoke harness, and confirm `deploy.sh doctor` would
   pass (or at minimum that you have not touched deploy/ semantics).

## The tier model

| Tier | Meaning | Action |
| --- | --- | --- |
| 0 | No conflict | nothing to do |
| 1 | Mechanical/cosmetic | auto-resolve per map, sanity-check the file |
| 2 | Additive; separate concerns | auto-resolve per map, gate on full suite + human review |
| 3 | Semantic high-risk | STOP. Report to a human. Never auto-resolve |

The map lives in `sync/conflict-tiers.conf`. Longest-prefix match wins; `*`
defaults to `stop`. Auto-resolution is an explicit allowlist — anything
unclassified pauses for review.

## Driving the flow

Read-only first, always:

```bash
script/upstream-sync.sh status      # what upstream has that we don't
script/upstream-sync.sh prepare     # merge upstream into sync/upstream, autofix tier 1/2
script/upstream-sync.sh report      # structured JSON of what happened
```

If `prepare` returns 0, the sync is safe: run `finish`, push, and open a PR.

If `prepare` halts (exit non-zero), read `sync/last-report.json`. The
`conflicts` array names each path, its tier, and the action the map assigned.
Then work the list in this order:

1. **Confirm each conflicted path's tier.** Re-check the map. The report's
   tier is authoritative for what the *script* may do, but your job is the
   ones it won't touch.
2. **For tier 1/2 paths** — resolve them with the map's action, then verify:
   - `ours`/`theirs`: inspect the file; ensure the chosen side is coherent and
     that no half-merged state remains.
   - `union` (docs/changelog only): run `git diff --check` for stray markers.
3. **For tier 3 paths** — do NOT resolve them yourself. For each, produce a
   short "both sides" analysis (what upstream changed, what the fork changed,
   why they interact) and the safe options. Then either:
   - If a path is clearly fork-owned (e.g. an additive `/api/v2` file upstream
     will never touch), move it to tier 1 `ours` in the map with a comment,
     and re-run — but only when you are sure upstream's change is irrelevant.
   - Otherwise leave it for a human. Do not guess.

## Resolution playbook (tier 3 analysis)

For each halted conflict, write a one-paragraph report capturing:

- **Path** and which side owns it (upstream, fork, or shared).
- **What upstream did** (commit + intent).
- **What the fork did** (and why — usually the API extension or deployment).
- **Why they interact** (shared schema, shared config default, shared file).
- **Options**, ranked: take upstream, take fork, or a specific merge of both.
- **Your recommendation**, with the reasoning a human needs to approve it.

Classic conflict zones in this fork:

- `lib/postal/config_schema.rb` — upstream moved DKIM key-size/rotation
  (`d96eddb`); the fork depends on the `dns.*` defaults. The risk is silent
  default drift, not a textual clash alone.
- `db/schema.rb` / `db/migrate/**` — never merge by hand; compare the two
  migration sets and let a human order them.
- `config/routes.rb` — upstream adds routes; the fork adds `/api/v2`. Look for
  route namespace collisions and for the unauthenticated `GET /spec` decision.
- `app/models/domain.rb`, `app/models/concerns/has_dns_checks.rb` — DKIM and
  DNS-check semantics; the fork and upstream have both changed these.

## Verification you must run before handing back

- `git diff --check` on the sync branch.
- `git diff main...sync/upstream --stat` to reveal scope.
- The test suite / smoke harness (use `script/test/run.ps1` on Windows, or the
  container harness on Linux) — at least the API specs and the OpenAPI contract
  check, since the fork's value is its API.
- If deploy/ touched: confirm `deploy.sh doctor` logic is intact by reading the
  affected shell, not by running it blindly.

## Output contract

When you finish, report:

1. The sync branch state (what merged, what was auto-resolved, what halted).
2. For each tier 3 path: the four-part analysis above.
3. Your recommendation and what, if anything, needs human approval.
4. The verification you actually ran and its result.

Never claim a sync is "done" while a tier 3 conflict is unresolved or while
verification has not run.
