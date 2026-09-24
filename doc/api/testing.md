# Testing the management API

The management API is covered by four layers of testing. Each one can fail while
the others pass, and the combination of which layers fail is what tells you where
the bug is, so they are described here in terms of the question each one answers
rather than in terms of how it works.

| Layer | Command | Question it answers |
| --- | --- | --- |
| RSpec + RuboCop | `./script/test/run.ps1` | Does the Ruby behave correctly, in process? |
| Smoke + contract | `./script/smoke/run.ps1` | Does a real server answer every endpoint in the shape its own document promises? |
| Production harness | `./script/production/run.ps1` | Does the deployed artifact work end to end, and does the API touch the same data the web UI does? |

Everything on this page is contributor tooling. None of it is the deployment
path, and all of it assumes a Windows checkout with PowerShell 7 — the scripts
run the Ruby suites inside containers precisely because they cannot run natively
there. To deploy Postal with this API, see [deployment.md](../deployment.md).

## RSpec and RuboCop

```
./script/test/run.ps1                 # both suites
./script/test/run.ps1 -RSpecOnly      # one suite, skipping the image build
./script/test/run.ps1 -SkipBuild
```

`spec/apis/` holds request specs for every API controller. These run in process
against the test database and are the fastest feedback available, but they never
open a socket: a routing mistake, a serialization difference between
development and production, or a misconfigured deployment will not show up here.

On Windows `bundle exec rspec` does not work at all — there is no MSYS2 toolchain
for the native gem extensions — so the script runs both suites inside the CI
image, on the CI compose network, against a MariaDB it starts and stops itself.
The working tree is mounted read-only and copied into the container; the copy is
what gets its line endings normalized, because doing that in place through a
Windows bind mount rewrites host files. `script/test/container.sh` explains the
two traps this avoids.

Four examples in `spec/lib/dns_resolver_spec.rb` perform live reverse DNS
lookups and fail wherever the container cannot resolve a PTR record. Those
failures are environmental, not regressions, and the script says so when RSpec
is the suite that failed.

## Smoke and contract validation

```
./script/smoke/run.ps1
```

Builds a throwaway stack from `docker-compose.smoke.yml`, boots Puma in
production mode against a real MariaDB, seeds an organization, a server and an
API token, then runs two stages against it:

* **smoke** — `script/smoke/run.rb` walks every endpoint group through the full
  create/read/update/delete lifecycle and the error paths, asserting the *content*
  of each response and recording the traffic.
* **contract** — Schemathesis fuzzes the documented GET operations looking for
  server errors and schema violations, then `script/smoke/validate_contract.py`
  replays everything the smoke stage recorded against `doc/api/openapi.yaml`.

The two stages disagree in a useful way. When smoke passes and contract fails,
the API behaves correctly and the document describing it is wrong. When both fail
on the same endpoint, the API is wrong. Neither stage aborts the run, so both
diagnoses are available at once.

The stack is destroyed at the end. Pass `-Keep` to leave it running.

## The production harness

```
./script/production/run.ps1
```

This is the layer to run before believing the API is ready to be used. It works
against `docker-compose.production.yml`: a persistent stack, in production mode,
with a real DKIM signing key, published on `127.0.0.1:5000` (web) and
`127.0.0.1:2525` (SMTP). Nothing is destroyed between runs, so the data you
create by hand survives and can be inspected in the web UI.

The word "production" in those filenames describes the Rails environment the
stack boots in, not its purpose. This is a local test rig: it binds to loopback,
runs MariaDB as `root`, has no TLS, and leaves every `dns.*` key on its
`postal.example.com` default. The real deployment topology is a separate file,
[`deploy/docker-compose.yml`](../../deploy/docker-compose.yml), and the two are
deliberately not shared — changing this one to suit a deployment would break a
verified test suite for no benefit.

Four stages run in order:

### bootstrap

`bootstrap.ps1` writes the configuration the stack needs if it is missing,
builds the image, brings up MariaDB and Puma, loads the schema, and creates an
administrator, an organization, a server, one message and an API token. It is
idempotent: on a stack which already exists it finds all of that again and leaves
it alone.

Three files are written, all listed in `.gitignore`:

| File | Contents |
| --- | --- |
| `.env` | `RAILS_SECRET_KEY`, the MariaDB root password, the administrator password |
| `config/postal.yml` | behavioural configuration, mounted into the containers at `/config` |
| `config/signing.key` | a 2048 bit RSA key used for DKIM signing |

`config/postal.yml` and `config/signing.key` are also in `.dockerignore`, because
the signing key is a secret and must not be baked into an image layer.

Everything the run needs afterwards is recorded in
`tmp/production/credentials.json`. **The plain API token appears in that file
only on the run which created it** — only its SHA-256 digest is stored in the
database, so it cannot be recovered later. If the file is lost, revoke the token
through the API and re-run with `-NewToken`.

This is the one stage whose failure stops the run: with no server, no schema and
no token there is nothing for the other three to talk to.

### tokens

`token-lifecycle.ps1` follows one concept — the API token — through everything
that can happen to it: creation, the single opportunity to read the plain key,
first use, `last_used_at` bookkeeping, expiry (valid, malformed and already
elapsed), revocation, and the four ways a request can be rejected.

Token handling gets its own stage because it is the part of the API where a
mistake is a security hole rather than a broken response. Every token it creates
is revoked again before it exits, including when an assertion fails, so a partial
run does not leave working credentials behind. The bootstrap token is used to
authenticate but is never revoked.

### sweep

`api-sweep.ps1` reads the OpenAPI document the server is *actually serving* at
`/api/v2/spec` — not the one in the repository — and walks every operation in it
over real HTTP from outside the container.

Being driven by the deployed document is the point. An operation added to
`doc/api/openapi.yaml` appears here on the next run with no edit to the script,
and the coverage report at the end names any operation which was not reached.
That figure is the one to watch: a documented operation which the sweep cannot
reach is either a routing bug or a document that describes something which does
not exist.

To give the member operations something to address, the sweep first creates a
sandbox organization and server and populates them with one of each kind of
resource. The bootstrap organization, server and message are only ever read from.

Pass `-ReadOnly` against an installation whose data matters.

### crosscheck

`crosscheck.ps1` drives a real Chromium with Playwright and compares the two
surfaces against the same data. The first three stages can all pass while the API
reads and writes somewhere other than the place the web UI uses — an endpoint can
return 200 and a plausible body while addressing the wrong scope — and this is
the only stage which can catch that.

It works in three directions:

* **API → UI** — create through the API, find it in the web UI.
* **UI → API** — create through a real web UI form, find it through the API.
* **deletion** — remove through one surface, confirm the other stops reporting it.

The sharpest checks are the credential ones. The web UI prints the credential key
in clear text, the API member endpoint returns it, and the API collection
endpoint deliberately omits it: all three have to agree, which pins down both the
value and the redaction. The message stage compares the plain text body byte for
byte, and every header and attachment as a set.

Failures leave a full page screenshot in `tmp/production/crosscheck/`. That
directory is cleared at the start of each run, because a screenshot is evidence
of a specific failure and a stale one is worse than none.

## Requirements

* Docker with the Compose plugin
* PowerShell 7
* `curl` and `jq` on `PATH`
* `openssl` on `PATH` (for the DKIM signing key)
* Node, plus a globally installed Playwright, for the crosscheck stage only:

```
npm install -g playwright
npx playwright install chromium
```

If Playwright is not resolvable the crosscheck stage is reported as **skipped**
rather than failed. A missing browser says nothing about the API, and counting it
as a failure would make the harness unusable anywhere Node is not set up.

## Useful invocations

```powershell
# Everything, from a standing start.
./script/production/run.ps1

# Re-run just the tests against the stack which is already up.
./script/production/run.ps1 -SkipBootstrap -SkipBuild

# Watch the browser and keep the sandboxes afterwards.
./script/production/run.ps1 -SkipBootstrap -Headed -Keep

# Read only, against data which matters.
./script/production/run.ps1 -SkipBootstrap -ReadOnly

# Remove residue left by an interrupted run.
./script/production/run.ps1 -SkipBootstrap -Cleanup
```

Each stage's output is written to `tmp/production/logs/<stage>.log` and
overwritten by the next run. The script exits non-zero if any stage failed, and
names the failures in a summary at the end.

Individual stages can be run on their own — `bootstrap.ps1`,
`token-lifecycle.ps1`, `api-sweep.ps1`, `crosscheck.ps1` and `cleanup.ps1` are
each usable independently, and each has comment based help:

```powershell
Get-Help ./script/production/api-sweep.ps1 -Detailed
```

## Cleaning up and resetting

Every test script removes what it creates. `cleanup.ps1` exists for the run which
did not finish, and removes anything whose permalink starts with `sweep-`,
`lifecycle-` or `xcheck-`. The bootstrap organization and its token are never
touched. Run it with `-WhatIf` first if the installation holds data you care
about.

Residue matters because `Organization#soft_destroy` keeps the row, and therefore
keeps its globally unique permalink taken: a leftover sandbox makes the next run
fail with "Short name has already been taken".

```powershell
./script/production/bootstrap.ps1 -Down    # stop, keep the data
./script/production/bootstrap.ps1 -Reset   # stop and delete the MariaDB volume
```

## Two configuration traps

Both of these fail silently, and both were found by this harness rather than by
reading the code.

**`config/postal.yml` must contain `version: 2`.** Without that key,
`Postal::Config` treats the file as the legacy v1 format and reads it through
`LegacyConfigSource`, which maps v1 names — `web.protocol`,
`general.use_ip_pools`, `web_server.bind_address` — onto the current schema.
None of the v2 names appear in that mapping, so every one of them is ignored: the
defaults apply and nothing reports an error. The symptom is a stack which starts
cleanly and behaves as though it had no configuration file at all.

**The Rails secret key environment variable is `RAILS_SECRET_KEY`, not
`SECRET_KEY_BASE`.** `config/initializers/secret_key.rb` reads
`Postal::Config.rails.secret_key` and falls back to `SecureRandom.hex(128)` with
a warning when it is nil. Passing `SECRET_KEY_BASE` instead therefore appears to
work while giving every container a different random key, which invalidates every
session cookie on each restart. See
[environment-variables.md](../config/environment-variables.md).

A related one worth knowing about: `Postal::Config.postal.web_protocol` has to be
`http` when there is no TLS terminator in front of the stack. Every remote form
in the web UI is answered with `{redirect_to: ...}`, which
`redirect_to_with_json` builds with `url_for`, so an `https` protocol here makes
every form in the UI redirect to a URL the server cannot answer.

## Security

The stack is published on `127.0.0.1` only and there is no TLS in front of it.
`.env` holds the administrator password, the MariaDB root password and the Rails
secret key, and `config/signing.key` holds a private DKIM key. None of these may
be committed, copied into an image layer, or exposed to a network. This harness
is for testing an API, not for running a mail server.
