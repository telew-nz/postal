#Requires -Version 7

<#
.SYNOPSIS
    Walks every operation in the deployed OpenAPI document with curl and checks
    that each one answers with a documented status and a JSON envelope.

.DESCRIPTION
    This script is driven by the specification the server is actually serving at
    /api/v2/spec rather than by a list of requests written into the script. That
    is the point: when an operation is added to doc/api/openapi.yaml it appears
    here on the next run with no edit, and the coverage report at the end names
    any operation which was not reached.

    It is not a substitute for script/smoke/run.rb, which asserts the *content*
    of every response and runs in CI against a throwaway stack. This one answers
    a different question: does the artifact which was actually deployed answer
    every documented operation, over real HTTP from outside the container, with a
    real token, in the shape its own document promises?

    To give the member operations something to address, the sweep first creates a
    sandbox organization and server through the API and populates them with one
    of each kind of resource. Everything it creates is inside that sandbox, and
    the sandbox is deleted at the end. The bootstrap organization, server and
    message are only ever read from -- with one deliberate exception, noted where
    the message operations are set up.

    Requests are made with curl.exe and the specification is parsed with jq.exe.

.PARAMETER ReadOnly
    Only exercise the operations which cannot change anything, and report the
    rest as skipped. Use this against an installation whose data matters.

.PARAMETER Keep
    Leave the sandbox organization in place afterwards so it can be inspected.

.PARAMETER BaseUrl
    Overrides the base URL from the credentials file.

.EXAMPLE
    ./script/production/api-sweep.ps1

.EXAMPLE
    ./script/production/api-sweep.ps1 -ReadOnly
#>
[CmdletBinding()]
param(
    [string] $BaseUrl,
    [switch] $ReadOnly,
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

$header = "X-Postal-API-Key"
$token = $credentials.token

# The suffix which makes everything this run creates distinct. The process id
# alone is not enough for two reasons: a shell which is reused between runs has
# the same one, and deleting an organization is a soft delete, so the row stays
# and its permalink -- which Organization validates as globally unique -- stays
# taken. A second run which reused the name would therefore be refused with
# "Short name has already been taken" rather than replacing the first.
# Only [a-z0-9-] is allowed in a permalink, which hex satisfies.
$run = "$PID-$([Guid]::NewGuid().ToString('n').Substring(0, 8))"

# Operations which are deliberately not swept, by operationId, with the reason.
# The sandbox organization and server are removed by the teardown at the end
# rather than during the sweep, because deleting them part way through would turn
# every later request into a 404 and prove nothing.
$deferred = @{
    deleteOrganization = "run by the teardown"
    deleteServer       = "run by the teardown"
}

# Values which can be substituted into a path parameter, keyed by the family the
# parameter belongs to and then by the parameter name. A family is the literal
# path segment which precedes the parameter, so `routes` in
# .../servers/{server_permalink}/routes/{uuid}.
$families = @{}
# organization_permalink and server_permalink appear in almost every path and
# almost always mean the sandbox, so they resolve from here unless something more
# specific overrides them.
$globals = @{}

# Values aimed at a particular path rather than at a family, as a list of
# @{ Match = <substring of the path template>; Values = @{ param = value } }.
# These take precedence over both of the tables above.
#
# They exist because two groups of operations cannot be exercised against the
# sandbox at all -- the API has no way to create what they address:
#
#   * a message arrives over SMTP, so a server created through the API has none,
#     and there is no operation which inserts one;
#   * an IP pool rule must reference a pool belonging to its own organization
#     ("IP pool must belong to the organization"), and ip_pools is index-only,
#     so an organization created through the API owns no pools.
#
# Both groups are therefore aimed at the bootstrap organization and server, which
# have a message and a pool. A family cannot express this: the family of
# {organization_permalink} is `organizations` and of {server_permalink} is
# `servers`, both of which are shared with every other path in the API.
$pathValues = @()

$script:passed = 0
$script:failures = [System.Collections.Generic.List[string]]::new()
$results = [System.Collections.Generic.List[object]]::new()

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

# Make one request with curl and return the status, the body and the content
# type. The status comes back on its own line through -w because curl cannot
# report it separately, and PowerShell hands back native stdout as an array of
# lines which makes the last one easy to peel off.
function Invoke-Api {
    param(
        [string] $Method = "GET",
        [string] $Path,
        [object] $Body,
        [string] $AuthToken = $token
    )

    $curl = @("-s", "-X", $Method, "-H", "Accept: application/json",
              "-H", "${header}: $AuthToken", "-w", "`n%{http_code}|%{content_type}")

    # A request body goes through a file rather than the argument list, because
    # PowerShell's quoting of JSON for a native command is unreliable and a
    # mangled body still looks plausible in the output.
    $bodyFile = $null
    if ($null -ne $Body) {
        $bodyFile = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($bodyFile, ($Body | ConvertTo-Json -Depth 8 -Compress))
        $curl += @("-H", "Content-Type: application/json", "--data", "@$bodyFile")
    }

    try {
        $raw = & curl.exe @curl "$BaseUrl$Path" 2>$null
    }
    finally {
        if ($bodyFile) { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
    }

    $lines = @($raw)
    $status = 0
    $text = ""
    $contentType = ""
    if ($lines.Count -ge 1) {
        $tail = [string]$lines[-1]
        if ($tail -match '^(\d+)\|(.*)$') {
            $status = [int]$Matches[1]
            $contentType = $Matches[2]
            if ($lines.Count -gt 1) { $text = ($lines[0..($lines.Count - 2)] -join "`n") }
        }
        else {
            # No trailing marker, which means curl itself failed.
            $text = ($lines -join "`n")
        }
    }

    return [pscustomobject]@{ Status = $status; Body = $text; ContentType = $contentType }
}

function Read-Jq {
    param([string] $Json, [string] $Filter)

    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    $value = $Json | jq -r $Filter 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($value -eq "null") { return $null }
    return $value
}

# True when the response carries a JSON document rather than raw message or
# attachment content. Only the former has an envelope to check.
function Test-Json {
    param([string] $ContentType)

    return ($ContentType -match 'application/json')
}

# ---------------------------------------------------------------------------
# The specification
# ---------------------------------------------------------------------------

Write-Host "API sweep against $BaseUrl" -ForegroundColor White

Write-Section "reading the deployed specification"

$specFile = [IO.Path]::GetTempFileName()
try {
    $specResponse = Invoke-Api -Path "/api/v2/spec" -AuthToken ""
    if ($specResponse.Status -ne 200) {
        Write-Host "GET /api/v2/spec returned $($specResponse.Status)." -ForegroundColor Red
        exit 1
    }
    [IO.File]::WriteAllText($specFile, $specResponse.Body)

    # The filter lives in a file because passing this much jq through PowerShell's
    # argument handling would need every double quote escaped twice.
    $filterFile = [IO.Path]::GetTempFileName()
    $filter = @'
[ .paths | to_entries[] | .key as $p | .value | to_entries[]
  | select(.key | test("^(get|post|put|patch|delete)$"))
  | { path: $p,
      method: (.key | ascii_upcase),
      operationId: (.value.operationId // "unnamed"),
      statuses: [ (.value.responses // {}) | keys[] | select(test("^[0-9]+$")) | tonumber ],
      contentTypes: [ (.value.responses // {}) | to_entries[] | select(.key | test("^2"))
                      | (.value.content // {}) | keys[] ],
      params: [ (.value.parameters // [])[] | select(.in == "path") | .name ] } ]
'@
    [IO.File]::WriteAllText($filterFile, $filter)

    $operations = (jq -c -f $filterFile $specFile | ConvertFrom-Json)
    Remove-Item $filterFile -ErrorAction SilentlyContinue

    Write-Host "  $($operations.Count) documented operations"
    $byMethod = $operations | Group-Object method | Sort-Object Name
    foreach ($group in $byMethod) { Write-Host "    $($group.Name): $($group.Count)" }
}
finally {
    Remove-Item $specFile -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# The sandbox
# ---------------------------------------------------------------------------

$sandboxOrg = "sweep-$run"
$sandboxServer = $null

function New-Sandbox {
    Write-Section "creating a sandbox"

    $org = Invoke-Api -Method POST -Path "/api/v2/organizations" `
        -Body @{ name = "Sweep Sandbox"; permalink = $script:sandboxOrg; time_zone = "UTC" }
    if ($org.Status -ne 201) {
        Write-Host "Could not create the sandbox organization: $($org.Status) $($org.Body)" -ForegroundColor Red
        exit 1
    }
    $script:globals["organization_permalink"] = (Read-Jq $org.Body '.data.permalink')
    Write-Host "  organization $($script:globals['organization_permalink'])"

    # A server gets its own message database, which is a separate MySQL schema
    # created at this point. It is also what makes the server-scoped operations
    # addressable at all.
    $server = Invoke-Api -Method POST -Path "/api/v2/organizations/$($script:globals['organization_permalink'])/servers" `
        -Body @{ name = "Sandbox Server"; mode = "Live" }
    if ($server.Status -ne 201) {
        Write-Host "Could not create the sandbox server: $($server.Status) $($server.Body)" -ForegroundColor Red
        exit 1
    }
    $script:sandboxServer = (Read-Jq $server.Body '.data.permalink')
    $script:globals["server_permalink"] = $script:sandboxServer
    Write-Host "  server $script:sandboxServer"
}

# Create one of each resource so that the member operations have something real
# to address. The bodies are the minimal set which passes model validation; they
# are not guesses, they are the same values script/smoke/run.rb uses.
function Seed-Sandbox {
    Write-Section "seeding the sandbox"

    $org = $globals["organization_permalink"]
    $server = $globals["server_permalink"]
    $orgBase = "/api/v2/organizations/$org"
    $serverBase = "$orgBase/servers/$server"

    # Routes and track domains both identify their parent domain by its integer
    # id rather than by uuid, which is why DomainSerializer exposes the id at all.
    $domain = Invoke-Api -Method POST -Path "$orgBase/domains" -Body @{ name = "sweep-$run.example.com" }
    $domainUuid = Read-Jq $domain.Body '.data.uuid'
    $domainId = Read-Jq $domain.Body '.data.id'
    if ($domainUuid) { $families["domains"] = @{ domain_uuid = $domainUuid } }
    Write-Host "  domains            $($domain.Status) uuid=$domainUuid id=$domainId"

    # A second domain, attached to the server rather than to the organization.
    # DomainsController picks its scope on the presence of server_permalink, so
    # the five operations nested under a server can only ever see a domain
    # created this way -- the organization-scoped one above is invisible to
    # them, and without this they all answer 404.
    $serverDomain = Invoke-Api -Method POST -Path "$serverBase/domains" -Body @{ name = "sweep-srv-$run.example.com" }
    $script:serverDomainUuid = Read-Jq $serverDomain.Body '.data.uuid'
    Write-Host "  domains (server)   $($serverDomain.Status) uuid=$script:serverDomainUuid"

    # A rule has to reference a pool belonging to the organization it is
    # created in, and ip_pools is index-only, so neither can be created inside
    # the sandbox. Both are created in the bootstrap organization instead and
    # removed again by the DELETE pass. One is organization-scoped and one
    # server-scoped because the API exposes both and each will only return a
    # rule whose owner matches.
    $poolId = $credentials.ip_pool_id
    if ($poolId) {
        $orgRule = Invoke-Api -Method POST -Path "/api/v2/organizations/$($credentials.organization_permalink)/ip_pool_rules" `
            -Body @{ from_text = "sweep-org-$run@example.com"; ip_pool_id = $poolId }
        $script:orgRuleUuid = Read-Jq $orgRule.Body '.data.uuid'
        Write-Host "  ip_pool_rules      $($orgRule.Status) uuid=$script:orgRuleUuid"

        $serverRule = Invoke-Api -Method POST -Path "/api/v2/organizations/$($credentials.organization_permalink)/servers/$($credentials.server_permalink)/ip_pool_rules" `
            -Body @{ from_text = "sweep-server-$run@example.com"; ip_pool_id = $poolId }
        $script:serverRuleUuid = Read-Jq $serverRule.Body '.data.uuid'
        Write-Host "  ip_pool_rules      $($serverRule.Status) uuid=$script:serverRuleUuid (server scoped)"
    }
    else {
        Write-Host "  ip_pool_rules      skipped, no ip_pool_id in the credentials file" -ForegroundColor Yellow
    }

    $http = Invoke-Api -Method POST -Path "$serverBase/http_endpoints" `
        -Body @{ name = "Sweep HTTP"; url = "https://example.com/hook"; encoding = "BodyAsJSON"; format = "RawMessage" }
    $httpUuid = Read-Jq $http.Body '.data.uuid'
    if ($httpUuid) { $families["http_endpoints"] = @{ uuid = $httpUuid } }
    Write-Host "  http_endpoints     $($http.Status) uuid=$httpUuid"

    $smtp = Invoke-Api -Method POST -Path "$serverBase/smtp_endpoints" `
        -Body @{ name = "Sweep SMTP"; hostname = "smtp.example.com"; port = 2525; ssl_mode = "STARTTLS" }
    $smtpUuid = Read-Jq $smtp.Body '.data.uuid'
    if ($smtpUuid) { $families["smtp_endpoints"] = @{ uuid = $smtpUuid } }
    Write-Host "  smtp_endpoints     $($smtp.Status) uuid=$smtpUuid"

    $address = Invoke-Api -Method POST -Path "$serverBase/address_endpoints" `
        -Body @{ address = "sweep-$run@example.com" }
    $addressUuid = Read-Jq $address.Body '.data.uuid'
    if ($addressUuid) { $families["address_endpoints"] = @{ uuid = $addressUuid } }
    Write-Host "  address_endpoints  $($address.Status) uuid=$addressUuid"

    $credential = Invoke-Api -Method POST -Path "$serverBase/credentials" `
        -Body @{ type = "SMTP"; name = "sweep-$run"; key = "sweep-password" }
    $credentialUuid = Read-Jq $credential.Body '.data.uuid'
    if ($credentialUuid) { $families["credentials"] = @{ uuid = $credentialUuid } }
    Write-Host "  credentials        $($credential.Status) uuid=$credentialUuid"

    $endpoint = if ($httpUuid) { "HTTPEndpoint#$httpUuid" } else { "Accept" }
    $route = Invoke-Api -Method POST -Path "$serverBase/routes" `
        -Body @{ name = "sweep-$run"; domain_id = $domainId; spam_mode = "Mark"; _endpoint = $endpoint }
    $routeUuid = Read-Jq $route.Body '.data.uuid'
    if ($routeUuid) { $families["routes"] = @{ uuid = $routeUuid } }
    Write-Host "  routes             $($route.Status) uuid=$routeUuid"

    $track = Invoke-Api -Method POST -Path "$serverBase/track_domains" `
        -Body @{ name = "track"; domain_id = $domainId; track_clicks = $true }
    $trackUuid = Read-Jq $track.Body '.data.uuid'
    if ($trackUuid) { $families["track_domains"] = @{ uuid = $trackUuid } }
    Write-Host "  track_domains      $($track.Status) uuid=$trackUuid"

    $suppression = Invoke-Api -Method POST -Path "$serverBase/messages/suppressions" `
        -Body @{ type = "recipient"; address = "sweep-bounce-$run@example.com" }
    if ($suppression.Status -eq 201) {
        $families["suppressions"] = @{
            suppression_type    = "recipient"
            suppression_address = "sweep-bounce-$run@example.com"
        }
    }
    Write-Host "  suppressions       $($suppression.Status)"

    # The sweep creates its own token rather than using the bootstrap one, so
    # that revoking it at the end cannot lock the harness out.
    $newToken = Invoke-Api -Method POST -Path "/api/v2/tokens" -Body @{ name = "sweep-$run" }
    $newTokenUuid = Read-Jq $newToken.Body '.data.uuid'
    if ($newTokenUuid) { $families["tokens"] = @{ id = $newTokenUuid } }
    Write-Host "  tokens             $($newToken.Status) uuid=$newTokenUuid"
}

# Aim the operations which cannot be exercised against the sandbox at the
# bootstrap dataset instead. This runs after the seeding because two of the
# entries carry the uuid of a rule which the seeding has just created.
#
# Entries are matched as substrings of the path template and every match is
# applied in order, so a later, longer match refines an earlier, shorter one.
function Set-PathOverrides {
    $bootstrapOrg = $credentials.organization_permalink
    $bootstrapServer = $credentials.server_permalink

    # /messages/{id} is a prefix of every message member operation -- deliveries,
    # activity, plain, html, headers, attachments, attachment, download, retry,
    # cancel_hold, remove_from_queue -- and matches none of the collection
    # endpoints, which work against the sandbox exactly as they are.
    if ($credentials.message_id) {
        $script:pathValues += @{
            Match  = "/messages/{id}"
            Values = @{ organization_permalink = $bootstrapOrg; server_permalink = $bootstrapServer; id = $credentials.message_id }
        }
        Write-Host "  messages           using the bootstrap message $($credentials.message_id)"
    }

    $script:pathValues += @{
        Match  = "/ip_pool_rules"
        Values = @{ organization_permalink = $bootstrapOrg; server_permalink = $bootstrapServer }
    }

    # The server-scoped domain operations. The match is a prefix of the member
    # path and therefore also covers dns_records, verify, check and the delete.
    if ($script:serverDomainUuid) {
        $script:pathValues += @{
            Match  = "/servers/{server_permalink}/domains/{domain_uuid}"
            Values = @{ domain_uuid = $script:serverDomainUuid }
        }
    }
    if ($script:orgRuleUuid) {
        $script:pathValues += @{
            Match  = "/organizations/{organization_permalink}/ip_pool_rules/{uuid}"
            Values = @{ uuid = $script:orgRuleUuid }
        }
    }
    if ($script:serverRuleUuid) {
        $script:pathValues += @{
            Match  = "/servers/{server_permalink}/ip_pool_rules/{uuid}"
            Values = @{ uuid = $script:serverRuleUuid }
        }
    }
}

# ---------------------------------------------------------------------------
# Resolution and execution
# ---------------------------------------------------------------------------

# Work out which family a path parameter belongs to. The rule is the nearest
# preceding literal segment, which holds for every path in this API: {uuid} in
# .../routes/{uuid} belongs to routes, {domain_uuid} in .../domains/{domain_uuid}
# belongs to domains, and both parameters of
# .../suppressions/{suppression_type}/{suppression_address} belong to
# suppressions because a parameter is never itself a family.
function Get-Family {
    param([string[]] $Segments, [int] $Index)

    for ($j = $Index - 1; $j -ge 0; $j--) {
        if ($Segments[$j] -notmatch '^\{') { return $Segments[$j] }
    }
    return $null
}

# Substitute a value for every path parameter in an operation. Named for what it
# does rather than `Resolve-Path`, which is a PowerShell built-in and would be
# shadowed for the rest of the script -- including the Set-Location at the top,
# which runs before this definition and would silently pick a different one.
function Resolve-OperationPath {
    param($Operation)

    # The template and the result are kept apart. Get-Family has to read the
    # template, because a parameter is identified by the literal segment before
    # it and once that segment has been replaced by a value the next parameter's
    # family can no longer be found. That is not hypothetical:
    # .../suppressions/{suppression_type}/{suppression_address} has two adjacent
    # parameters, and resolving the first in place made the second look as if it
    # belonged to a family named after the first one's value.
    $template = $Operation.path -split '/'
    $segments = $template.Clone()
    $unresolved = @()

    # The most specific override which matches this path, if any.
    $override = $null
    foreach ($entry in $pathValues) {
        if ($Operation.path.Contains($entry.Match)) {
            if ($null -eq $override) { $override = @{} }
            foreach ($key in $entry.Values.Keys) { $override[$key] = $entry.Values[$key] }
        }
    }

    for ($i = 0; $i -lt $segments.Count; $i++) {
        if ($template[$i] -notmatch '^\{(.+)\}$') { continue }
        $name = $Matches[1]

        $family = Get-Family -Segments $template -Index $i
        $value = $null
        if ($override -and $override.Contains($name)) {
            $value = $override[$name]
        }
        elseif ($family -and $families[$family] -and $families[$family].Contains($name)) {
            $value = $families[$family][$name]
        }
        elseif ($globals.Contains($name)) {
            $value = $globals[$name]
        }

        if ($null -eq $value) {
            $unresolved += $name
            # A syntactically plausible value rather than an empty segment,
            # so that the request reaches the controller and is answered with
            # the documented 404 instead of failing to route at all.
            $value = if ($name -eq 'id') { '999999999' } else { 'does-not-exist' }
        }
        $segments[$i] = $value
    }

    return [pscustomobject]@{ Path = ($segments -join '/'); Unresolved = $unresolved }
}

# Check one response against what the document declares for the operation which
# produced it. Two things are verified and nothing more: that the status is one
# the document lists, and that a JSON response carries the envelope every
# operation in this API shares.
function Test-Response {
    param($Operation, $Resolved, $Response)

    $label = "$($Operation.method) $($Operation.path)"
    $documented = @($Operation.statuses)

    if ($Response.Status -eq 0) {
        $results.Add([pscustomobject]@{ Operation = $Operation; Status = 0; Outcome = "fail"; Note = "curl could not complete the request" })
        Confirm-That $label $false "the request did not complete"
        return
    }

    $problems = @()

    if ($documented.Count -gt 0 -and $documented -notcontains $Response.Status) {
        $problems += "status $($Response.Status) is not one of the documented [$($documented -join ', ')]"
    }

    if ($Response.Status -eq 204 -or $Response.Status -eq 205) {
        # render_no_content is `head :no_content`, which sends neither a body nor
        # a Content-Type. Absence of both is what the status means, so there is
        # no envelope to check here -- only that nothing was sent.
        if ($Response.Body) { $problems += "a $($Response.Status) carried a body" }
        if ($Response.ContentType) { $problems += "a $($Response.Status) carried a content type" }
    }
    elseif ($Operation.path -eq '/api/v2/spec') {
        # The one operation which answers with something other than an envelope:
        # it serves the OpenAPI document itself, which is what is being checked.
        $isSpec = Read-Jq $Response.Body 'if type == "object" and has("openapi") and has("paths") then "ok" else "bad" end'
        if ($isSpec -ne "ok") { $problems += "the response is not an OpenAPI document" }
    }
    elseif (Test-Json $Response.ContentType) {
        $shape = Read-Jq $Response.Body 'if type == "object" and (has("data") or has("error")) then "ok" else "bad" end'
        if ($shape -ne "ok") {
            $problems += "the JSON body has neither a data nor an error member"
        }
    }
    elseif ($Response.Status -lt 400) {
        # A body which is not JSON is only acceptable where the document says it
        # can happen. Two operations serve raw content rather than an envelope:
        # the attachment download declares */* and the message download declares
        # text/plain. Reading that from the specification instead of keeping a
        # list of paths here is the point of driving the sweep from the document
        # -- if a third raw endpoint is added, this accepts it unedited.
        $declaresRaw = @($Operation.contentTypes | Where-Object { $_ -notmatch 'application/json' }).Count -gt 0
        if (-not $declaresRaw) {
            $problems += "returned '$($Response.ContentType)' which is not JSON, and the document declares no non-JSON response for it"
        }
    }

    $note = if ($Resolved.Unresolved.Count -gt 0) { "unresolved: $($Resolved.Unresolved -join ', ')" } else { "" }
    $outcome = if ($problems.Count -eq 0) { "pass" } else { "fail" }
    $results.Add([pscustomobject]@{ Operation = $Operation; Status = $Response.Status; Outcome = $outcome; Note = $note })
    Confirm-That "$label -> $($Response.Status)" ($problems.Count -eq 0) ($problems -join '; ')
}

# A request body for the operations which need one. Sending an empty object to a
# create is enough to prove that it is routed, authenticated and validating: the
# answer has to be one of the documented error statuses rather than a 500 or an
# HTML page. The seeded resources are what make the successful paths reachable.
function Get-Body {
    param($Operation)

    switch ($Operation.method) {
        "GET" { return $null }
        "DELETE" { return $null }
        default { return @{} }
    }
}

function Invoke-Sweep {
    param([string[]] $Methods, [string] $Title)

    Write-Section $Title

    $selected = @($operations | Where-Object { $Methods -contains $_.method })

    if ($Methods -contains "DELETE") {
        # Deletions run deepest path first. A route and a track domain both hold
        # the id of the domain they were created against and go with it when it
        # is deleted, so in document order -- which puts the organization's
        # domains before the server's routes -- both member deletes arrive after
        # their subject has gone and are answered with a 404 that proves
        # nothing. Ordering by depth puts dependents first without the sweep
        # having to know which resources depend on which.
        $selected = @($selected | Sort-Object { ($_.path -split '/').Count } -Descending)
    }
    foreach ($operation in $selected) {
        if ($deferred.ContainsKey($operation.operationId)) { continue }

        $resolved = Resolve-OperationPath -Operation $operation
        $response = Invoke-Api -Method $operation.method -Path $resolved.Path -Body (Get-Body -Operation $operation)
        Test-Response -Operation $operation -Resolved $resolved -Response $response
    }
}

function Remove-Sandbox {
    Write-Section "teardown"

    $org = $globals["organization_permalink"]
    $server = $globals["server_permalink"]

    if ($Keep) {
        Write-Host "  -Keep was given, leaving the sandbox organization '$org' in place" -ForegroundColor Yellow
        return
    }

    # Both of these are documented operations, so the teardown doubles as the
    # last two requests of the sweep. The server goes first: an organization
    # cannot be deleted while a server still belongs to it.
    #
    # Both are guarded against accidental deletion the same way the web UI is,
    # by requiring the name to be echoed back in confirm_text. Without it the
    # request is refused with a 422 -- which is a documented status, so a
    # teardown which forgets it still reports a pass while leaving the sandbox
    # behind. The bodies below are the reason this function exists.
    $deleteServer = $operations | Where-Object operationId -eq 'deleteServer' | Select-Object -First 1
    if ($deleteServer) {
        $resolved = Resolve-OperationPath -Operation $deleteServer
        $response = Invoke-Api -Method DELETE -Path $resolved.Path -Body @{ confirm_text = "Sandbox Server" }
        Test-Response -Operation $deleteServer -Resolved $resolved -Response $response
    }

    $deleteOrg = $operations | Where-Object operationId -eq 'deleteOrganization' | Select-Object -First 1
    if ($deleteOrg) {
        $resolved = Resolve-OperationPath -Operation $deleteOrg
        $response = Invoke-Api -Method DELETE -Path $resolved.Path -Body @{ confirm_text = "Sweep Sandbox" }
        Test-Response -Operation $deleteOrg -Resolved $resolved -Response $response
    }

    # The token the sweep created is revoked rather than left active, because a
    # working credential which nothing references is exactly the kind of thing
    # which should not survive a test run.
    if ($families["tokens"]) {
        $revoke = Invoke-Api -Method DELETE -Path "/api/v2/tokens/$($families['tokens']['id'])"
        Write-Host "  revoked the sweep token ($($revoke.Status))"
    }
}

# ---------------------------------------------------------------------------

if ($ReadOnly) {
    Write-Host "read-only: the sandbox is not created and mutating operations are skipped" -ForegroundColor Yellow
    $globals["organization_permalink"] = $credentials.organization_permalink
    $globals["server_permalink"] = $credentials.server_permalink
    # Nothing was seeded, so the message operations still need pointing at the
    # bootstrap message and the pool rules at rules which do not exist. Both
    # resolve to a documented 404, which is the best a read-only run can do.
    Set-PathOverrides
}
else {
    New-Sandbox
    Seed-Sandbox
    Set-PathOverrides
}

# The passes are ordered by method rather than run in document order. GETs go
# first so that they see the resources the seeding created; DELETEs go last so
# that they do not remove something a later request still needs.
Invoke-Sweep -Methods @("GET") -Title "sweep: reads"
if (-not $ReadOnly) {
    Invoke-Sweep -Methods @("POST", "PATCH", "PUT") -Title "sweep: writes"
    Invoke-Sweep -Methods @("DELETE") -Title "sweep: deletes"
    Remove-Sandbox
}

# ---------------------------------------------------------------------------

Write-Section "coverage"

$exercised = @($results | ForEach-Object { $_.Operation.operationId } | Sort-Object -Unique)
$skipped = @($operations | Where-Object { $exercised -notcontains $_.operationId })

Write-Host "  $($exercised.Count) of $($operations.Count) documented operations exercised"
if ($skipped.Count -gt 0) {
    Write-Host ""
    Write-Host "  not exercised:" -ForegroundColor Yellow
    foreach ($operation in $skipped) {
        $reason = if ($ReadOnly -and $operation.method -ne "GET") { "mutating, skipped by -ReadOnly" }
        elseif ($deferred.ContainsKey($operation.operationId)) { $deferred[$operation.operationId] }
        else { "no request was made" }
        Write-Host "    $($operation.method) $($operation.path) -- $reason"
    }
}

$unresolved = @($results | Where-Object { $_.Note })
if ($unresolved.Count -gt 0) {
    Write-Host ""
    Write-Host "  requests whose path parameters could not be resolved:" -ForegroundColor Yellow
    foreach ($entry in $unresolved) {
        Write-Host "    $($entry.Operation.method) $($entry.Operation.path) -- $($entry.Note)"
    }
}

# A 404 is a documented status for almost every member operation, so one which
# only ever produced a 404 has proved that it routes and authenticates but not
# that it does anything. Those are counted out loud rather than folded into the
# coverage figure, because "102 of 102 exercised" reads as a much stronger claim
# than it is if a third of them were answered from a record-not-found path.
$notFoundOnly = @($results | Where-Object { $_.Status -eq 404 })
if ($notFoundOnly.Count -gt 0) {
    Write-Host ""
    Write-Host "  answered 404, so only routing and authentication were proved:" -ForegroundColor Yellow
    foreach ($entry in $notFoundOnly) {
        Write-Host "    $($entry.Operation.method) $($entry.Operation.path)"
    }
}

Write-Host ""
Write-Host "$($script:passed) passed, $($script:failures.Count) failed" -ForegroundColor $(if ($script:failures.Count -eq 0) { "Green" } else { "Red" })
foreach ($failure in $script:failures) { Write-Host "  FAILED: $failure" -ForegroundColor Red }

if ($script:failures.Count -gt 0) { exit 1 }
exit 0
