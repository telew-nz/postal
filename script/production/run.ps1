#Requires -Version 7

<#
.SYNOPSIS
    Brings up the production stack and runs every layer of the API test harness
    against it, in one command.

.DESCRIPTION
    Four stages run in order:

      bootstrap   bootstrap.ps1 writes .env, config/postal.yml and the DKIM
                  signing key if they are missing, builds the image, brings up
                  MariaDB and Puma, loads the schema, creates an administrator,
                  an organization, a server, one message and an API token, and
                  records all of it in tmp/production/credentials.json. It is
                  idempotent, so on a stack which already exists it changes
                  nothing.

      tokens      token-lifecycle.ps1 follows one concept -- the API token --
                  through creation, first use, last_used_at bookkeeping, expiry,
                  revocation and the four ways a request can be rejected. Token
                  handling is the part of the API where a mistake is a security
                  hole rather than a broken response, so it gets its own stage.

      sweep       api-sweep.ps1 reads the OpenAPI document the server is
                  actually serving at /api/v2/spec and walks every operation in
                  it over real HTTP. An operation added to the document appears
                  here on the next run with no edit to the script, and the
                  coverage report at the end names any operation not reached.

      crosscheck  crosscheck.ps1 drives a real browser and compares the two
                  surfaces against the same data: things created through the API
                  are found in the web UI, things created through a web UI form
                  are found through the API, and things deleted through one stop
                  being reported by the other.

    The first three stages answer "does the API do what its document says". Only
    the fourth can answer "does the API read and write the same data the web UI
    does", which is the question a wrapper API most often gets wrong: an endpoint
    can return 200 and a plausible body while addressing the wrong scope.

    A failing stage does not abort the run. The stages disagree in useful ways --
    a sweep which passes alongside a failing cross-check points at a scope or a
    serializer rather than at the document -- and seeing both at once is what
    distinguishes those cases. Failures are recorded, the remaining stages still
    execute, and the script exits non-zero at the end naming what failed.

    The one exception is bootstrap: with no stack there is nothing for the other
    three to talk to, so its failure stops the run immediately.

    Every stage's output is written to tmp/production/logs/<stage>.log and
    overwritten by the next run. The cross-check leaves a full page screenshot in
    tmp/production/crosscheck/ for each check which failed.

.PARAMETER SkipBootstrap
    Assume the stack is already up and credentials.json already exists. Use this
    to re-run the tests without touching the deployment.

.PARAMETER SkipBuild
    Passed to bootstrap.ps1: reuse images which have already been built.

.PARAMETER SkipCrosscheck
    Do not run the browser stage. Useful when Playwright is not installed, or
    when only the API's own behaviour is in question.

.PARAMETER Headed
    Passed to crosscheck.ps1: show the browser rather than running it headless.

.PARAMETER ReadOnly
    Passed to api-sweep.ps1: only exercise operations which cannot change
    anything. Use this against an installation whose data matters.

.PARAMETER Keep
    Passed to the test stages: leave the sandboxes and tokens they created in
    place so that they can be inspected by hand. cleanup.ps1 removes them later.

.PARAMETER Cleanup
    Run cleanup.ps1 afterwards to remove test residue, which is worth doing after
    a run which was interrupted rather than allowed to finish.

.PARAMETER LogDirectory
    Where the per stage logs are written.

.EXAMPLE
    ./script/production/run.ps1

.EXAMPLE
    # Re-run just the tests against the stack which is already up.
    ./script/production/run.ps1 -SkipBootstrap -SkipBuild

.EXAMPLE
    # Watch the browser, and keep the sandboxes afterwards.
    ./script/production/run.ps1 -SkipBootstrap -Headed -Keep
#>
[CmdletBinding()]
param(
    [switch] $SkipBootstrap,
    [switch] $SkipBuild,
    [switch] $SkipCrosscheck,
    [switch] $Headed,
    [switch] $ReadOnly,
    [switch] $Keep,
    [switch] $Cleanup,
    [string] $LogDirectory
)

# Native commands write progress to stderr, which PowerShell would turn into a
# terminating error under 'Stop'. Only cmdlets need that strictness here.
$ErrorActionPreference = "Continue"

Set-Location (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

if (-not $LogDirectory) { $LogDirectory = Join-Path "tmp" "production" "logs" }
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

$here = $PSScriptRoot
$credentialsPath = Join-Path "tmp" "production" "credentials.json"

# Each stage runs in its own PowerShell process. Calling the child with & would
# work most of the time, but these scripts all end in `exit`, and keeping the
# child in a separate process is what makes that unambiguously its own exit code
# rather than something the parent has to reason about.
$pwsh = (Get-Process -Id $PID).Path

function Write-Stage {
    param([string] $Name)

    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

# A stage which did not pass. Recorded rather than acted upon, so that the
# remaining stages still run and the summary at the end can name all of them.
$script:Failures = @()
$script:Skipped = @()
$script:Passed = @()
$script:StageCode = 0

function Note-Failure {
    param([string] $Name, [int] $Code, [string] $Log)

    Write-Host ""
    Write-Host "Stage '$Name' failed with exit code $Code; continuing." -ForegroundColor Red
    Write-Host "  full output in $Log" -ForegroundColor Red
    $script:Failures += $Name
}

function Invoke-Stage {
    param([string] $Name, [string] $Script, [string[]] $Arguments)

    Write-Stage $Name
    $log = Join-Path $LogDirectory "$Name.log"

    # The child's output is left on the output stream rather than sent to
    # Out-Host, so that a caller who redirects or pipes this script still sees
    # it. The exit code travels in a script scoped variable instead of as the
    # function's return value, because a return value would have to be piped
    # away at every call site and would take the stage's output with it.
    & $pwsh -NoProfile -File $Script @Arguments 2>&1 | Tee-Object -FilePath $log
    $script:StageCode = $LASTEXITCODE

    if ($script:StageCode -ne 0) {
        Note-Failure $Name $script:StageCode $log
    }
    else {
        $script:Passed += $Name
    }
}

function Test-Playwright {
    # crosscheck.ps1 sets NODE_PATH itself, and NODE_PATH is consulted by
    # require() only, which is why crosscheck.cjs is CommonJS. The probe has to
    # be run the same way or it will report a package as missing which the real
    # script would have found.
    if ($env:NODE_PATH) { return $true }
    $globalRoot = (& npm root -g 2>$null | Select-Object -Last 1)
    if (-not $globalRoot) { return $false }
    $env:NODE_PATH = $globalRoot.Trim()
    $probe = "try { require.resolve('playwright'); console.log('ok') } catch (e) { console.log('no') }"
    return ((& node -e $probe 2>$null) -join "") -match '^ok'
}

# ---------------------------------------------------------------------------

Write-Host "Postal management API test harness" -ForegroundColor White
Write-Host "logs go to $LogDirectory"

if (-not $SkipBootstrap) {
    $bootstrapArgs = @()
    if ($SkipBuild) { $bootstrapArgs += "-SkipBuild" }

    Write-Stage "bootstrap"
    $bootstrapLog = Join-Path $LogDirectory "bootstrap.log"
    & $pwsh -NoProfile -File (Join-Path $here "bootstrap.ps1") @bootstrapArgs 2>&1 |
        Tee-Object -FilePath $bootstrapLog

    # Unlike the test stages this one stops the run. Nothing else can proceed
    # without a server, a schema and a token, and three stages of connection
    # errors would say less than the bootstrap log already does.
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "bootstrap failed with exit code $LASTEXITCODE; not running the tests." -ForegroundColor Red
        Write-Host "  full output in $bootstrapLog" -ForegroundColor Red
        exit $LASTEXITCODE
    }
    $script:Passed += "bootstrap"
}

if (-not (Test-Path $credentialsPath)) {
    Write-Host ""
    Write-Host "$credentialsPath does not exist, so there is nothing to authenticate with." -ForegroundColor Red
    Write-Host "  run this script without -SkipBootstrap." -ForegroundColor Red
    exit 1
}

$testArgs = @()
if ($Keep) { $testArgs += "-Keep" }

Invoke-Stage "tokens" (Join-Path $here "token-lifecycle.ps1") $testArgs

$sweepArgs = @() + $testArgs
if ($ReadOnly) { $sweepArgs += "-ReadOnly" }
Invoke-Stage "sweep" (Join-Path $here "api-sweep.ps1") $sweepArgs

if ($SkipCrosscheck) {
    $script:Skipped += "crosscheck (asked to be skipped)"
}
elseif (-not (Test-Playwright)) {
    # Reported as skipped rather than failed. A missing browser is a property of
    # the machine running the harness and says nothing about the API, and
    # counting it as a failure would make this script unusable anywhere Node is
    # not set up -- including in CI images which only need the other stages.
    Write-Stage "crosscheck"
    Write-Host "Playwright is not resolvable, so the browser stage was skipped." -ForegroundColor Yellow
    Write-Host "  npm install -g playwright" -ForegroundColor Yellow
    Write-Host "  npx playwright install chromium" -ForegroundColor Yellow
    $script:Skipped += "crosscheck (Playwright is not installed)"
}
else {
    $crosscheckArgs = @()
    if ($Headed) { $crosscheckArgs += "-Headed" }
    Invoke-Stage "crosscheck" (Join-Path $here "crosscheck.ps1") $crosscheckArgs
}

if ($Cleanup) {
    # Not a stage: it removes residue rather than testing anything, and a
    # failure to remove something is reported by cleanup.ps1 itself.
    Write-Stage "cleanup"
    & $pwsh -NoProfile -File (Join-Path $here "cleanup.ps1") 2>&1 |
        Tee-Object -FilePath (Join-Path $LogDirectory "cleanup.log")
}

# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=== summary ===" -ForegroundColor Cyan
foreach ($name in $script:Passed) { Write-Host "  passed   $name" -ForegroundColor Green }
foreach ($name in $script:Skipped) { Write-Host "  skipped  $name" -ForegroundColor Yellow }
foreach ($name in $script:Failures) { Write-Host "  FAILED   $name" -ForegroundColor Red }

if ($script:Failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed stages: $($script:Failures -join ', ')" -ForegroundColor Red
    Write-Host "Their full output is in $LogDirectory, and the cross-check left a" -ForegroundColor Red
    Write-Host "screenshot of every failed check in tmp/production/crosscheck/." -ForegroundColor Red
    exit 1
}

Write-Host ""
if ($script:Skipped.Count -gt 0) {
    Write-Host "All stages which ran passed, but $($script:Skipped.Count) were skipped." -ForegroundColor Yellow
    exit 0
}
Write-Host "All stages passed." -ForegroundColor Green
exit 0
