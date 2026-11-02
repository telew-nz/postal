#Requires -Version 7

<#
.SYNOPSIS
    Runs RuboCop and RSpec against the working tree, from a checkout that cannot
    run them natively.

.DESCRIPTION
    On Windows neither suite can be run directly: there is no MSYS2 toolchain for
    the native gem extensions, and `bundle exec` reports the whole Gemfile as
    missing. This runs them inside the CI image instead, on the CI compose network
    so that the MariaDB the suite expects is reachable by the hostname it expects.

    The working tree is mounted read-only and copied into the container by
    script/test/container.sh rather than being mounted over the application
    directory. The application is at /opt/postal/app, which is also first on PATH,
    so mounting the tree anywhere else leaves the image's own stale copy in charge
    -- and that copy has CRLF binstubs which fail with a misleading
    "/usr/bin/env: 'ruby\r'" error. The mount is read-only because an earlier
    version of the wrapper normalized line endings in place and rewrote several
    hundred host files doing it.

    Four specs in spec/lib/dns_resolver_spec.rb perform live reverse DNS lookups
    and fail wherever the container cannot resolve a PTR record. That is
    environmental, not a regression, and is the most likely cause of a non-zero
    exit from an otherwise healthy tree.

.PARAMETER Image
    Tag for the CI image. Built with the Dockerfile's 'ci' target if absent.

.PARAMETER SkipBuild
    Reuse the image even if it could be rebuilt. The build takes several minutes.

.PARAMETER RuboCopOnly
    Run only RuboCop.

.PARAMETER RSpecOnly
    Run only RSpec.

.PARAMETER KeepDatabase
    Leave the CI MariaDB running afterwards, for a follow-up invocation.

.EXAMPLE
    ./script/test/run.ps1

.EXAMPLE
    ./script/test/run.ps1 -RSpecOnly -SkipBuild
#>

param(
    [string] $Image = "postal-ci:local",
    [switch] $SkipBuild,
    [switch] $RuboCopOnly,
    [switch] $RSpecOnly,
    [switch] $KeepDatabase
)

$ErrorActionPreference = "Continue"

# Two levels up: script/test/ -> repository root.
Set-Location (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$root = (Get-Location).Path
$wrapper = Join-Path $root "script\test\container.sh"
$compose = @("-f", "docker-compose.yml", "-p", "postal-test")

# Every docker compose invocation needs this, including `down`: without it the
# postal service has neither an image nor a build context and compose refuses to
# parse the project at all.
$env:POSTAL_IMAGE = $Image

if (-not (Test-Path $wrapper)) {
    Write-Host "missing $wrapper" -ForegroundColor Red
    exit 1
}

function Write-Stage {
    param([string] $Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

$failures = @()
$rspecFailed = $false

if (-not $SkipBuild) {
    $present = docker image inspect $Image --format '{{.Id}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $present) {
        Write-Stage "building $Image"
        docker build --target ci -t $Image .
        if ($LASTEXITCODE -ne 0) {
            Write-Host "image build failed" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "$Image already present, not rebuilding (-SkipBuild to say so explicitly)"
    }
}

Write-Stage "starting the CI MariaDB"
docker compose @compose up -d mariadb
if ($LASTEXITCODE -ne 0) {
    Write-Host "could not start mariadb" -ForegroundColor Red
    exit 1
}

# mariadb-admin ping answers as soon as the server accepts a connection, which
# happens before InnoDB has finished initializing, and a suite started in that
# window fails in ways that look like application bugs. The image ships a
# healthcheck which waits for both.
$ready = $false
for ($attempt = 1; $attempt -le 60; $attempt++) {
    docker compose @compose exec -T mariadb `
        /usr/local/bin/healthcheck.sh --connect --innodb_initialized 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 2
}

if (-not $ready) {
    Write-Host "mariadb did not become ready" -ForegroundColor Red
    docker compose @compose logs --tail 40 mariadb
    docker compose @compose down --remove-orphans | Out-Null
    exit 1
}
Write-Host "mariadb ready after $($attempt * 2)s"

$script:SuiteCode = 0

function Invoke-Suite {
    param([string] $Name, [string[]] $Command)

    Write-Stage $Name

    # The wrapper arrives with CRLF, so it cannot be executed directly: it is
    # stripped into the container's own filesystem, which is writable, rather than
    # into the read-only mount.
    $prelude = "tr -d '\r' < /container.sh > /tmp/suite.sh && bash /tmp/suite.sh"
    $mounts = @("-v", "${root}:/src:ro", "-v", "${wrapper}:/container.sh:ro")

    # The suite's output has to stay on the output stream so that it reaches the
    # console and any redirect, which means the exit code cannot be the return
    # value: assigning the call would capture the output instead of the code.
    docker compose @compose run --rm -T --entrypoint /bin/bash `
        @mounts postal -c "$prelude $($Command -join ' ')"
    $script:SuiteCode = $LASTEXITCODE
}

if (-not $RSpecOnly) {
    Invoke-Suite "rubocop" @("bundle", "exec", "rubocop", "--format", "simple", "--force-exclusion")
    if ($script:SuiteCode -ne 0) { $failures += "rubocop ($($script:SuiteCode))" }
}

if (-not $RuboCopOnly) {
    Invoke-Suite "rspec" @("bundle", "exec", "rspec")
    if ($script:SuiteCode -ne 0) {
        $failures += "rspec ($($script:SuiteCode))"
        $rspecFailed = $true
    }
}

if (-not $KeepDatabase) {
    Write-Stage "stopping the CI MariaDB"
    docker compose @compose down --remove-orphans | Out-Null
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Failed: $($failures -join ', ')" -ForegroundColor Red

    # Only worth saying when RSpec ran. Attached to a RuboCop failure it points
    # at a file that has nothing to do with the offenses just reported.
    if ($rspecFailed) {
        Write-Host "If the only failures are in spec/lib/dns_resolver_spec.rb, they are"
        Write-Host "live reverse DNS lookups and are environmental."
    }
    exit 1
}
Write-Host "Both suites passed." -ForegroundColor Green
exit 0
