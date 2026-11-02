#Requires -Version 7

<#
.SYNOPSIS
    Stands up a persistent, production-mode Postal installation and publishes
    the credentials needed to drive its management API.

.DESCRIPTION
    This is the entry point for testing the API against something which behaves
    like a real deployment rather than the throwaway smoke stack.

    It is idempotent and safe to re-run. On the first invocation it writes the
    configuration the stack needs, builds the image, creates the schema, an
    administrator, an organization, a server, one message and a bootstrap API
    token. On later invocations it finds all of those again and leaves them
    alone, so any data created by hand or by an earlier test run survives.

    Three files are written, all of which are listed in .gitignore:

      .env                  secrets: RAILS_SECRET_KEY, the MariaDB root password
                            and the administrator password
      config/postal.yml     behavioural configuration, mounted at /config
      config/signing.key    a 2048 bit RSA key used for DKIM signing

    config/postal.yml and config/signing.key are also in .dockerignore, because
    the signing key is a secret and must not be baked into an image layer. The
    running containers read them from the ./config mount.

    The result is written to tmp/production/credentials.json, which is what
    token-lifecycle.ps1, api-sweep.ps1 and crosscheck.ps1 read. The bootstrap API
    token appears there only on the run which created it: only its SHA-256 digest
    is stored, so it cannot be recovered later. If the file is lost, revoke the
    token and re-run with -NewToken.

    This is the first stage of run.ps1, which calls it and then runs all three
    test scripts. Running it directly is for when only the deployment is in
    question; doc/api/testing.md describes the whole harness.

    The web server is published on 127.0.0.1:5000 only. There is no TLS in front
    of it, so it must not be exposed to the network.

.PARAMETER SkipBuild
    Reuse images which have already been built.

.PARAMETER NewToken
    Create an additional bootstrap token even though one already exists. Use this
    after losing tmp/production/credentials.json. The old token is left active,
    so revoke it through the API if it should no longer work.

.PARAMETER Down
    Stop the stack. The MariaDB volume is kept, so the next run resumes with all
    of its data.

.PARAMETER Reset
    Stop the stack and delete the MariaDB volume. Everything is destroyed and
    the next run builds the dataset from scratch.

.EXAMPLE
    ./script/production/bootstrap.ps1

.EXAMPLE
    # Rebuild the image after changing application code, without touching the
    # data. Rebuilding is the default, so this is the plain invocation.
    ./script/production/bootstrap.ps1

.EXAMPLE
    # Bring the stack up and run every test stage against it.
    ./script/production/run.ps1

.EXAMPLE
    ./script/production/bootstrap.ps1 -Reset
#>
[CmdletBinding()]
param(
    [string] $Image = "postal-production:local",
    [string] $BaseImage = "postal-base:local",
    [switch] $SkipBuild,
    [switch] $NewToken,
    [switch] $Down,
    [switch] $Reset
)

$ErrorActionPreference = "Continue"

Set-Location (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$composeFile = "docker-compose.production.yml"
# 'setup' is the profile which makes the one-shot bootstrap service targetable
# without `up -d` treating it as a long running one.
$compose = @("compose", "--profile", "setup", "-f", $composeFile)
$credentialsPath = Join-Path "tmp" "production" "credentials.json"
# Set from POSTAL_WEB_HOSTNAME once .env has been read. It cannot be hardcoded to
# 127.0.0.1: config/application.rb pushes postal.web_hostname onto config.hosts
# and nothing else, so ActionDispatch::HostAuthorization refuses any request
# whose Host header is not exactly that name -- including the loopback address
# when the hostname is 'localhost'.
$baseUrl = $null

function Write-Stage {
    param([string] $Name)

    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Stop-OnFailure {
    param([string] $Name, [int] $Code)

    Write-Host ""
    Write-Host "Stage '$Name' failed with exit code $Code." -ForegroundColor Red
    exit $Code
}

# 48 bytes of base64url. The restricted alphabet matters: docker compose reads
# .env literally, so a '+' or a quote in a value would be interpreted rather
# than passed through.
function New-Secret {
    $bytes = [byte[]]::new(48)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# Whole line comments and blank lines only. A '#' inside a value is left alone,
# which is enough for the one thing this is used for: recognising a
# config/postal.yml which an earlier version of this script wrote.
function Remove-YamlComments {
    param([string] $Text)
    return (($Text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }) -join "`n")
}

# Read .env into a hashtable, add any key which is missing and write it back.
# Existing values are never replaced: the MariaDB volume is initialised with the
# root password from the first run, so changing it afterwards would leave the
# server unable to connect to a database which still has the old one.
function Initialize-EnvFile {
    $values = @{}
    if (Test-Path ".env") {
        foreach ($line in Get-Content ".env") {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
                $values[$Matches[1]] = $Matches[2]
            }
        }
    }

    # An earlier version of this script generated SECRET_KEY_BASE, which Postal
    # never reads. config/initializers/secret_key.rb takes the value from
    # Postal::Config.rails.secret_key, whose environment variable is
    # RAILS_SECRET_KEY; with neither set it falls back to SecureRandom.hex, so
    # every container got a different key and each restart invalidated every
    # session. Carry an existing value across rather than generating a new one,
    # so that upgrading a running stack does not log anyone out.
    if ($values["SECRET_KEY_BASE"] -and -not $values["RAILS_SECRET_KEY"]) {
        $values["RAILS_SECRET_KEY"] = $values["SECRET_KEY_BASE"]
        $values.Remove("SECRET_KEY_BASE")
        Write-Host "  renamed SECRET_KEY_BASE to RAILS_SECRET_KEY in .env"
    }

    $generated = @()
    foreach ($key in @("RAILS_SECRET_KEY", "MAIN_DB_PASSWORD", "POSTAL_ADMIN_PASSWORD")) {
        if (-not $values[$key]) {
            $values[$key] = New-Secret
            $generated += $key
        }
    }
    if (-not $values["POSTAL_WEB_HOSTNAME"]) { $values["POSTAL_WEB_HOSTNAME"] = "localhost" }

    $body = @(
        "# Generated by script/production/bootstrap.ps1. Listed in .gitignore.",
        "# Values are only ever added, never replaced, because the MariaDB volume",
        "# is initialised with the password from the first run."
    )
    foreach ($key in ($values.Keys | Sort-Object)) {
        $body += "$key=$($values[$key])"
    }

    # LF rather than CRLF: docker compose tolerates both but a stray carriage
    # return ends up inside the value on some versions.
    [IO.File]::WriteAllText((Join-Path (Get-Location) ".env"), ($body -join "`n") + "`n")

    if ($generated.Count -gt 0) {
        Write-Host "  wrote .env (generated: $($generated -join ', '))"
    }
    else {
        Write-Host "  .env already complete"
    }

    return $values
}

function Initialize-Config {
    New-Item -ItemType Directory -Path "config" -Force | Out-Null

    if (-not (Test-Path "config/signing.key")) {
        Write-Host "  generating a DKIM signing key"
        # Not the fixture in docker/ci-config, which is committed and therefore
        # not secret. A real installation signs outgoing mail with this key and
        # publishes the matching public half as a DNS TXT record.
        & openssl genrsa -out "config/signing.key" 2048 2>$null
        if ($LASTEXITCODE -ne 0) { Stop-OnFailure "signing key" $LASTEXITCODE }
    }
    else {
        Write-Host "  config/signing.key already exists"
    }

    # Only behaviour lives here. Everything host specific or secret -- the
    # database credentials, RAILS_SECRET_KEY, the bind address and the web
    # hostname -- is supplied as an environment variable by
    # docker-compose.production.yml, which takes precedence over this file.
    $marker = "# Generated by script/production/bootstrap.ps1"
    $yaml = @'
# Generated by script/production/bootstrap.ps1. Listed in .gitignore.
#
# The `version: 2` key below is load bearing rather than decorative. Without it
# Postal::Config treats the file as the legacy v1 format and reads it through
# LegacyConfigSource, which maps v1 names -- web.protocol, general.use_ip_pools,
# web_server.bind_address -- onto the current schema. None of the v2 names used
# here appear in that mapping, so every one of them is ignored: the defaults
# apply and nothing reports an error. An earlier version of this script wrote the
# file without the key, which is how web_protocol came to be https on a stack
# that only serves plain http.
version: 2

postal:
  # Plain HTTP, because there is no TLS terminator in front of this stack. This
  # has to be right: redirect_to_with_json runs its argument through url_for, so
  # an https protocol here makes every remote form in the web UI redirect to a
  # URL this server cannot answer.
  # web_hostname comes from POSTAL_WEB_HOSTNAME: config/application.rb adds it
  # to config.hosts and ActionDispatch::HostAuthorization answers 403 to any
  # request whose Host header does not match.
  web_protocol: http
  use_ip_pools: false
  # Resolves to the ./config mount, which is where bootstrap.ps1 put the key.
  signing_key_path: /config/signing.key

api:
  enabled: true
  max_per_page: 250

web_server:
  default_bind_address: 0.0.0.0
  default_port: 5000
  max_threads: 5

rails:
  environment: production

# Message inspection is off. rspamd, SpamAssassin and ClamAV are separate
# services which this stack does not run, and enabling them would make the
# worker try to reach hosts which do not exist.
rspamd:
  enabled: false
spamd:
  enabled: false
clamav:
  enabled: false
'@
    $yaml = ($yaml -replace "`r`n", "`n")

    if (-not (Test-Path "config/postal.yml")) {
        Write-Host "  writing config/postal.yml"
        [IO.File]::WriteAllText((Join-Path (Get-Location) "config/postal.yml"), $yaml)
    }
    else {
        $existing = (Get-Content "config/postal.yml" -Raw) -replace "`r`n", "`n"
        # The version key is what is missing from the file being recognised, so
        # it has to be left out of the comparison.
        $generated = (Remove-YamlComments $yaml) -replace "(?m)^version:.*\n", ""
        if ($existing -match '(?m)^\s*version:') {
            Write-Host "  config/postal.yml already exists"
        }
        elseif ($existing.Contains($marker) -or (Remove-YamlComments $existing) -eq $generated) {
            # Written by an earlier version of this script, so it is safe to
            # replace: it is being ignored in its entirety anyway. The content
            # comparison catches the files written before the marker was
            # introduced, which carry nothing to identify them.
            Write-Host "  config/postal.yml had no 'version: 2' key and was being ignored; rewrote it" -ForegroundColor Yellow
            [IO.File]::WriteAllText((Join-Path (Get-Location) "config/postal.yml"), $yaml)
        }
        else {
            # Hand written, so report it rather than overwriting someone's work.
            Write-Host "  WARNING: config/postal.yml has no 'version: 2' key." -ForegroundColor Yellow
            Write-Host "  Postal will parse it as the legacy v1 format, whose key names differ, and" -ForegroundColor Yellow
            Write-Host "  silently ignore every setting in it. Add 'version: 2' as the first key." -ForegroundColor Yellow
        }
    }
}

function Read-Credentials {
    if (Test-Path $credentialsPath) {
        try { return (Get-Content $credentialsPath -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

# The healthcheck only proves that MariaDB is answering, not that it will accept
# the password in .env. The two can disagree whenever the volume outlives the
# file which describes it: the entrypoint sets the root password only when it
# initialises an empty datadir, so a .env which is later lost or edited leaves
# the volume holding the old one. Without this check that surfaces as a hundred
# lines of ActiveRecord backtrace from db:create. The password travels in an
# environment variable rather than on the client's command line, so that it is
# not visible in the container's process list. It has to be MYSQL_PWD: this
# client does not read the MARIADB_PWD spelling and silently sends no password
# at all, which looks exactly like a mismatch. The retry is because the
# healthcheck can report the server ready while the entrypoint is still running
# its initialisation pass against a temporary socket-only server.
function Test-DatabasePassword {
    param([string] $Password, [int] $Timeout = 90)

    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        docker @compose exec -T -e "MYSQL_PWD=$Password" mariadb mariadb --user=root --execute="SELECT 1" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Wait-ForApi {
    param([int] $Timeout = 180)

    Write-Host "  waiting for $baseUrl/api/v2/spec"
    $deadline = (Get-Date).AddSeconds($Timeout)
    $lastStatus = 0
    while ((Get-Date) -lt $deadline) {
        try {
            # -SkipHttpErrorCheck so that a 403 is reported as a status rather
            # than thrown, which is the difference between a useful diagnosis and
            # a two minute timeout.
            $response = Invoke-WebRequest -Uri "$baseUrl/api/v2/spec" -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck
            $lastStatus = $response.StatusCode
            if ($lastStatus -eq 200) {
                Write-Host ""
                Write-Host "  up" -ForegroundColor Green
                return $true
            }
        }
        catch {
            # not accepting connections yet
            $lastStatus = 0
        }
        Start-Sleep -Seconds 2
        Write-Host "." -NoNewline
    }

    Write-Host ""
    if ($lastStatus -eq 403) {
        $hostHeader = ([Uri]$baseUrl).Host
        Write-Host "  the server is running but answered 403 to a Host header of '$hostHeader'." -ForegroundColor Red
        Write-Host "  config.hosts contains only postal.web_hostname, which is currently"
        Write-Host "  '$($envValues['POSTAL_WEB_HOSTNAME'])'. Set POSTAL_WEB_HOSTNAME in .env to the name"
        Write-Host "  you intend to use, then re-run this script."
        return $false
    }
    if ($lastStatus -ne 0) {
        Write-Host "  the server answered $lastStatus rather than 200." -ForegroundColor Red
    }
    else {
        Write-Host "  the web server did not accept connections within ${Timeout}s." -ForegroundColor Red
    }

    # Piped to Out-Host so that the log text is shown without becoming part of
    # this function's return value, which the caller tests as a boolean.
    docker @compose logs --tail 80 postal | Out-Host
    return $false
}

# Merge what the bootstrap script reported into tmp/production/credentials.json.
#
# The token needs care. bootstrap.rb only prints a plain key on the run which
# created it, because only the digest is stored, so a later run reports null and
# the value already on disk has to be kept. If both are missing there is no way
# to recover: the token must be recreated with -NewToken.
function Write-Credentials {
    param($Bootstrap)

    $existing = Read-Credentials
    $token = $Bootstrap.token
    if (-not $token) { $token = $existing.token }

    if (-not $token) {
        Write-Host ""
        Write-Host "A bootstrap token already exists but its plain key is not known." -ForegroundColor Red
        Write-Host "Only the digest of a token is stored, so it cannot be recovered."
        Write-Host "Re-run with -NewToken to create another one."
        exit 1
    }

    $adminPassword = $Bootstrap.admin_password
    if (-not $adminPassword) { $adminPassword = $envValues["POSTAL_ADMIN_PASSWORD"] }

    $credentials = [ordered]@{
        base_url                 = $baseUrl
        token                    = $token
        token_uuid               = $Bootstrap.token_uuid
        admin_email              = $Bootstrap.admin_email
        # Needed by crosscheck.ps1, which logs into the web UI as this user.
        admin_password           = $adminPassword
        organization_permalink   = $Bootstrap.organization_permalink
        server_permalink         = $Bootstrap.server_permalink
        server_id                = $Bootstrap.server_id
        message_id               = $Bootstrap.message_id
        # The API can list IP pools but not create them, so api-sweep.ps1 needs
        # one to exist before it can exercise the ip_pool_rules operations.
        ip_pool_id               = $Bootstrap.ip_pool_id
    }

    New-Item -ItemType Directory -Path (Split-Path $credentialsPath) -Force | Out-Null
    $json = ($credentials | ConvertTo-Json -Depth 4)
    [IO.File]::WriteAllText((Join-Path (Get-Location) $credentialsPath), $json + "`n")

    $created = @()
    if ($Bootstrap.created.user) { $created += "admin user" }
    if ($Bootstrap.created.organization) { $created += "organization" }
    if ($Bootstrap.created.server) { $created += "server" }
    if ($Bootstrap.created.ip_pool) { $created += "IP pool" }
    if ($Bootstrap.created.token) { $created += "API token" }

    if ($created.Count -gt 0) {
        Write-Host "  created: $($created -join ', ')"
    }
    else {
        Write-Host "  nothing to create, the existing dataset was reused"
    }
    Write-Host "  wrote $credentialsPath"
}

# ---------------------------------------------------------------------------

if ($Down -or $Reset) {
    Write-Stage "stopping the stack"
    docker @compose down
    if ($Reset) {
        Write-Host "  removing the MariaDB volume" -ForegroundColor Yellow
        docker @compose down -v
        if (Test-Path $credentialsPath) { Remove-Item $credentialsPath }
    }
    exit 0
}

Write-Stage "configuration"
$envValues = Initialize-EnvFile
Initialize-Config

# Exported so that the `docker compose run` below can pass them into the
# bootstrap script, which needs the administrator password to create the user.
$env:POSTAL_ADMIN_PASSWORD = $envValues["POSTAL_ADMIN_PASSWORD"]
$env:POSTAL_ADMIN_EMAIL = if ($envValues["POSTAL_ADMIN_EMAIL"]) { $envValues["POSTAL_ADMIN_EMAIL"] } else { "admin@localhost" }
$baseUrl = "http://$($envValues['POSTAL_WEB_HOSTNAME']):5000"
# Tells bootstrap.rb to create a fresh token even though an active one already
# exists, which is the only way to get a plain key back after losing the
# credentials file.
$env:POSTAL_FORCE_NEW_TOKEN = if ($NewToken) { "1" } else { "" }
$env:POSTAL_IMAGE = $Image

if (-not $SkipBuild) {
    Write-Stage "building $BaseImage"
    # The base stage only. The upstream `full` target cannot be used from a
    # Windows checkout because it precompiles assets before anything has had a
    # chance to fix the CRLF line endings in bin/rake.
    docker build --target base -t $BaseImage .
    if ($LASTEXITCODE -ne 0) { Stop-OnFailure "base build" $LASTEXITCODE }

    Write-Stage "building $Image"
    docker build -f Dockerfile.production --build-arg BASE_IMAGE=$BaseImage -t $Image .
    if ($LASTEXITCODE -ne 0) { Stop-OnFailure "production build" $LASTEXITCODE }
}

Write-Stage "starting MariaDB"
docker @compose up -d --wait mariadb
if ($LASTEXITCODE -ne 0) { Stop-OnFailure "mariadb" $LASTEXITCODE }

if (-not (Test-DatabasePassword $envValues["MAIN_DB_PASSWORD"])) {
    Write-Host ""
    Write-Host "MariaDB refused the password in .env." -ForegroundColor Red
    Write-Host "  The postal-data volume was initialised with a different one, and MariaDB only"
    Write-Host "  sets the root password when it creates an empty datadir. Either put the"
    Write-Host "  original value back into MAIN_DB_PASSWORD, or discard the volume with:"
    Write-Host ""
    Write-Host "      ./script/production/bootstrap.ps1 -Reset"
    Write-Host ""
    Write-Host "  -Reset deletes every organization, server, message and token in this stack."
    exit 1
}
Write-Host "  MariaDB accepted the password in .env"

Write-Stage "initialising the schema and the dataset"
$bootstrapOutput = docker @compose run --rm bootstrap 2>&1
if ($LASTEXITCODE -ne 0) {
    $bootstrapOutput | ForEach-Object { Write-Host $_ }
    Stop-OnFailure "bootstrap" $LASTEXITCODE
}

# The bootstrap script prints one JSON line behind a marker so that it can be
# separated from the Rails and rake output around it.
$marker = ($bootstrapOutput | Select-String -Pattern '^POSTAL_BOOTSTRAP ' | Select-Object -Last 1)
if (-not $marker) {
    $bootstrapOutput | ForEach-Object { Write-Host $_ }
    Write-Host ""
    Write-Host "bootstrap produced no POSTAL_BOOTSTRAP line." -ForegroundColor Red
    exit 1
}
$bootstrap = ($marker.Line -replace '^POSTAL_BOOTSTRAP ', '') | ConvertFrom-Json

Write-Credentials -Bootstrap $bootstrap

Write-Stage "starting the web server"
docker @compose up -d postal
if ($LASTEXITCODE -ne 0) { Stop-OnFailure "postal" $LASTEXITCODE }

if (-not (Wait-ForApi)) { exit 1 }

Write-Host ""
Write-Host "Ready." -ForegroundColor Green
Write-Host "  API      $baseUrl/api/v2"
Write-Host "  OpenAPI  $baseUrl/api/v2/spec   (unauthenticated)"
Write-Host "  Web UI   $baseUrl/               ($($bootstrap.admin_email))"
Write-Host "  Creds    $credentialsPath"
exit 0
