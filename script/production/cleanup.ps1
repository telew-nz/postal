#Requires -Version 7

<#
.SYNOPSIS
    Removes the resources a production test run leaves behind.

.DESCRIPTION
    api-sweep.ps1 deletes its own sandbox, token-lifecycle.ps1 revokes its own
    tokens and crosscheck.ps1 tears its own organization down, so none of them
    needs this in a normal run. It exists for the run which did not finish: an
    interrupted sweep leaves an organization behind, and because
    Organization#soft_destroy keeps the row -- and the permalink with it, which
    is validated as globally unique -- the next run cannot reuse the name and is
    refused with "Short name has already been taken".

    Everything it removes is matched on the name prefixes the test scripts use,
    so the bootstrap organization, its server, its message and the bootstrap token
    are never touched. Run it against an installation whose data matters only
    after reading the prefix filters below.

    Tokens matter most here. Both test scripts revoke what they create, and
    token-lifecycle.ps1 does so even when an assertion fails -- but a run which
    is killed outright leaves an active token behind, and an unreferenced working
    credential is the one kind of residue which is a security problem rather than
    clutter.

.PARAMETER BaseUrl
    Overrides the base URL from the credentials file.

.PARAMETER Prefixes
    The name prefixes to treat as test residue. Defaults to the ones
    api-sweep.ps1, token-lifecycle.ps1 and crosscheck.ps1 generate.

.EXAMPLE
    ./script/production/cleanup.ps1

.EXAMPLE
    ./script/production/cleanup.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $BaseUrl,
    [string[]] $Prefixes = @("sweep-", "lifecycle-", "xcheck-")
)

$ErrorActionPreference = "Continue"

Set-Location (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$credentialsPath = Join-Path "tmp" "production" "credentials.json"
if (-not (Test-Path $credentialsPath)) {
    Write-Host "$credentialsPath does not exist. Run script/production/bootstrap.ps1 first." -ForegroundColor Red
    exit 1
}
$credentials = Get-Content $credentialsPath -Raw | ConvertFrom-Json
if (-not $BaseUrl) { $BaseUrl = $credentials.base_url }
$BaseUrl = $BaseUrl.TrimEnd('/')

$header = "X-Postal-API-Key"
$token = $credentials.token
$bodyFile = [IO.Path]::GetTempFileName()

# A jq fragment which is true when a string starts with any of the prefixes.
# Built once here rather than interpolated into each filter below. Single quoted
# strings throughout: jq filters need literal double quotes and backslashes, and
# in PowerShell a backslash is not an escape character, so `"` inside a double
# quoted string ends it rather than quoting anything.
$startsWithAny = (@($Prefixes | ForEach-Object { 'startswith("' + $_ + '")' }) -join ' or ')

function Invoke-Api {
    param([string] $Method = "GET", [string] $Path, [object] $Body)

    $curl = @("-s", "-X", $Method, "-H", "Accept: application/json",
              "-H", "${header}: $token", "-w", "`n%{http_code}")
    if ($null -ne $Body) {
        [IO.File]::WriteAllText($bodyFile, ($Body | ConvertTo-Json -Depth 8 -Compress))
        $curl += @("-H", "Content-Type: application/json", "--data", "@$bodyFile")
    }

    $raw = @(& curl.exe @curl "$BaseUrl$Path" 2>$null)
    $status = 0
    $text = ""
    if ($raw.Count -ge 1) {
        $tail = [string]$raw[-1]
        if ($tail -match '^(\d+)$') {
            $status = [int]$Matches[1]
            if ($raw.Count -gt 1) { $text = ($raw[0..($raw.Count - 2)] -join "`n") }
        }
    }
    return [pscustomobject]@{ Status = $status; Body = $text }
}

function Read-Jq {
    param([string] $Json, [string] $Filter)

    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
    return @($Json | jq -r $Filter 2>$null | Where-Object { $_ -and $_ -ne "null" })
}

try {
    Write-Host "Cleaning up test residue on $BaseUrl" -ForegroundColor White
    Write-Host "matching $($Prefixes -join ', '); the bootstrap organization '$($credentials.organization_permalink)' and its token are not touched"
    Write-Host ""

    # An organization is deleted with confirm_text echoing its name, the same
    # guard the web UI applies. Without it the request is refused with a 422
    # which looks like success next to the 204 the other deletes return.
    $orgs = Invoke-Api -Path "/api/v2/organizations"
    $leftovers = Read-Jq $orgs.Body ('.data[] | select(.permalink | ' + $startsWithAny + ') | .permalink')
    if ($leftovers.Count -eq 0) { Write-Host "  no leftover organizations" }
    foreach ($org in $leftovers) {
        $servers = Invoke-Api -Path "/api/v2/organizations/$org/servers"
        $rows = Read-Jq $servers.Body '.data[] | "\(.permalink)\t\(.name)"'
        foreach ($row in $rows) {
            $parts = $row -split "`t"
            if ($PSCmdlet.ShouldProcess("$org/$($parts[0])", "delete server")) {
                $r = Invoke-Api -Method DELETE -Path "/api/v2/organizations/$org/servers/$($parts[0])" -Body @{ confirm_text = $parts[1] }
                Write-Host "  server $($parts[0]) -> $($r.Status)"
            }
        }

        $detail = Invoke-Api -Path "/api/v2/organizations/$org"
        $name = (Read-Jq $detail.Body '.data.name') -join ''
        if ($PSCmdlet.ShouldProcess($org, "delete organization")) {
            $r = Invoke-Api -Method DELETE -Path "/api/v2/organizations/$org" -Body @{ confirm_text = $name }
            Write-Host "  organization $org -> $($r.Status)"
        }
    }

    # Rules the sweep creates live on the bootstrap organization, because a rule
    # has to reference a pool belonging to its own organization and only the
    # bootstrap one has any. A sweep which was interrupted between creating and
    # deleting them leaves them there.
    $rules = Invoke-Api -Path "/api/v2/organizations/$($credentials.organization_permalink)/ip_pool_rules"
    $ruleRows = Read-Jq $rules.Body ('.data[] | select(.from_text | ' + $startsWithAny + ') | "\(.uuid)\t\(.from_text)"')
    if ($ruleRows.Count -eq 0) { Write-Host "  no leftover IP pool rules" }
    foreach ($row in $ruleRows) {
        $parts = $row -split "`t"
        if ($PSCmdlet.ShouldProcess($parts[1], "delete IP pool rule")) {
            $r = Invoke-Api -Method DELETE -Path "/api/v2/organizations/$($credentials.organization_permalink)/ip_pool_rules/$($parts[0])"
            Write-Host "  ip pool rule $($parts[1]) -> $($r.Status)"
        }
    }

    $tokens = Invoke-Api -Path "/api/v2/tokens"
    $tokenRows = Read-Jq $tokens.Body ('.data[] | select(.revoked_at == null) | select(.name | ' + $startsWithAny + ') | "\(.uuid)\t\(.name)"')
    if ($tokenRows.Count -eq 0) { Write-Host "  no leftover tokens" }
    foreach ($row in $tokenRows) {
        $parts = $row -split "`t"
        if ($PSCmdlet.ShouldProcess($parts[1], "revoke token")) {
            $r = Invoke-Api -Method DELETE -Path "/api/v2/tokens/$($parts[0])"
            Write-Host "  token $($parts[1]) -> $($r.Status)"
        }
    }

    Write-Host ""
    $after = Invoke-Api -Path "/api/v2/organizations"
    Write-Host "  organizations now: $((Read-Jq $after.Body '.data[].permalink') -join ', ')"
    $afterTokens = Invoke-Api -Path "/api/v2/tokens"
    Write-Host "  active tokens now: $((Read-Jq $afterTokens.Body '.data[] | select(.revoked_at == null) | .name') -join ', ')"
}
finally {
    # -WhatIf and -Confirm propagate to every cmdlet in scope, including this
    # one, so a dry run would otherwise leave its temporary request body on disk.
    Remove-Item $bodyFile -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
}
