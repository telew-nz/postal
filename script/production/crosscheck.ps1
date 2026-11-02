#Requires -Version 7

<#
.SYNOPSIS
    Cross-checks the management API against the web UI, in both directions,
    using Playwright to drive a real browser.

.DESCRIPTION
    api-sweep.ps1 proves that every documented operation answers with a
    documented status and a well formed envelope. That is not the same as
    proving the endpoint reads and writes the same data the web UI does, and
    the difference is exactly where a wrapper API goes wrong: a serializer can
    invent a field, a scope can quietly address the wrong organization, a
    redaction can be applied in one place and not the other.

    This script therefore creates things through one surface and looks for them
    through the other, in both directions, and deletes through one and confirms
    the other stops reporting it. The sharpest checks are the credential ones,
    where the web UI prints the key in clear text, the API member endpoint
    returns it, and the API collection endpoint deliberately omits it: all three
    have to agree.

    The assertions themselves live in crosscheck.cjs, because a browser can only
    be driven from Node. This wrapper exists to make Playwright resolvable and
    to keep the entry point consistent with the other scripts in this directory.

    Playwright is expected to be installed globally:

        npm install -g playwright
        npx playwright install chromium

    NODE_PATH is set to the global module directory here because that is the
    only mechanism Node offers for resolving a package which is not in a local
    node_modules, and it is consulted by require() only. That is why
    crosscheck.cjs is CommonJS rather than an ES module.

    Failures leave a full page screenshot in tmp/production/crosscheck/.

.PARAMETER BaseUrl
    Overrides the base URL from the credentials file.

.PARAMETER Headed
    Show the browser instead of running it headless. Useful when a check fails
    and the screenshot is not enough.

.PARAMETER Credentials
    Path to the credentials file written by bootstrap.ps1.

.EXAMPLE
    ./script/production/crosscheck.ps1

.EXAMPLE
    ./script/production/crosscheck.ps1 -Headed
#>
[CmdletBinding()]
param(
    [string] $BaseUrl,
    [switch] $Headed,
    [string] $Credentials
)

$ErrorActionPreference = "Continue"

Set-Location (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$script = Join-Path "script" "production" "crosscheck.cjs"
if (-not (Test-Path $script)) {
    Write-Host "$script does not exist." -ForegroundColor Red
    exit 1
}

$credentialsPath = if ($Credentials) { $Credentials } else { Join-Path "tmp" "production" "credentials.json" }
if (-not (Test-Path $credentialsPath)) {
    Write-Host "$credentialsPath does not exist. Run script/production/bootstrap.ps1 first." -ForegroundColor Red
    exit 1
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "node is not on PATH." -ForegroundColor Red
    exit 1
}

# An explicit NODE_PATH is left alone, so that a local node_modules or a
# checkout of Playwright somewhere else still takes precedence.
if (-not $env:NODE_PATH) {
    $globalRoot = (& npm root -g 2>$null | Select-Object -Last 1)
    if (-not $globalRoot) {
        Write-Host "npm could not report its global module directory." -ForegroundColor Red
        exit 1
    }
    $env:NODE_PATH = $globalRoot.Trim()
}

$env:POSTAL_CREDENTIALS = $credentialsPath
if ($BaseUrl) { $env:POSTAL_BASE_URL = $BaseUrl.TrimEnd('/') }
if ($Headed) { $env:POSTAL_HEADED = "1" } else { Remove-Item Env:\POSTAL_HEADED -ErrorAction SilentlyContinue }

# Resolved here rather than left to Node so that a missing package is reported
# as "install Playwright" instead of a stack trace from inside crosscheck.cjs.
$probe = "try { require.resolve('playwright'); console.log('ok') } catch (e) { console.log(e.message) }"
$resolved = (& node -e $probe 2>&1) -join " "
if ($resolved -notmatch '^ok') {
    Write-Host "Playwright is not resolvable from NODE_PATH=$($env:NODE_PATH)." -ForegroundColor Red
    Write-Host "  $resolved" -ForegroundColor Red
    Write-Host ""
    Write-Host "  npm install -g playwright"
    Write-Host "  npx playwright install chromium"
    exit 1
}

& node $script
exit $LASTEXITCODE
