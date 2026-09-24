# deploy/

The production deployment for Postal with the `/api/v2` management API.

**The runbook is [`doc/deployment.md`](../doc/deployment.md).** It covers
prerequisites, the Cloudflare Tunnel setup, DNS and deliverability, the security
posture, backup, upgrade and rollback, and the failure modes worth knowing about
before they happen.

## The short version

```bash
cd /opt/postal/deploy

./deploy.sh init --domain example.com   # .env, secrets, DKIM key, database grants
./deploy.sh build                       # the image, from this checkout
./deploy.sh migrate                     # the schema
./deploy.sh up                          # the stack, waiting for healthy
./deploy.sh admin                       # the administrator and the first API token
./deploy.sh dns                         # every record to publish
./deploy.sh doctor                      # assert it, rather than assume it
```

`./deploy.sh help` lists everything; `./deploy.sh COMMAND --help` gives a command's
own options.

## What is in here

| Path | Contents |
| --- | --- |
| `deploy.sh` | The dispatcher. Sources `lib/*.sh` in full, then routes. |
| `docker-compose.yml` | The topology. |
| `docker-compose.debug.yml` | Diagnostics override: publishes the origin on `127.0.0.1:5000`. |
| `config/postal.yml` | Committed production configuration. Site-independent; every value that differs per installation arrives as an environment variable. |
| `.env.example` | Every variable, with no real values and a note on where each comes from. `init` copies it to `.env`. |
| `cloudflared/config.yml` | Reference ingress for a *locally-managed* tunnel. Not read by default. |
| `lib/*.sh` | One file per command group. |
| `lib/*.rb` | Helpers run inside the bootstrap container: `ensure_database.rb`, `ensure_admin.rb`, `register_ips.rb`, `doctor_checks.rb`. |

Generated on the host, all gitignored: `.env`, `config/signing.key`,
`database/init/`, `backups/`, `.upgrade-state`.

## Two things worth saying up front

**`deploy.sh` never invents a site-specific value.** It generates secrets, and it
prompts for the four names it cannot guess. Run without a terminal it leaves them
empty and lists what is missing, which is how an unattended run from configuration
management is meant to complete.

**Nothing here is the local test harness.** `docker-compose.production.yml` and
`script/production/` in the repository root are contributor tooling for a Windows
checkout: loopback-only, MariaDB as `root`, no TLS, every `dns.*` key left on its
`postal.example.com` default. The word "production" in those filenames describes the
Rails environment they boot in, not their purpose. The two topologies are
deliberately not shared — changing that one to suit a deployment would break a
verified test suite for no benefit. See
[doc/api/testing.md](../doc/api/testing.md).
