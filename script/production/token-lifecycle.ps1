#Requires -Version 7

<#
.SYNOPSIS
    Exercises the full lifecycle of a Postal API token against the running
    production stack using curl, parsing every response with jq.

.DESCRIPTION
    The smoke suite asserts that each endpoint answers with the right shape.
    This script does something different: it follows one concept -- the API
    token -- through everything that can happen to it, because token handling is
    the one part of the API where a mistake is a security hole rather than a
    broken response.

    It covers creation, the single opportunity to read the plain key, first use,
    the last_used_at bookkeeping, expiry (valid, malformed and already elapsed),
    revocation, and the four ways a request can be rejected. Every token it
    creates is revoked again before it exits, including when an assertion fails,
    so a partial run does not leave working credentials behind.

    The bootstrap token from tmp/production/credentials.json is used to
    authenticate but is never revoked: it is what every other script depends on,
    and revoking it would lock the whole harness out.

    Requests are made with curl.exe and responses are parsed with jq.exe. Both
    are expected to be on PATH.

.PARAMETER BaseUrl
    Overrides the base URL from the credentials file.

.PARAMETER Keep
    Leave the tokens this script created active instead of revoking them, so
    that they can be inspected by hand afterwards.

.EXAMPLE
    ./script/production/token-lifecycle.ps1

.EXAMPLE
    ./script/production/token-lifecycle.ps1 -Keep
#>
[CmdletBinding()]
param(
    [string] $BaseUrl,
    [switch] $Keep
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

# The header must match API::V2::BaseController::API_TOKEN_HEADER.
$header = "X-Postal-API-Key"

# Every token this script creates, so that the cleanup at the end can revoke all
# of them even if an assertion failed part way through.
$created = [System.Collections.Generic.List[object]]::new()

$script:passed = 0
$script:failures = [System.Collections.Generic.List[string]]::new()

# Names are suffixed with the process id so that two runs cannot collide and so
# that anything left behind by an interrupted run is easy to recognise.
$run = "lifecycle-$PID"

function Write-Section {
    param([string] $Name)

    Write-Host ""
    Write-Host "== $Name ==" -ForegroundColor Cyan
}

function Confirm-That {
    param([string] $What, [bool] $Condition, [string] $Detail = "")

    if ($Condition) {
        $script:passed++
        Write-Host "  PASS $What" -ForegroundColor Green
    }
    else {
        $script:failures.Add($(if ($Detail) { "$What -- $Detail" } else { $What }))
        Write-Host "  FAIL $What" -ForegroundColor Red
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
    }
}

# Make one request with curl and return the status alongside the body.
#
# The status is asked for through -w on its own line because curl has no way to
# report it separately, and PowerShell hands back native stdout as an array of
# lines which makes the last one easy to peel off.
function Invoke-Api {
    param(
        [string] $Method = "GET",
        [string] $Path,
        [string] $Token,
        [object] $Body
    )

    $curl = @("-s", "-X", $Method, "-H", "Accept: application/json", "-w", "`n%{http_code}")

    # A request body is written to a file and sent with --data @file. Passing
    # JSON through PowerShell's argument parser mangles the quoting, and the
    # mangled version still looks plausible in the output.
    $bodyFile = $null
    if ($null -ne $Body) {
        $bodyFile = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($bodyFile, ($Body | ConvertTo-Json -Depth 8 -Compress))
        $curl += @("-H", "Content-Type: application/json", "--data", "@$bodyFile")
    }

    if ($Token) { $curl += @("-H", "${header}: $Token") }

    try {
        $raw = & curl.exe @curl "$BaseUrl$Path" 2>$null
    }
    finally {
        if ($bodyFile) { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
    }

    if ($null -eq $raw) { $raw = @() }
    $lines = @($raw)
    $status = 0
    $text = ""
    if ($lines.Count -ge 1) {
        # A 204 has no body at all, so the only line is the status.
        if ($lines.Count -eq 1) {
            $status = [int]($lines[0] -replace '\D', '')
        }
        else {
            $status = [int]($lines[-1] -replace '\D', '')
            $text = ($lines[0..($lines.Count - 2)] -join "`n")
        }
    }

    return [pscustomobject]@{ Status = $status; Body = $text }
}

# Run a jq filter over a response body. jq is used rather than ConvertFrom-Json
# so that the assertions read the way the same checks would in a shell pipeline,
# and because -e turns a false or null result into a non-zero exit which is a
# convenient way to test for absence.
function Read-Jq {
    param([string] $Json, [string] $Filter)

    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    $value = $Json | jq -r $Filter 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($value -eq "null") { return $null }
    return $value
}

function New-Token {
    param([string] $Name, [string] $ExpiresAt)

    $body = @{ name = $Name }
    if ($ExpiresAt) { $body["expires_at"] = $ExpiresAt }
    $response = Invoke-Api -Method POST -Path "/api/v2/tokens" -Token $credentials.token -Body $body
    return $response
}

# ---------------------------------------------------------------------------

Write-Host "Token lifecycle against $BaseUrl" -ForegroundColor White
Write-Host "authenticating as $($credentials.admin_email) with the bootstrap token"

Write-Section "the bootstrap token"

$me = Invoke-Api -Path "/api/v2/me" -Token $credentials.token
Confirm-That "GET /me with the bootstrap token returns 200" ($me.Status -eq 200) "got $($me.Status): $($me.Body)"

if ($me.Status -ne 200) {
    Write-Host ""
    Write-Host "Cannot continue without a working token." -ForegroundColor Red
    exit 1
}

# KEY_PREFIX is "pst_" and KEY_LENGTH is 32, so a well formed key is 36
# characters. The prefix exists so that a token is recognisable in a log file and
# by a secret scanner, which makes it worth pinning.
Confirm-That "the token has the pst_ prefix" ($credentials.token.StartsWith("pst_"))
Confirm-That "the token is 36 characters (prefix + 32)" ($credentials.token.Length -eq 36) "length $($credentials.token.Length)"

$tokenName = Read-Jq $me.Body '.data.token.name'
Confirm-That "/me reports the token it was authenticated with" ($tokenName -eq "bootstrap") "name '$tokenName'"
Confirm-That "/me reports the same token uuid as the credentials file" ((Read-Jq $me.Body '.data.token.uuid') -eq $credentials.token_uuid)
Confirm-That "the bootstrap token has no expiry" ($null -eq (Read-Jq $me.Body '.data.token.expires_at'))

Write-Section "rejected credentials"

# Four distinct ways to fail authentication. The first two have their own error
# codes because "you sent nothing" and "you sent something wrong" are different
# problems for whoever is debugging the client.
$noHeader = Invoke-Api -Path "/api/v2/me"
Confirm-That "no header at all returns 401" ($noHeader.Status -eq 401) "got $($noHeader.Status)"
Confirm-That "  and says MissingAPIKey" ((Read-Jq $noHeader.Body '.error.code') -eq "MissingAPIKey") (Read-Jq $noHeader.Body '.error.code')

$empty = Invoke-Api -Path "/api/v2/me" -Token ""
Confirm-That "an empty header returns 401 MissingAPIKey" ($empty.Status -eq 401 -and (Read-Jq $empty.Body '.error.code') -eq "MissingAPIKey") "got $($empty.Status) $(Read-Jq $empty.Body '.error.code')"

$nonsense = Invoke-Api -Path "/api/v2/me" -Token "pst_notavalidtokenatallnotvalid1234"
Confirm-That "an unrecognised token returns 401" ($nonsense.Status -eq 401) "got $($nonsense.Status)"
Confirm-That "  and says InvalidAPIKey" ((Read-Jq $nonsense.Body '.error.code') -eq "InvalidAPIKey") (Read-Jq $nonsense.Body '.error.code')

# The legacy API uses X-Server-API-Key and this one deliberately does not, so a
# client which sends the wrong header name must be rejected rather than silently
# treated as unauthenticated in some other way.
$wrongName = & curl.exe -s -o NUL -w "%{http_code}" -H "X-Server-API-Key: $($credentials.token)" "$BaseUrl/api/v2/me"
Confirm-That "the legacy X-Server-API-Key header is not accepted" ($wrongName -eq "401") "got $wrongName"

$bearer = & curl.exe -s -o NUL -w "%{http_code}" -H "Authorization: Bearer $($credentials.token)" "$BaseUrl/api/v2/me"
Confirm-That "an Authorization Bearer header is not accepted" ($bearer -eq "401") "got $bearer"

Write-Section "creating a token"

$before = Invoke-Api -Path "/api/v2/tokens" -Token $credentials.token
Confirm-That "GET /tokens lists the existing tokens" ($before.Status -eq 200) "got $($before.Status)"
$beforeCount = [int](Read-Jq $before.Body '.data | length')

$newName = "$run-created"
$create = New-Token -Name $newName
Confirm-That "POST /tokens returns 201" ($create.Status -eq 201) "got $($create.Status): $($create.Body)"

$newKey = Read-Jq $create.Body '.data.key'
$newUuid = Read-Jq $create.Body '.data.uuid'
if ($newUuid) { $created.Add([pscustomobject]@{ uuid = $newUuid; name = $newName }) }

Confirm-That "the response carries the plain key" ($null -ne $newKey)
Confirm-That "the new key has the pst_ prefix and is 36 characters" ($newKey -and $newKey.StartsWith("pst_") -and $newKey.Length -eq 36) "key '$newKey'"
Confirm-That "the new key is not the bootstrap token" ($newKey -ne $credentials.token)

# key_prefix is the first KEY_PREVIEW_LENGTH (8) characters of the plain key. It
# is what a user reads in the UI to tell two tokens apart without either of them
# being recoverable.
$keyPrefix = Read-Jq $create.Body '.data.key_prefix'
Confirm-That "key_prefix is the first 8 characters of the key" ($keyPrefix -eq $newKey.Substring(0, 8)) "prefix '$keyPrefix'"
Confirm-That "the name was stored" ((Read-Jq $create.Body '.data.name') -eq $newName)
Confirm-That "a new token starts with no expiry" ($null -eq (Read-Jq $create.Body '.data.expires_at'))
Confirm-That "a new token has not been revoked" ($null -eq (Read-Jq $create.Body '.data.revoked_at'))
Confirm-That "a new token has not been used yet" ($null -eq (Read-Jq $create.Body '.data.last_used_at'))

$after = Invoke-Api -Path "/api/v2/tokens" -Token $credentials.token
$afterCount = [int](Read-Jq $after.Body '.data | length')
Confirm-That "the collection grew by one" ($afterCount -eq $beforeCount + 1) "$beforeCount -> $afterCount"

# The plain key is only in the create response. It is never persisted -- only its
# SHA-256 digest is -- so a later read must not be able to produce it. If this
# ever started returning a key it would mean the digest had been replaced with
# something reversible.
$listed = Read-Jq $after.Body ".data[] | select(.uuid == `"$newUuid`") | .key"
Confirm-That "listing the tokens does not expose the plain key" ($null -eq $listed) "got '$listed'"
$listedPrefix = Read-Jq $after.Body ".data[] | select(.uuid == `"$newUuid`") | .key_prefix"
Confirm-That "  but the listing still shows the key prefix" ($listedPrefix -eq $newKey.Substring(0, 8))

# A missing required parameter is a 400 ParameterMissing rather than a 422
# ValidationError. The distinction is deliberate and documented: 422 means the
# request was well formed but the values did not validate, whereas here the
# parameter was never supplied at all, so params.require raises before any model
# is involved. This is the one case where the two are easy to confuse.
$noName = Invoke-Api -Method POST -Path "/api/v2/tokens" -Token $credentials.token -Body @{}
Confirm-That "creating a token without a name returns 400" ($noName.Status -eq 400) "got $($noName.Status): $($noName.Body)"
Confirm-That "  and says ParameterMissing" ((Read-Jq $noName.Body '.error.code') -eq "ParameterMissing") (Read-Jq $noName.Body '.error.code')

Write-Section "using the new token"

$asNew = Invoke-Api -Path "/api/v2/me" -Token $newKey
Confirm-That "the new token authenticates" ($asNew.Status -eq 200) "got $($asNew.Status): $($asNew.Body)"
Confirm-That "/me with it reports its own uuid" ((Read-Jq $asNew.Body '.data.token.uuid') -eq $newUuid)
Confirm-That "/me with it reports its own name" ((Read-Jq $asNew.Body '.data.token.name') -eq $newName)
# Both tokens belong to the same user, so the identity behind them is the same.
# What differs is the token, which is the point of reporting it separately.
Confirm-That "both tokens resolve to the same user" ((Read-Jq $asNew.Body '.data.user.uuid') -eq (Read-Jq $me.Body '.data.user.uuid'))

# UserAPIToken#use writes last_used_at with update_column on every authenticated
# request, so a single use is enough to set it.
$usedList = Invoke-Api -Path "/api/v2/tokens" -Token $credentials.token
$lastUsed = Read-Jq $usedList.Body ".data[] | select(.uuid == `"$newUuid`") | .last_used_at"
Confirm-That "last_used_at was recorded by the request above" ($null -ne $lastUsed) "still null"

Write-Section "expiry"

$future = (Get-Date).ToUniversalTime().AddHours(1).ToString("yyyy-MM-ddTHH:mm:ssZ")
$futureToken = New-Token -Name "$run-future" -ExpiresAt $future
Confirm-That "a token can be created with a future expiry" ($futureToken.Status -eq 201) "got $($futureToken.Status): $($futureToken.Body)"
$futureKey = Read-Jq $futureToken.Body '.data.key'
$futureUuid = Read-Jq $futureToken.Body '.data.uuid'
if ($futureUuid) { $created.Add([pscustomobject]@{ uuid = $futureUuid; name = "$run-future" }) }
Confirm-That "the expiry is echoed back" ($null -ne (Read-Jq $futureToken.Body '.data.expires_at'))
$stillWorks = Invoke-Api -Path "/api/v2/me" -Token $futureKey
Confirm-That "a token which has not expired yet still works" ($stillWorks.Status -eq 200) "got $($stillWorks.Status)"

$badExpiry = New-Token -Name "$run-bad" -ExpiresAt "not a date"
Confirm-That "an unparseable expiry returns 422" ($badExpiry.Status -eq 422) "got $($badExpiry.Status): $($badExpiry.Body)"
Confirm-That "  and explains which field was wrong" ((Read-Jq $badExpiry.Body '.error.details[0]') -match 'Expires at') (Read-Jq $badExpiry.Body '.error.details[0]')

# TokensController parses expires_at and then saves whatever it produced. Nothing
# validates that the moment is in the future, so an already elapsed expiry is
# accepted at creation and the token is simply never usable: the active scope
# filters on expires_at > now. That is worth pinning because it is the kind of
# behaviour a client would otherwise discover in production.
$past = (Get-Date).ToUniversalTime().AddHours(-1).ToString("yyyy-MM-ddTHH:mm:ssZ")
$pastToken = New-Token -Name "$run-past" -ExpiresAt $past
Confirm-That "an expiry in the past is accepted at creation" ($pastToken.Status -eq 201) "got $($pastToken.Status): $($pastToken.Body)"
$pastKey = Read-Jq $pastToken.Body '.data.key'
$pastUuid = Read-Jq $pastToken.Body '.data.uuid'
if ($pastUuid) { $created.Add([pscustomobject]@{ uuid = $pastUuid; name = "$run-past" }) }
$pastUse = Invoke-Api -Path "/api/v2/me" -Token $pastKey
Confirm-That "  but the already expired token cannot be used" ($pastUse.Status -eq 401) "got $($pastUse.Status)"
Confirm-That "  and it is reported as InvalidAPIKey" ((Read-Jq $pastUse.Body '.error.code') -eq "InvalidAPIKey")
$expiredListed = Invoke-Api -Path "/api/v2/tokens" -Token $credentials.token
Confirm-That "an expired token is still listed so it can be cleaned up" ($null -ne (Read-Jq $expiredListed.Body ".data[] | select(.uuid == `"$pastUuid`") | .uuid"))

Write-Section "revocation"

$revoke = Invoke-Api -Method DELETE -Path "/api/v2/tokens/$newUuid" -Token $credentials.token
Confirm-That "DELETE /tokens/:uuid returns 204" ($revoke.Status -eq 204) "got $($revoke.Status): $($revoke.Body)"
$created.Remove(($created | Where-Object uuid -eq $newUuid))

$afterRevoke = Invoke-Api -Path "/api/v2/me" -Token $newKey
Confirm-That "the revoked token no longer authenticates" ($afterRevoke.Status -eq 401) "got $($afterRevoke.Status)"
Confirm-That "  and is reported as InvalidAPIKey" ((Read-Jq $afterRevoke.Body '.error.code') -eq "InvalidAPIKey")

# revoke! sets revoked_at rather than deleting the row, so that a record of the
# token survives for auditing. That is the reason the row is still here.
$revokedList = Invoke-Api -Path "/api/v2/tokens" -Token $credentials.token
$revokedRow = Read-Jq $revokedList.Body ".data[] | select(.uuid == `"$newUuid`") | .revoked_at"
Confirm-That "the revoked token is still listed" ($null -ne (Read-Jq $revokedList.Body ".data[] | select(.uuid == `"$newUuid`") | .uuid"))
Confirm-That "  and now carries revoked_at" ($null -ne $revokedRow) "revoked_at is null"

$twice = Invoke-Api -Method DELETE -Path "/api/v2/tokens/$newUuid" -Token $credentials.token
Confirm-That "revoking twice succeeds rather than erroring" ($twice.Status -eq 204) "got $($twice.Status): $($twice.Body)"

$missing = Invoke-Api -Method DELETE -Path "/api/v2/tokens/00000000-0000-4000-8000-000000000000" -Token $credentials.token
Confirm-That "revoking a token which does not exist returns 404" ($missing.Status -eq 404) "got $($missing.Status): $($missing.Body)"
Confirm-That "  and says NotFound" ((Read-Jq $missing.Body '.error.code') -eq "NotFound")

# Deliberately not tested: revoking the bootstrap token. It would succeed and
# every other script in this directory would stop working, with no way to mint a
# replacement except bootstrap.ps1 -NewToken.

Write-Section "cleanup"

if ($Keep) {
    Write-Host "  -Keep was given, leaving $($created.Count) token(s) active:" -ForegroundColor Yellow
    foreach ($entry in $created) { Write-Host "    $($entry.name) ($($entry.uuid))" }
}
else {
    foreach ($entry in $created) {
        $result = Invoke-Api -Method DELETE -Path "/api/v2/tokens/$($entry.uuid)" -Token $credentials.token
        if ($result.Status -eq 204) {
            Write-Host "  revoked $($entry.name)"
        }
        else {
            Write-Host "  could not revoke $($entry.name): $($result.Status)" -ForegroundColor Yellow
            $script:failures.Add("cleanup: could not revoke $($entry.name)")
        }
    }
    # The bootstrap token must still work, otherwise this script has destroyed the
    # thing every other script depends on.
    $final = Invoke-Api -Path "/api/v2/me" -Token $credentials.token
    Confirm-That "the bootstrap token still works after cleanup" ($final.Status -eq 200) "got $($final.Status)"
}

Write-Host ""
Write-Host "$($script:passed) passed, $($script:failures.Count) failed" -ForegroundColor $(if ($script:failures.Count -eq 0) { "Green" } else { "Red" })
foreach ($failure in $script:failures) { Write-Host "  FAILED: $failure" -ForegroundColor Red }

if ($script:failures.Count -gt 0) { exit 1 }
exit 0
