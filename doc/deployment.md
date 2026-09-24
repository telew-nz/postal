# Deploying Postal with the /api/v2 management API

This is the runbook for the production deployment in [`deploy/`](../deploy). It
describes a real mail server: one that receives mail on port 25 from the
internet, delivers mail out through DNS, and answers both the web UI and the JSON
management API over HTTPS.

Nothing here is about the contributor test harness. `docker-compose.production.yml`
and `script/production/` are local Windows test tooling and are described in
[api/testing.md](api/testing.md); they are deliberately not shared with this
deployment.

## What the deployment looks like

| Process | Network | Reachable from | Purpose |
| --- | --- | --- | --- |
| `mariadb` | bridge | `127.0.0.1:3306` | The main schema and one schema per mail server |
| `postal` | bridge | nothing published | Puma: the web UI and `/api/v2` |
| `smtp` | bridge | `0.0.0.0:25` | Inbound SMTP. Queues; never dials out |
| `worker` | bridge, or host under IP pools | nothing | Delivery, and the scheduled tasks |
| `cloudflared` | bridge at `172.28.0.254` | nothing | Outbound-only tunnel for HTTP |
| `bootstrap` | bridge | nothing | One-shot runner `deploy.sh` uses for setup |

HTTP and SMTP take completely different paths, and the reason is not a matter of
taste:

```
HTTP  internet -> Cloudflare edge (TLS) -> cloudflared -> postal:5000
SMTP  internet -> this host, port 25 -> smtp
```

A Cloudflare Tunnel gives a public inbound listener for HTTP and HTTPS only.
Every other service type it supports — TCP, SSH, RDP, SMB — requires the
*connecting party* to run `cloudflared access <proto>` itself, which the world's
mail servers will not do. So port 25 is published on the host and needs a public
IP, a PTR record, and inbound 25 permitted by the provider.

Nothing else is reachable from the network. The web process has no published port
at all, and MariaDB is on loopback.

## Prerequisites

* A Linux host with Docker Engine and the Compose plugin.
* A **public IPv4 address**, with inbound TCP 25 permitted and **outbound TCP 25
  permitted**. Most cloud providers block outbound 25 by default and require a
  request. Check this first: nothing in the deployment fails loudly if it is
  blocked, mail simply queues forever.
* The provider must let you set a **PTR record** for that address. It is not a DNS
  record you can create yourself.
* A Cloudflare account with the domain on it, able to create a tunnel and an
  Access policy.
* `git`, `openssl` and `curl` on the host. `jq` is not needed; the Ruby helpers
  emit JSON that `deploy.sh` parses itself.
* Outbound HTTPS to Cloudflare: TCP 443, plus UDP 7844 for QUIC unless cloudflared
  is run with `--protocol http2`.
* Outbound DNS resolution (UDP/TCP 53) for MX, SPF, DKIM and PTR lookups.

## 1. Clone at a tag

The deployment builds from the checkout, so the checkout has to be a revision that
can be named later. That is what makes rollback possible.

```bash
sudo mkdir -p /opt/postal && sudo chown "$USER" /opt/postal
git clone https://github.com/<you>/postal /opt/postal
cd /opt/postal
git checkout api-v1.0.0
```

Everything below runs from `/opt/postal/deploy`.

```bash
cd deploy
```

`deploy.sh` resolves its own directory from `BASH_SOURCE`, so it behaves the same
whether invoked as `./deploy.sh`, by absolute path, or through a symlink.

`.gitattributes` in the repository marks `*.sh` as `eol=lf`, so a clone on Linux
gets shell scripts with LF endings. If the tree was copied from Windows by some
other means, two things can go wrong, and both produce errors that do not point at
the cause:

```bash
sed -i 's/\r$//' deploy.sh lib/*.sh    # a CR in a shebang makes the kernel fail
                                       # execve with ENOENT, which Docker reports
                                       # as "no such file or directory" for a file
                                       # that is plainly there
chmod +x deploy.sh                     # if the executable bit did not survive
```

`bash ./deploy.sh COMMAND` works identically to `./deploy.sh COMMAND` and needs
neither, which is also how `upgrade` invokes the newly checked out revision.

## 2. `init` — secrets and site values

```bash
./deploy.sh init --domain example.com
```

This creates `.env` from `.env.example`, generates `RAILS_SECRET_KEY`,
`MAIN_DB_PASSWORD` and `MARIADB_ROOT_PASSWORD` with `openssl rand -hex 32`,
generates `config/signing.key` with `openssl genrsa 2048` at mode 600, and renders
`database/init/001-postal-user.sql`.

`--domain` derives the `dns.*` names rather than leaving them on their schema
defaults, which are all subdomains of `postal.example.com`:

| Variable | Value from `--domain example.com` |
| --- | --- |
| `DNS_MX_RECORDS` | `mx.example.com` |
| `DNS_SPF_INCLUDE` | `spf.example.com` |
| `DNS_RETURN_PATH_DOMAIN` | `rp.example.com` |
| `DNS_ROUTE_DOMAIN` | `routes.example.com` |
| `DNS_TRACK_DOMAIN` | `track.example.com` |
| `DNS_HELO_HOSTNAME` | `mx.example.com` |
| `POSTAL_SMTP_HOSTNAME` | `mx.example.com` |

Leaving those alone produces domains that cannot be verified and mail that cannot
be delivered, with no error anywhere. That is the failure mode `init --domain`
exists to prevent.

It then prompts for the four values it cannot invent:

* `POSTAL_WEB_HOSTNAME` — the public hostname the tunnel serves, e.g.
  `postal.example.com`. This is not a label. `config/application.rb` pushes
  exactly this one value onto `config.hosts`, and `ActionDispatch::HostAuthorization`
  answers **403** to every request whose `Host` header does not match it. It must
  be the public name, not the origin's name or IP.
* `POSTAL_SMTP_HOSTNAME` — announced in the SMTP 220 banner, used for CRAM-MD5
  challenges and Received-header loop detection. Should be the name the PTR record
  resolves to.
* `POSTAL_ADMIN_EMAIL` — the administrator's login.
* `CLOUDFLARE_TUNNEL_TOKEN` — read without echoing, because it can serve traffic
  as the tunnel.

Also set `POSTAL_PUBLIC_IP`. Nothing in Postal reads it: the address the host is
reachable on is not something the application can determine from inside a NAT'd
container, which is exactly why it has to be stated. `dns` uses it to print the A
records, and `doctor` uses it to check the PTR.

`init` is idempotent and only fills values that are currently empty, so it is safe
to re-run after an interrupted attempt and safe to run on an installation already
serving mail. It ends by listing anything still missing and returning non-zero,
rather than letting the gap be discovered when compose refuses to start.

`--force-secrets` regenerates the three secrets. It invalidates every web session
and breaks access to the existing database volume, which then has to be recreated.

### The signing key's ownership

The containers run as uid 999 and mount `./config` read-only, so they have to be
able to read `signing.key` as that uid. Running `init` as root sets it; running it
as an ordinary user warns and prints the exact command:

```bash
sudo chown 999:999 /opt/postal/deploy/config/signing.key
```

Until it is, DKIM signing fails — and it fails on the far side, as a verification
error at the recipient, not as an error here. `doctor` checks it.

### The scoped database user

`database/init/001-postal-user.sql` replaces the `root` access that
`docker-compose.production.yml` uses locally:

```sql
GRANT ALL PRIVILEGES ON `postal`.* TO 'postal'@'%';
GRANT ALL PRIVILEGES ON `postal-server-%`.* TO 'postal'@'%';
```

Nothing else: no global privileges, nothing on the `mysql` schema, no `FILE`.
Postal creates one schema per mail server, named `postal-server-<id>`, which is
why the second grant needs a pattern — a database-level grant on a name pattern
also permits `CREATE DATABASE` for matching names.

The MariaDB entrypoint runs `/docker-entrypoint-initdb.d` **only on first
initialization of an empty volume**. Changing the password in `.env` afterwards
does nothing to a database that already exists; `init --force-secrets` says so, and
`doctor` verifies that the connecting user is not `root` and cannot read other
schemas.

## 3. Cloudflare Tunnel

In the Zero Trust dashboard: create a tunnel, then add a public hostname for
`POSTAL_WEB_HOSTNAME` pointing at

```
http://postal:5000
```

`postal` is the compose service name, not `localhost` — cloudflared runs on the
compose network and resolves it there, while `localhost` would be cloudflared's
own container. `http`, not `https`: Puma serves plaintext and the edge terminates
TLS. That asymmetry is why `postal.web_protocol` is `https` in
`deploy/config/postal.yml` while the origin is `http`.

Copy the tunnel token into `.env` as `CLOUDFLARE_TUNNEL_TOKEN`.

The compose file runs cloudflared in **token mode**, where the ingress rules live
in the dashboard and the only secret on the host is the token.
[`deploy/cloudflared/config.yml`](../deploy/cloudflared/config.yml) is a reference
configuration for a locally-managed tunnel instead, with the exact `command` and
`volumes` edits needed to switch, and a note about the credentials file it then
requires.

The tunnel connector is behind a compose profile that `./deploy.sh up` activates by
default. Two reasons it is a profile and not unconditional: the token cannot be
required at interpolation time, because compose expands the whole file before it
decides which services to start, so a `:?` there would refuse to bring up the
origin for an operator who has not created a tunnel yet; and diagnosing the origin
directly, without Cloudflare in the path, is a normal thing to need —
`./deploy.sh up --without-tunnel`.

## 4. Build, migrate, up

```bash
./deploy.sh build
./deploy.sh migrate
./deploy.sh up
```

**`build`** uses the upstream `Dockerfile`'s `full` target, passing
`VERSION=$(git describe --tags)` and `BRANCH` as build args so the running image
can be identified afterwards. `Dockerfile.production` is not involved: its whole
purpose is undoing CRLF damage in a Windows working tree, and its own header says
that on a Linux checkout the normalization is a no-op which makes it equivalent to
`--target full`.

`--target full` is stated explicitly rather than relied on as the default because
the alternative target `ci` skips asset compilation, and an image built with it
serves a web UI with no stylesheet — a silent difference, not an error.

`build` **refuses to run on a dirty working tree** unless `--allow-dirty` is
given. An image built from uncommitted changes has no revision to check out,
nothing to roll back to, and no way to tell two builds of the same tag apart.

Set `POSTAL_IMAGE_TAG` (e.g. `postal:api-v1.0.0`) to tag a versioned image
alongside the mutable `POSTAL_IMAGE` that compose references. Without it, every
build destroys the previous image's only reference, and
`./deploy.sh rollback --no-build` has nothing to roll back to.

**`migrate`** starts MariaDB if it is not already running — the bootstrap container
depends on it, and a migration against an absent database reports a connection
error that reads like a schema problem — then creates the main database, loads or
migrates the schema, and runs migrations against every server's message database.
Idempotent.

**`up`** starts everything and waits for every healthcheck. The web healthcheck
sets the `Host` header explicitly, because `config.hosts` contains only
`postal.web_hostname` and a probe to `127.0.0.1` without it is answered 403 by
HostAuthorization, making the container look permanently unhealthy when Rails is
fine. A 302 to the login page counts as success: it proves Rails booted and
routing works, which is all liveness needs to know.

## 5. `admin` — the administrator and the first token

```bash
./deploy.sh admin
```

Creates the administrator named by `POSTAL_ADMIN_EMAIL` and an API token, and
prints the plain `pst_` key **once**:

```
Send it as:   X-Postal-API-Key: pst_...
```

Only the SHA-256 digest is stored, so the key cannot be read back later. If it is
lost, `./deploy.sh admin --new-token` mints another; the old one is left active so
anything still using it keeps working, and can then be revoked through
`DELETE /api/v2/tokens/{uuid}`.

The key is saved to `POSTAL_API_TOKEN` in `.env` (`--no-save` to skip) so that
`dns` and `doctor` can call the API without the operator pasting it each time. It
stays host side: compose only forwards the variables each service lists, and none
of them list this one.

Idempotent — an existing administrator and an existing active token of the same
name are left alone. The token name matters more than it looks: only the digest is
stored, so `POSTAL_TOKEN_NAME` is the only handle on it afterwards.

## 6. `dns` — publish the records

```bash
./deploy.sh dns
```

Read-only. Prints every record this installation needs, in the order they are
needed, derived from the configuration rather than hardcoded — so two commands
running against the same configuration cannot drift apart.

| # | Record | Value |
| --- | --- | --- |
| 1 | `A` for each name in `DNS_MX_RECORDS` | `POSTAL_PUBLIC_IP` |
| 2 | `TXT` at `DNS_SPF_INCLUDE` | `v=spf1 mx a:<smtp hostname> ~all` |
| 3 | `MX` at `DNS_RETURN_PATH_DOMAIN` | `10 <smtp hostname>` |
| 3 | `TXT` at `<dkim id>._domainkey.<return path domain>` | from `config/signing.key` |
| 4 | `MX` at `DNS_ROUTE_DOMAIN` | `10 <smtp hostname>` |
| 5 | `CNAME` at `DNS_TRACK_DOMAIN` | `<web hostname>.` |
| 6 | **PTR** for `POSTAL_PUBLIC_IP` | `DNS_HELO_HOSTNAME` — ask the provider |

The return-path DKIM value is the public half of `config/signing.key`, obtained by
running Postal's own `script/default_dkim_record.rb` in the bootstrap container.
`DKIMHeader` falls back to `d=<return path domain>` with `s=<dkim identifier>`
whenever a domain has no verified key of its own, which is the common case, so
this is the record that signs most outbound mail.

Item 6 is not a DNS record and cannot be created in a DNS zone. It is the single
most common reason outbound mail is rejected, and it must match
`DNS_HELO_HOSTNAME` and the hostname of every registered IP address.

Once organizations and domains exist, `dns` also fetches the per-domain records
from `GET /api/v2/organizations/:org/domains/:uuid/dns_records`. An **unverified**
domain answers 422 there, so for those the only record printed is the verification
TXT:

```bash
./deploy.sh dns                       # prints postal-verification.<domain>
# publish it, then:
curl -X POST "$BASE/api/v2/organizations/$ORG/domains/$UUID/verify" \
     -H "X-Postal-API-Key: $TOKEN"
./deploy.sh dns                       # now prints the domain's SPF, DKIM, MX, CNAME
curl -X POST "$BASE/api/v2/organizations/$ORG/domains/$UUID/check" \
     -H "X-Postal-API-Key: $TOKEN"
```

`--no-api` prints only the records derivable from configuration, for when the stack
is not running or no token is available.

Then confirm what the internet actually resolves:

```bash
./deploy.sh doctor
```

## 7. `doctor` — assert, don't assume

```bash
./deploy.sh doctor
```

`doctor` exists because a mail server fails in ways that look like success. It
observes the running deployment rather than reading its configuration back, and
exits non-zero if anything failed. `--quick` skips the four groups that run a
bootstrap container — `config`, `database`, `dns` and `addresses` — and so starts
nothing itself, though it still needs a working docker and a stack which is up.

| Group | What it proves |
| --- | --- |
| `files` | the signing key exists and is owned by uid 999; `config/postal.yml` has `version: 2`; `.env` is 600; `trusted_proxies` covers the compose subnet and the compose project name matches `COMPOSE_PROJECT` |
| `containers` | every expected service running and healthy, and **exactly one** worker variant |
| `https` | `GET /api/v2/spec` through the tunnel, and the same request against the origin from inside |
| `api` | `/api/v2/me` refused without a key, accepted with the saved one |
| `smtp` | port 25 greets with `220` and announces `postal.smtp_hostname` |
| `config` | what the application actually resolved, including whether any value is still an `example.com` default |
| `database` | the connecting user is not `root` and cannot read other schemas; the schema is loaded; a worker holds the `tasks` role; the queue depth |
| `dns` | PTR, SPF, DKIM, the MX A records and the tracking CNAME, resolved from inside the container |
| `addresses` | each registered IP is on an interface of this host, and its hostname is that address's PTR |

Two of these deserve saying out loud, because both are invisible otherwise.

**Separating the tunnel from the origin.** `https` makes the same request twice:
once through the public hostname, once from inside against the origin. If the
origin answers and the public name does not, the fault is in the tunnel or in DNS
and there is no reason to look at the application. A **403 is HostAuthorization,
never permissions** — `config.hosts` receives exactly one entry, so
`POSTAL_WEB_HOSTNAME` must equal `postal.web_hostname` and must be the public
hostname the tunnel serves.

**The `tasks` role.** `worker_roles` has one row per role, renewed every 60 seconds
and stolen after five minutes (`app/models/worker_role.rb`). Absent is different
from stale and means something different: absent means no worker has ever acquired
it, so either none is running or it cannot reach this database. Stale means the
holder is gone. Either way no scheduled task runs — retention, queue sizing, the
suppression list — even though message delivery may be continuing in another
process. Nothing in the web UI reports this.

`dns` lookups use Ruby's `Resolv` rather than Postal's own resolver, deliberately:
doctor asks what the internet sees, not what Postal is configured to ask. The image
installs `curl` and `netcat` but neither `dig` nor `host`, so there is no resolver
to shell out to.

## Security

Read this before pointing anything at the public internet.

**Tokens are user-scoped with no permission model.** A `UserAPIToken` belongs to a
user and can do everything that user can do through the API. There is no
read-only token, no per-organization scope, and no way to grant one token less than
another. Any token held by an administrator is an administrator credential.

**The bootstrap token belongs to an administrator.** `./deploy.sh admin` creates it
under `POSTAL_ADMIN_EMAIL` and saves the key in `.env`, which is why that file is
gitignored, chmod 600, excluded from the Docker build context, and never forwarded
into a container.

**`GET /api/v2/spec` is unauthenticated.** `config/routes.rb` says so in a comment.
Anyone who can reach the hostname can enumerate every operation, its parameters and
its response shapes before authenticating. That is a reconnaissance surface, not a
vulnerability on its own, but it should be a decision rather than a default.

**The recommended posture is a Cloudflare Access policy on the API hostname in
front of the token.** Access is enforced at the edge, so an unauthenticated
request never reaches Puma at all — which also closes the unauthenticated `/spec`.
If the web UI and the API must be reachable by different audiences, put them on
different hostnames with different policies; they are the same Puma process, so one
hostname covers both by default.

The alternative is `API_ENABLED=false` in `.env`, which disables the API entirely.
`api.enabled` defaults to `true` in the schema, so `deploy/config/postal.yml`
states it explicitly rather than inheriting it: this is the switch that decides
whether an administrative interface is reachable from the internet.

Beyond that:

* `deploy/backups/` is gitignored for a reason. Each archive contains a dump of
  every schema, `config/signing.key` and the whole of `.env`. Point `--out` at a
  mounted off-host filesystem: a backup on the same disk as the data it protects
  does not survive losing that disk.
* `./deploy.sh up --debug` publishes the origin on `127.0.0.1:5000`, which bypasses
  Cloudflare and therefore **bypasses any Access policy**. Anyone with a shell on
  the host can then reach the management API with a valid token and no second
  factor. Prefer `./deploy.sh status`, which probes the origin from inside the
  running container and opens nothing, or `./deploy.sh exec` for a shell in there.
* `postal.trusted_proxies` must contain the cloudflared network. The subnet is
  pinned by an explicit `ipam` declaration so the value cannot drift on restart;
  without it Rack ignores `X-Forwarded-For` and `request.ip` becomes the tunnel
  container's address rather than the client's, which is what Authie sessions and
  every access log then record. If the subnet changes, `config/postal.yml` and
  `CLOUDFLARED_IP` change with it, and `doctor` checks all three agree.
* The Rails secret key variable is **`RAILS_SECRET_KEY`, not `SECRET_KEY_BASE`**.
  `config/initializers/secret_key.rb` reads `Postal::Config.rails.secret_key` and
  falls back to `SecureRandom.hex(128)` when it is nil, so passing the conventional
  name appears to work while giving every container a different random key and
  invalidating every session cookie on each restart.
* `config/postal.yml` **must contain `version: 2`**. Without it the file is read
  through `LegacyConfigSource`, which maps v1 names onto the current schema; none
  of the v2 names appear in that mapping, so every one is silently ignored and the
  defaults apply with no error. `doctor` checks for it.

## Operating

```bash
./deploy.sh status              # compose ps, plus a probe of the origin from inside
./deploy.sh logs [service]      # --tail=200 by default; LOGS_TAIL to change it
./deploy.sh ps
./deploy.sh restart [service]
./deploy.sh exec [service] [-- cmd]   # a shell in the web container by default
./deploy.sh down                # stops the stack, keeps the database volume
./deploy.sh reset               # deletes the stack AND the volume, with a typed confirmation
```

`down` deliberately does not pass `--volumes`: that would delete the MariaDB data
directory, which is every message this installation has ever received. `reset` does
it, separately, and asks you to type the hostname of the installation first.

Container logs are rotated by the compose file — `json-file` with
`POSTAL_LOG_MAX_SIZE` (default `50m`) and `POSTAL_LOG_MAX_FILE` (default `5`),
about 1.2 GB across the six services. Docker's json-file driver has **no** size
limit unless one is set, so a mail server left running will eventually fill the
disk with logs, and a full disk is a worse failure than the one that filled it:
MariaDB stops cleanly at best and corrupts at worst.

## Backup and restore

```bash
./deploy.sh backup [--label nightly] [--out /mnt/backups] [--stop] [--volume] [--keep 7]
./deploy.sh backups
./deploy.sh restore FILE [--volume] [--config] [--env] [--yes]
```

`backup` writes one gzipped tarball containing a dump of every Postal schema, the
`config/` directory (including the DKIM signing key) and `.env`. The dump is
validated rather than assumed — `gzip -t`, then a count of `CREATE DATABASE`
statements — because a dump can fail and still produce a truncated archive, and
`gzip` reports success on an empty input.

`MYSQL_PWD` is set inside the container by its own shell from a variable compose
already gives it. Passing `-p` on the command line would put the password in argv,
where it is readable from `/proc` by any user on the host for as long as the dump
runs.

The MariaDB **system schema is deliberately not dumped**. Grants are rendered by
`./deploy.sh init` into `database/init/`, which the entrypoint applies to an empty
volume, so a restore recreates the scoped user from source rather than from a dump
of `mysql.user` taken at some arbitrary earlier moment.

`--volume` copies the raw data directory instead of dumping. Larger and tied to
this MariaDB version, but restores without re-running migrations. It requires
`--stop`. `restore --volume` destroys the current data directory.

`restore` refuses to overwrite `config/` or `.env` unless `--config` or `--env` is
given, because doing so replaces the DKIM signing key and every secret the running
installation is using.

Both commands clean up their working directory on **any** exit, including a failure.
That matters more than it looks: a failed backup would otherwise leave a directory
holding the signing key and a full database dump on disk.

## Upgrade and rollback

```bash
./deploy.sh upgrade api-v1.1.0
./deploy.sh rollback                 # back to the revision the last upgrade left
./deploy.sh rollback api-v1.0.0      # or to a named tag
```

`upgrade` requires a clean working tree, fetches tags, **takes a backup labelled
`pre-upgrade-<target>` before anything changes**, writes `.upgrade-state` recording
where this host was, then checks out the target and runs `build`, `migrate` and
`up` using the *newly checked out* `deploy.sh`.

With no tag it lists the tags available and stops: a mail server should not be moved
to an unspecified "latest". A non-tag commit is accepted with a warning that it will
not be reproducible later the way a tag is.

It also compares the new `.env.example` against `.env` and names the keys the new
revision has that this host lacks — the ones worth surfacing are the optional ones
whose absence is silent.

If any phase fails, `upgrade` prints both the rollback command and the
restore-from-backup path, because they answer different problems.

`rollback` returns to the recorded revision and rebuilds and restarts, but **does
not migrate and therefore does not undo any migration the upgrade applied** —
MariaDB has no down migrations. If the upgrade did migrate and the new schema is the
problem, restoring the pre-upgrade backup is the correct action, not rollback:

```bash
./deploy.sh backups
./deploy.sh restore <archive>
```

`--no-build` reuses the image already tagged for that revision, which is only
correct if it was built before — which `POSTAL_IMAGE_TAG` is what makes possible.

A note on something that looks wrong but is not. `git checkout` rewrites the very
scripts that are executing. That is safe: bash parses a complete function body
before running any of it, so once `deploy.sh` has sourced `lib/*.sh` every function
is already in memory and the files on disk are irrelevant to it; `main` exits rather
than returns, so nothing is read from `deploy.sh` after that point; and git replaces
a file by writing a temporary one and renaming it over the target, so the inode bash
holds open is untouched. Rewriting a running script in place, with the same inode,
does corrupt it — which is why nothing here does that.

## Outbound IP pools

Off by default, and enabling it is not just a flag.

When a message has an assigned `IPAddress`, `SMTPClient::Endpoint` sets
`Net::SMTP#source_address` from it before connecting, which makes Ruby `bind()`
that address. Under bridge networking the container does not hold the host's public
IP, so the bind fails with `EADDRNOTAVAIL` and nothing assigned to an IP address is
ever sent. The same job matches `Socket.ip_address_list` against the `IPAddress`
table to decide what it may claim, so the address has to be genuinely present on an
interface for the worker to see it at all.

```bash
# .env
POSTAL_USE_IP_POOLS=true
POSTAL_IP_ADDRESSES=203.0.113.10=mx1.example.com,203.0.113.11=mx2.example.com
POSTAL_IP_POOL_NAME=Default

./deploy.sh ip      # register them
./deploy.sh up      # now selects the worker-hostnet variant
```

`POSTAL_USE_IP_POOLS=true` switches the worker to `network_mode: host` and sets
`MAIN_DB_HOST`, `MESSAGE_DB_HOST` and `WAIT_FOR_TARGETS` to `127.0.0.1`, because a
host-networked container cannot resolve the `mariadb` DNS name. That is the only
configuration under which registered IP addresses can be bound, and it is the only
reason to give up bridge isolation. The host-networked worker accepts no inbound
connections — its health server binds `127.0.0.1` — and it is the process that has
to speak to the internet as the host anyway.

`./deploy.sh ip` exists as a command because there is no API route for it:
`config/routes.rb` exposes `ip_addresses` only as a web-UI resource nested under
`ip_pools`, and the API gives `ip_pools` `only: [:index]`. Registration goes
through `rails runner`.

Each entry's hostname becomes the HELO string for mail sent from that address, so
it **must equal that address's PTR record**. `doctor` checks both halves: that the
address is on an interface of this host, and that its hostname is that address's
PTR.

Without IP pools, a message with no assigned IP is still delivered — the queue job
selects on `ip_address_id: [nil, @ip_addresses]` — and on a bridge network
`@ip_addresses` is empty, so the worker claims only unassigned messages and never
attempts a bind it cannot satisfy. SNAT gives the mail the host's public IP. Single-IP
sending works fine this way, which is why pools are opt-in.

## Deliberate gaps

These are decisions recorded here so they are not rediscovered as bugs.

**Inbound SMTP has no TLS.** `smtp_server.tls_enabled` is `false`. Cloudflare does
not terminate SMTP, so inbound STARTTLS on a directly-published port 25 would need a
certificate on this host that something then has to renew. To enable opportunistic
STARTTLS later, set `smtp_server.tls_enabled: true` and provide
`tls_certificate_path` and `tls_private_key_path` — the schema defaults them to
`$config-file-root/smtp.cert` and `smtp.key`, which is `/config` here, so files at
`deploy/config/smtp.cert` and `deploy/config/smtp.key` would be picked up.
**Outbound delivery is unaffected**: the worker negotiates STARTTLS with remote
servers itself, per their advertised capabilities.

**`EHLO` presents no hostname.** `app/lib/smtp_server/client.rb` answers
`250-My capabilities are` where RFC 5321 puts the server's name. This is upstream
behaviour, not something the API introduced, and changing it is a change to mail
handling rather than to the deployment. It is worth fixing before this faces the
internet; the fix is `"250-#{Postal::Config.postal.smtp_hostname}"`, and
`spec/lib/smtp_server/client/helo_spec.rb` asserts the current literal in two places
and would have to be updated with it.

**No message inspection.** `rspamd`, `spamd` and `clamav` are all `enabled: false`.
They are separate services this topology does not run, and enabling any of them
makes the worker attempt to reach a host that does not exist. Add the services to
`docker-compose.yml` before flipping these.

**MariaDB is containerised with a named volume.** Swapping in an external managed
database changes only `main_db`/`message_db` and removes the loopback publish.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Every request returns **403** | `HostAuthorization`. `config.hosts` has exactly one entry | `POSTAL_WEB_HOSTNAME` must equal the public hostname the tunnel serves |
| Stack is healthy but completely empty | The compose project name changed, so the MariaDB volume name changed | `COMPOSE_PROJECT` and the `name:` in `docker-compose.yml` must agree; `doctor` checks this |
| Configuration seems to be ignored entirely | `config/postal.yml` has no `version: 2` | Add it. Without it the file is read as legacy v1 and every v2 key is silently dropped |
| Sessions invalid after every restart | `SECRET_KEY_BASE` was set instead of `RAILS_SECRET_KEY` | Use `RAILS_SECRET_KEY` |
| Access logs and Authie show the tunnel's IP | `postal.trusted_proxies` does not cover the cloudflared subnet | Pin the subnet in all three places; `doctor` checks them |
| Web container permanently unhealthy, but `curl` inside works | The healthcheck is not setting `Host` | It does; if you edited it, `$$` is compose's escape for a literal `$` |
| Mail queues and never sends | Outbound port 25 blocked by the provider | Ask the provider. Nothing fails loudly when this is blocked |
| Mail sends but is rejected or spam-filtered | PTR missing or not matching `DNS_HELO_HOSTNAME` | Set the PTR at the provider; `doctor` verifies it |
| `EADDRNOTAVAIL` from the worker | An `IPAddress` is assigned but the worker is bridge-networked | Enable IP pools, or unassign the address |
| Scheduled tasks not running, delivery fine | No worker holds the `tasks` role | `doctor` distinguishes absent from stale; check the worker's log |
| DKIM fails at the recipient | `signing.key` not readable by uid 999, or the TXT record not published | `sudo chown 999:999`, then `./deploy.sh dns` and re-publish |
| `deploy.sh: command not found` on a copied tree | CRLF in the shebang; the kernel fails `execve` with ENOENT | `sed -i 's/\r$//' deploy.sh lib/*.sh`, or clone the repository instead of copying it |
| `./deploy.sh: Permission denied` | The executable bit did not survive the copy | `chmod +x deploy.sh`, or invoke it as `bash ./deploy.sh` |
