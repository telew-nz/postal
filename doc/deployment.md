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
| `acme` | bridge | nothing | One-shot ACME client, only under `--profile tls` |

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
* Optional: to provision the DNS records, the tunnel, and client-domain zones
  automatically, a single Cloudflare API token with these permissions:
  Zone→DNS→Edit, Zone→Zone→Read, Account→CFD Tunnel→Edit, and (for
  `cloudflare zone add`) Account→Zone→Edit. The Zone resource scope must cover
  All zones, because a client zone does not exist when the token is created.
  Set `CLOUDFLARE_ACCOUNT_ID` when the token sees more than one account.
  Without the token the manual steps below still apply and are fully supported.
* `git`, `openssl` and `curl` on the host. `jq` is not needed; the Ruby helpers
  emit JSON that `deploy.sh` parses itself.
* Outbound HTTPS to Cloudflare: TCP 443, plus UDP 7844 for QUIC unless cloudflared
  is run with `--protocol http2`.
* Outbound DNS resolution (UDP/TCP 53) for MX, SPF, DKIM and PTR lookups.
* For inbound SMTP TLS only: a **second** Cloudflare API token, scoped to
  Zone → DNS → Edit on the one zone, and a real contact email address. See
  [7. `tls`](#7-tls--the-inbound-smtp-certificate). Neither is needed by anything
  else here — the tunnel token cannot be reused, because it is not a DNS
  credential.

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

### Automating this step

`./deploy.sh cloudflare provision` does all of the above through the Cloudflare
API when `CLOUDFLARE_API_TOKEN` is set in `.env` (scopes in the prerequisites): it
creates the tunnel, writes its connector token to `CLOUDFLARE_TUNNEL_TOKEN`,
creates the public-hostname CNAME pointing at the tunnel, sets the ingress route
`POSTAL_WEB_HOSTNAME → http://postal:5000`, and provisions the installation-wide DNS
records (A for the MX names, SPF, return-path MX + DKIM, route MX, tracking
CNAME). It is idempotent and deletes nothing; `--dry-run` prints what it would do
without calling the API. It never creates the PTR (that stays with the hosting
provider) and it does not publish per-domain records, which come from the
management API once domains exist — run `./deploy.sh dns` after `admin` for those.

### Onboarding a client domain

`./deploy.sh cloudflare zone add <domain>` adds a client's domain as a zone
(`POST /zones`), prints the two nameservers to give the client, then polls the
zone until it is `active` (nameserver verification) — the confirmation that the
client has pointed their NS records at Cloudflare. `cloudflare zone status
<domain>` shows the current status and nameservers. The zone is created on the
account the token belongs to; the client is expected to change their registrar
nameservers to the ones printed. Only then can records be created in the zone
(via `cloudflare provision` equivalents or the dashboard). This does not create
the Postal organization/domain — that still goes through the management API and
`./deploy.sh dns`.

Once a domain exists in Postal, `./deploy.sh cloudflare domain <domain>`
publishes its records into its Cloudflare zone automatically: it looks the
domain up via the management API, (re)publishes the verification TXT, and, once
verified, publishes the per-domain SPF/DKIM/MX/CNAME records via the Cloudflare
API. `--verify` triggers domain verification after publishing the TXT.
Requires `POSTAL_API_TOKEN` (from `./deploy.sh admin`) in addition to the
Cloudflare token. This replaces the manual "publish the verification TXT, then
re-run `dns`" loop for domains whose zone is in the same Cloudflare account.

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

## 7. `tls` — the inbound SMTP certificate

Optional. Everything above this point is a working mail server without it.

```bash
./deploy.sh tls issue --staging   # against Let's Encrypt's staging CA
./deploy.sh tls issue             # the real certificate
./deploy.sh tls status
```

Obtains a certificate from Let's Encrypt using the **DNS-01** challenge and
installs it where the SMTP server reads it. DNS-01 rather than HTTP-01 because
there is nothing to serve the challenge from: port 25 is an SMTP listener, and the
HTTPS origin is behind a tunnel on a different hostname. DNS-01 also does not
require the validated name to be the name being served, which is what makes a
certificate for the MX hostnames possible at all here.

The names come from `POSTAL_SMTP_HOSTNAME` plus `DNS_MX_RECORDS`, deduplicated, in
that order — the first becomes the certificate's common name and the directory
acme.sh keeps its state in. Those are the names remote servers are told to connect
to, which is what the certificate has to cover; note that `EHLO` does not present
`smtp_hostname` at all, so a certificate for it is not what makes the banner name
validate.

### What each subcommand does

| Command | Effect |
| --- | --- |
| `tls issue [--staging] [--wildcard DOMAIN]` | Creates the `_acme-challenge` TXT records, waits for them to propagate, obtains the certificate, then runs `install`. Always passes `--force`, so it replaces a certificate that is not near expiry — that costs rate limit, which is why the limit is printed first. `--wildcard DOMAIN` issues `DOMAIN` and `*.DOMAIN` (DNS-01) instead of the MX hostnames |
| `tls renew [--force]` | Renews the existing certificate **as it stands**, then installs it. Exits 0 and changes nothing when the certificate is not yet due |
| `tls install` | Copies the pair into `config/`, sets ownership, flips `SMTP_SERVER_TLS_ENABLED`, recreates `smtp` |
| `tls import CERT KEY` | Installs an already-obtained certificate (e.g. a wildcard issued elsewhere) into `config/smtp.cert` and `config/smtp.key`, flips `SMTP_SERVER_TLS_ENABLED`, recreates `smtp`. Provide a fullchain, leaf first. Imported certificates are not renewed by this tool |
| `tls status` | Reads the installed certificate back: chain length, issuer, subject alternative names, expiry, whether the key matches |

### Why `install` recreates the container rather than restarting it

`SMTPServer::Server` parses the certificate **once per process** and memoizes it on
the class (`@tls_certificates ||=`), and `prepare_environment` traps only `TERM` and
`INT` — both of which shut the listener down. There is no reload signal, so a
renewed certificate on disk is invisible to a running process.

It also has to be `up -d --no-deps smtp`, not `restart`. `docker compose restart`
reuses the existing container and therefore its original environment, so the new
`SMTP_SERVER_TLS_ENABLED` never arrives: `.env` says TLS is on, the process says it
is off, and anything reading `.env` agrees with `.env`. `doctor` compares the two
and fails when they differ. The recreate drops in-flight SMTP connections, which
`install` warns about and skips entirely when the certificate did not change.

The file must be a **fullchain, leaf first**. `ssl_context` assigns the first
certificate in the file to the context and everything after it to
`extra_chain_cert`, so a leaf-only file presents no intermediate. Let's Encrypt's
intermediate is widely cached, which means that passes most of the time and then
fails for one sender — so `doctor` treats a chain of one as a failure.

### What this does and does not buy you

**Inbound mail on port 25 is opportunistic** (RFC 7435). A sender that cannot
validate the session falls back to plaintext and still delivers, so for ordinary
server-to-server mail a publicly trusted certificate behaves the same as a
self-signed one. **This is not a deliverability fix**, and it will not move a spam
score.

What it is required for:

* **MTA-STS** (RFC 8461). Gmail, Microsoft, Yahoo and Fastmail do validate, and a
  policy in `enforce` mode refuses to deliver rather than downgrading. The
  certificate is necessary but **not sufficient**: MTA-STS also needs the policy
  document served over HTTPS at `mta-sts.<domain>` and a `_mta-sts` TXT record,
  and Postal serves neither. Publishing a policy without both would stop inbound
  mail from those providers.
* **DANE** (RFC 7672), which additionally needs a DNSSEC-signed zone.
* **Mail-client submission**, which validates like a browser and will not offer a
  "continue anyway".

Outbound delivery is unaffected either way: the worker negotiates STARTTLS with
remote servers itself, per their advertised capabilities.

### Renewal

Renewal is driven from the host by a timer, not by a sidecar. A sidecar that could
recreate `smtp` itself would need `/var/run/docker.sock`, which is root on the host,
in a container holding a credential that can write DNS records for the zone.

`./deploy.sh tls renew --help` prints a ready-made unit and timer pair. Twice daily
is Let's Encrypt's own recommendation: with `ACME_RENEW_DAYS=30` on a 90-day
certificate the window opens with a month of validity still to run, so about 60
attempts precede expiry.
`Persistent=true` matters — it runs a missed invocation after downtime rather than
waiting for the next one, which is the difference between a host that was off and
an expired certificate.

A run where the certificate is not yet due exits 0 with no change, and that is the
expected outcome for about two thirds of invocations. acme.sh signals it with its
own code 2, which `tls renew` translates rather than reporting as a failure.

### Rolling back

Set `SMTP_SERVER_TLS_ENABLED=false` in `.env` and recreate `smtp`. Do not leave the
flag true with the files removed: `client.rb` answers `220 Ready to start TLS`
whenever `tls_enabled?` is true and then the handshake raises, which is worse than
the clean `502 TLS not available` a sender handles by falling back to plaintext.
`tls install` therefore only flips the flag after both files are in place and
readable by uid 999.

### Configuration

| Variable | Default | Notes |
| --- | --- | --- |
| `SMTP_SERVER_TLS_ENABLED` | `false` | In `x-postal-env`, so every Postal process sees the same value. `doctor` reads resolved configuration from a bootstrap container, and a value only `smtp` had would make it disagree with the running server |
| `CLOUDFLARE_DNS_API_TOKEN` | — | Read by the `dns_cf` plugin as `CF_Token`. **Not** the tunnel token and **not** the global API key |
| `ACME_CONTACT_EMAIL` | — | Required, and checked before anything is attempted. Let's Encrypt validates the domain against the public suffix list and rejects reserved names, so no placeholder works — and its `invalidContact` error arrives *after* the account key is created and does not name the address as the problem |
| `ACME_RENEW_DAYS` | `30` | Days of validity remaining at which renewal is attempted |
| `ACME_KEYLENGTH` | `2048` | RSA, not ECDSA: some MTAs still have TLS stacks that will not negotiate ECDSA, and a certificate the peer cannot use is worse than a larger handshake |
| `ACME_IMAGE` | `neilpang/acme.sh:3.1.1` | Pinned, where `CLOUDFLARED_IMAGE` is `:latest`. This container holds an account key and a DNS-edit token, so a moving tag is a supply-chain risk with an unusually large blast radius |
| `ACME_DEBUG` | unset | Set to `2` for the client's own trace |

The client is pinned to a state directory at `/acme.sh` inside the container, and
that path is not interchangeable. `/root/.acme.sh` holds the **program** —
`/usr/local/bin/acme.sh` is a symlink into it — so mounting host state there
destroys the tool with `acme.sh: not found`. acme.sh's own default CA is also
ZeroSSL rather than Let's Encrypt, which is why every invocation here passes
`--server` explicitly; the CA chosen at first issue is recorded per domain and is
sticky.

The `acme` container is deliberately **not** given `./config`. It holds a
DNS-edit token and `./config` holds the DKIM signing key, so it installs into
`./acme/install/` and `deploy.sh` copies the two files across on the host — which
is also the only place the `chown` to uid 999 can happen, since the container runs
as root and would otherwise leave a key the SMTP server cannot read.

## 8. `doctor` — assert, don't assume

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
| `tls` | the certificate the SMTP server presents: chain length, key match, issuer, expiry, SAN coverage against the configured names, and a **live STARTTLS handshake** against port 25. Also compares `.env` against the running container's own environment |
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

**The `tls` handshake is probed rather than read.** `server.rb` rescues
`OpenSSL::SSL::SSLError` and logs `SSL Negotiation Failed` at **debug** level, which
is off in production. A certificate that every remote server rejects therefore
produces no output on this host at all — the mail simply arrives in plaintext, or
does not arrive. So `doctor` runs `openssl s_client -starttls smtp
-verify_return_error` against the published port and reports what a sender would
conclude, distinguishing `untrusted` from `nostarttls` from `unreachable`.

The group is skipped entirely when `SMTP_SERVER_TLS_ENABLED` is not `true`, which is
the default and not a defect. It does warn if a certificate is installed and unused,
because that is indistinguishable from having no certificate to whoever installed it.

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
`POSTAL_LOG_MAX_SIZE` (default `50m`) and `POSTAL_LOG_MAX_FILE` (default `5`), so
250 MB per container and about 1.2 GB across the five that stay up (`bootstrap` and
`acme` are one-shots and barely log). Every service in the table above inherits it,
including the profiled ones. Docker's json-file driver has **no** size limit unless
one is set, so a mail server left running will eventually fill the disk with logs,
and a full disk is a worse failure than the one that filled it: MariaDB stops
cleanly at best and corrupts at worst.

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

## Master scripts

Two convenience wrappers for a throwaway or re-bootstrapable server, in
`deploy/`:

**`sudo bash deploy/master-destroy.sh`** — stops the stack, removes the
containers and the MariaDB volume, `rm -rf /opt/postal`, then re-clones the
repository at the latest `api-v*` tag (or `--ref <tag>`). Requires a typed
confirmation unless `--yes`. `POSTAL_REPO_DIR` / `POSTAL_REPO_URL` override the
path and clone source.

**`sudo bash deploy/master-standup.sh`** — runs the full known-good sequence:
`init` → `cloudflare keys` → `cloudflare provision` → `build` → `migrate` →
`up` → `admin` → `doctor`. It requires `deploy/.env` to already be seeded with
the site values and `CLOUDFLARE_API_TOKEN` (`init` fills the remaining secrets;
`cloudflare keys` copies the unified key to the DNS field). Pass `--domain
example.com` to derive the `dns.*` names. Any failing step stops the run.
`--cold` runs a precheck first that detects and removes any stale postal
containers and volumes (including the MariaDB volume) before standing up fresh;
`--yes` skips its confirmation prompt.

These are convenience tools for an operator on the host; they are not part of
the `./deploy.sh` command surface.

## Client onboarding

`./deploy.sh onboard --domain client.com [--org NAME] [--server-name NAME]
[--test-to you@example.com] [--no-test]` automates the whole flow for a
client domain: it ensures the organization and mail server, creates the domain
under the server, publishes and verifies its DNS records in Cloudflare, creates
an address endpoint (`receive@<domain>`) and a route to it, creates an API
credential, optionally sends an outbound test and an inbound loopback, then
prints a summary including the API credential key (use it as
`X-Server-API-Key` for the legacy send API). It is idempotent — existing pieces
are reused, not duplicated. Requires `POSTAL_API_TOKEN`, `CLOUDFLARE_API_TOKEN`
and `POSTAL_WEB_HOSTNAME` in `.env`.

For deliverability, the per-domain publish also writes a **DMARC** record at
`_dmarc.<domain>` (policy from `DNS_DMARC_POLICY`, default `p=none`). SPF and
DKIM can both pass while DMARC still fails without this record. Start at
`p=none` to gather aggregate reports, then tighten to `p=quarantine` and
`p=reject` once reports confirm no spoofing.

To further improve deliverability, compliance and reputation, the per-domain
publish optionally writes, when configured in `.env`:
- **TLS-RPT** (`_smtp.tls.<domain>`, from `DNS_TLS_RPT_RUA`) — receives reports
  on TLS/MTA-STS failures.
- **MTA-STS** (`_mta-sts.<domain>`, when `DNS_MTA_STS=true`) — requires the
  policy file to also be served over HTTPS at
  `https://mta-sts.<domain>/.well-known/mta-sts.txt`.
- **BIMI** (`default._bimi.<domain>`, from `DNS_BIMI_LOGO_URL`) — brand logo in
  supporting inboxes.
- **DMARC rua** (`DNS_DMARC_RUA`) and **SPF hardening** (`DNS_SPF_ALLOW=-all`,
  hardfail instead of the `~all` default).

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

**Inbound SMTP TLS is off by default.** `smtp_server.tls_enabled` is `false`, and
that is a defensible default rather than an omission: inbound mail on port 25 is
opportunistic, so a sender which cannot validate a session falls back to plaintext
and still delivers. Enabling it needs a certificate that something then renews, and
a renewal that nothing performs is an expiry that presents as senders quietly
downgrading — no error on this host. [`tls`](#7-tls--the-inbound-smtp-certificate)
implements the whole of it, including the timer, and that section is also where the
limits of the benefit are stated: it is not a deliverability fix.
**Outbound delivery is unaffected** either way: the worker negotiates STARTTLS with
remote servers itself, per their advertised capabilities.

**No MTA-STS policy is served.** The certificate `tls` obtains is a prerequisite for
MTA-STS but not the whole of it — the policy document has to be served over HTTPS at
`mta-sts.<domain>` and a `_mta-sts` TXT record published alongside it. Postal serves
neither, and the tunnel's ingress is configured for one hostname. Publishing a policy
in `enforce` mode without both would cause Gmail, Microsoft, Yahoo and Fastmail to
refuse to deliver here at all, which is worse than not publishing one.

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
| MariaDB logs `Access denied for user 'postal'` | The volume was initialized without the grant, or with an older password (the initdb.d script only runs on an empty volume) | `./deploy.sh migrate` reconciles the grants against `.env`; if its root auth fails, `./deploy.sh reset` to recreate the volume |
| Access logs and Authie show the tunnel's IP | `postal.trusted_proxies` does not cover the cloudflared subnet | Pin the subnet in all three places; `doctor` checks them |
| Web container permanently unhealthy, but `curl` inside works | The healthcheck is not setting `Host` | It does; if you edited it, `$$` is compose's escape for a literal `$` |
| Mail queues and never sends | Outbound port 25 blocked by the provider | Ask the provider. Nothing fails loudly when this is blocked |
| Mail sends but is rejected or spam-filtered | PTR missing or not matching `DNS_HELO_HOSTNAME` | Set the PTR at the provider; `doctor` verifies it |
| `EADDRNOTAVAIL` from the worker | An `IPAddress` is assigned but the worker is bridge-networked | Enable IP pools, or unassign the address |
| Scheduled tasks not running, delivery fine | No worker holds the `tasks` role | `doctor` distinguishes absent from stale; check the worker's log |
| DKIM fails at the recipient | `signing.key` not readable by uid 999, or the TXT record not published | `sudo chown 999:999`, then `./deploy.sh dns` and re-publish |
| `tls issue` fails with `invalidContact` | Let's Encrypt rejected `ACME_CONTACT_EMAIL`. It validates the domain against the public suffix list and refuses reserved names | Use a real address. The error arrives after the account key is created and does not name the address, so it reads like an account problem |
| `tls issue` fails creating the TXT record | `CLOUDFLARE_DNS_API_TOKEN` lacks Zone → DNS → Edit on the zone, or the name is not in a zone this account can write | Scope a token to the zone. The tunnel token is not a DNS credential and cannot be reused |
| `acme.sh: not found` from the client | Host state mounted at `/root/.acme.sh`, which holds the **program** — `/usr/local/bin/acme.sh` is a symlink into it | Mount at `/acme.sh`, as the compose file does |
| `tls renew` reports success but the certificate is unchanged | Not due yet. acme.sh returns its own code 2 for a skip, which `tls renew` reports as `ok` | Expected for about two thirds of timer runs. `tls renew --force` to override, `tls status` to see the expiry |
| `.env` says TLS is on but port 25 offers no STARTTLS | The container was `restart`ed, which reuses the original environment | `docker compose up -d --no-deps smtp`, which `tls install` does. `doctor` compares `.env` against the running container and fails on the difference |
| Senders silently fall back to plaintext | The certificate expired, presents no intermediate, or does not cover the MX name | `./deploy.sh tls status`, then `./deploy.sh doctor`. `server.rb` logs `SSL Negotiation Failed` at debug level, so nothing appears in production logs |
| `deploy.sh: command not found` on a copied tree | CRLF in the shebang; the kernel fails `execve` with ENOENT | `sed -i 's/\r$//' deploy.sh lib/*.sh`, or clone the repository instead of copying it |
| `./deploy.sh: Permission denied` | The executable bit did not survive the copy | `chmod +x deploy.sh`, or invoke it as `bash ./deploy.sh` |
