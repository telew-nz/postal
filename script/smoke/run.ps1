#Requires -Version 7

<#
.SYNOPSIS
    Runs the end-to-end smoke test and the OpenAPI contract validation for the
    Postal management API.

.DESCRIPTION
    Boots a real Puma server in production mode against a real MariaDB, seeds it
    with an organization, a server and an API token, then drives the API over
    HTTP from a separate container.

    Two layers of checking run against that server:

      smoke     - script/smoke/run.rb walks every endpoint group, exercising the
                  full create/read/update/delete lifecycle and the error paths,
                  and records each response.

      contract  - Schemathesis fuzzes the documented GET operations looking for
                  server errors and schema violations, then
                  script/smoke/validate_contract.py replays everything the smoke
                  stage recorded against doc/api/openapi.yaml to prove that the
                  responses match what the document promises.

    The two layers disagree in a useful way. When the smoke stage passes and the
    contract stage fails, the API behaves correctly and the document describing
    it is wrong. When both fail on the same endpoint, the API is wrong. The
    stages therefore do not abort the run: a failure is recorded, the remaining
    stages still execute, and the script exits non-zero at the end.

    The contract stage reports how many of the documented operations the smoke
    stage reached, and lists any it did not. That number is the coverage figure
    to watch when an operation is added to doc/api/openapi.yaml.

    Schemathesis finishes with two warnings which are expected and are not
    failures: one because most operations return 404 for the random path
    parameters it generates, and one about the QUERY filter which
    docker-compose.smoke.yml explains.

    Set SCHEMATHESIS_MAX_TIME to give the fuzz run longer than its default 180
    seconds.

.PARAMETER Image
    Tag for the application image. Built with the 'ci' target by default because
    the API never renders a view, so precompiled assets are not needed.

.PARAMETER SkipBuild
    Reuse an image which has already been built.

.PARAMETER SkipSchemathesis
    Only run the deterministic contract check against the recorded traffic.

.PARAMETER Keep
    Leave the stack running afterwards so that it can be inspected.

.EXAMPLE
    ./script/smoke/run.ps1

.EXAMPLE
    ./script/smoke/run.ps1 -SkipBuild -Keep

.EXAMPLE
    # Only the deterministic half of the contract stage, with the stack left up
    # afterwards so that a failing request can be repeated by hand.
    ./script/smoke/run.ps1 -SkipBuild -SkipSchemathesis -Keep
#>
[CmdletBinding()]
param(
    [string] $Image = "postal-smoke:local",
    [switch] $SkipBuild,
    [switch] $SkipSchemathesis,
    [switch] $Keep
)

# Native commands write progress to stderr, which PowerShell would turn into a
# terminating error under 'Stop'. Only cmdlets need that strictness here.
$ErrorActionPreference = "Continue"

# Everything is relative to the repository root regardless of where this is
# invoked from.
Set-Location (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$composeFile = "docker-compose.smoke.yml"
$env:POSTAL_IMAGE = $Image
$env:SCHEMATHESIS_ENABLED = if ($SkipSchemathesis) { "0" } else { "1" }

function Write-Stage {
    param([string] $Name)

    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Stop-Stack {
    param([switch] $DumpLogs)

    if ($DumpLogs) {
        Write-Host ""
        Write-Host "=== postal logs ===" -ForegroundColor Yellow
        docker compose -f $composeFile logs --tail 150 postal
    }

    if ($Keep) {
        Write-Host ""
        Write-Host "Stack left running. Tear it down with:" -ForegroundColor Yellow
        Write-Host "  docker compose -f $composeFile down -v"
        return
    }

    Write-Host ""
    Write-Host "=== tearing down ===" -ForegroundColor Cyan
    docker compose -f $composeFile down -v --remove-orphans | Out-Null
}

function Fail-Stage {
    param([string] $Name, [int] $Code)

    Write-Host ""
    Write-Host "Stage '$Name' failed with exit code $Code." -ForegroundColor Red
    Stop-Stack -DumpLogs
    exit $Code
}

# Records a failing exit code without aborting, so that the remaining stages
# still run. A smoke assertion failure and a contract failure are diagnosed
# differently, and seeing both at once is what distinguishes a bug in the API
# from a bug in the document which describes it.
$script:StageFailures = @()

function Note-StageFailure {
    param([string] $Name, [int] $Code)

    Write-Host ""
    Write-Host "Stage '$Name' failed with exit code $Code; continuing." -ForegroundColor Red
    $script:StageFailures += "$Name ($Code)"
}

# ---------------------------------------------------------------------------

if (-not $SkipBuild) {
    Write-Stage "building $Image"
    # The 'ci' target skips asset precompilation. The API renders JSON only, so
    # there is nothing for the asset pipeline to do and skipping it saves
    # several minutes of build time.
    docker build --target ci -t $Image .
    if ($LASTEXITCODE -ne 0) { Fail-Stage "build" $LASTEXITCODE }
}

# Start from a clean slate so that a previous aborted run cannot interfere.
docker compose -f $composeFile down -v --remove-orphans | Out-Null

Write-Stage "starting MariaDB"
docker compose -f $composeFile up -d --wait mariadb
if ($LASTEXITCODE -ne 0) { Fail-Stage "mariadb" $LASTEXITCODE }

Write-Stage "loading the schema and seeding"
docker compose -f $composeFile run --rm -T init
if ($LASTEXITCODE -ne 0) { Fail-Stage "init" $LASTEXITCODE }

Write-Stage "starting the web server"
docker compose -f $composeFile up -d postal
if ($LASTEXITCODE -ne 0) { Fail-Stage "postal" $LASTEXITCODE }

Write-Stage "smoke test"
docker compose -f $composeFile run --rm -T smoke
if ($LASTEXITCODE -ne 0) { Note-StageFailure "smoke" $LASTEXITCODE }

Write-Stage "OpenAPI contract validation"
docker compose -f $composeFile run --rm -T -e SCHEMATHESIS_ENABLED contract
if ($LASTEXITCODE -ne 0) { Note-StageFailure "contract" $LASTEXITCODE }

Stop-Stack

if ($StageFailures.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed stages: $($StageFailures -join ', ')" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "All stages passed." -ForegroundColor Green
exit 0
