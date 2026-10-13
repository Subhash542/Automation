<#
.SYNOPSIS
  Exports all Anypoint Platform users and their business group memberships to CSV.

.DESCRIPTION
  One CSV row per user per business group, including roles where the role
  endpoint is available. Works on Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER ClientId / ClientSecret
  Connected app credentials (client credentials grant). Defaults to the
  ANYPOINT_CLIENT_ID / ANYPOINT_CLIENT_SECRET environment variables.

.PARAMETER Token
  Existing bearer token (alternative to ClientId/ClientSecret).
  Defaults to ANYPOINT_TOKEN.

.PARAMETER BaseUrl
  Control plane URL. EU: https://eu1.anypoint.mulesoft.com

.PARAMETER OrgId
  Root org ID. Defaults to the org tied to the token.

.EXAMPLE
  $env:ANYPOINT_CLIENT_ID = '...'; $env:ANYPOINT_CLIENT_SECRET = '...'
  .\Get-AnypointUsersReport.ps1 -OutputPath .\users_report.csv
#>
[CmdletBinding()]
param(
    [string]$ClientId     = $env:ANYPOINT_CLIENT_ID,
    [string]$ClientSecret = $env:ANYPOINT_CLIENT_SECRET,
    [string]$Token        = $env:ANYPOINT_TOKEN,
    [string]$BaseUrl      = $(if ($env:ANYPOINT_BASE_URL) { $env:ANYPOINT_BASE_URL } else { 'https://anypoint.mulesoft.com' }),
    [string]$OrgId        = $env:ANYPOINT_ORG_ID,
    [string]$OutputPath   = '.\anypoint_users_report.csv',
    [int]$PageSize        = 200
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$BaseUrl = $BaseUrl.TrimEnd('/')

# Role endpoints differ between setups. The script tries these in order and
# uses the first one that returns data. Adjust if yours differs (see the
# Access Management API reference in Anypoint Exchange).
$RolePaths = @(
    '/accounts/api/organizations/{org}/users/{user}/rolegroups',
    '/accounts/api/organizations/{org}/users/{user}/roles',
    '/accounts/api/users/{user}/roles'
)

function Invoke-Anypoint {
    param(
        [string]$Path,
        [hashtable]$Query,
        [switch]$AllowNotFound
    )
    $uri = "$BaseUrl$Path"
    if ($Query) {
        $qs = ($Query.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&'
        $uri = "${uri}?$qs"
    }
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Get
        }
        catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 404 -and $AllowNotFound) { return $null }
            if ($status -in 429, 500, 502, 503, 504 -and $attempt -lt 3) {
                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
                continue
            }
            throw
        }
    }
}

function Get-BusinessGroupMap {
    param($Node, [hashtable]$Map, [string]$ParentPath = '')
    $full = if ($ParentPath) { "$ParentPath/$($Node.name)" } else { $Node.name }
    $Map[$Node.id] = $full
    foreach ($child in @($Node.subOrganizations)) {
        if ($child) { Get-BusinessGroupMap -Node $child -Map $Map -ParentPath $full }
    }
}

# --- Authenticate -----------------------------------------------------------
if (-not $Token) {
    if (-not ($ClientId -and $ClientSecret)) {
        throw 'Provide -Token, or -ClientId and -ClientSecret (or the matching ANYPOINT_* environment variables).'
    }
    $body = @{ client_id = $ClientId; client_secret = $ClientSecret; grant_type = 'client_credentials' } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri "$BaseUrl/accounts/api/v2/oauth2/token" -Method Post `
        -ContentType 'application/json' -Body $body
    $Token = $resp.access_token
}
$script:Headers = @{ Authorization = "Bearer $Token" }

# --- Org + business groups --------------------------------------------------
if (-not $OrgId) {
    $OrgId = (Invoke-Anypoint -Path '/accounts/api/me').user.organization.id
}
$bgNames = @{}
Get-BusinessGroupMap -Node (Invoke-Anypoint -Path "/accounts/api/organizations/$OrgId/hierarchy") -Map $bgNames

# --- List all users (paginated) ---------------------------------------------
$users = New-Object System.Collections.Generic.List[object]
$offset = 0
do {
    $page = Invoke-Anypoint -Path "/accounts/api/organizations/$OrgId/users" `
        -Query @{ limit = $PageSize; offset = $offset }
    $data = @($page.data)
    foreach ($u in $data) { $users.Add($u) }
    $offset += $data.Count
} while ($data.Count -gt 0 -and $offset -lt $page.total)

Write-Host "$($users.Count) users, $($bgNames.Count) business groups" -ForegroundColor Cyan
if ($users.Count -eq 0) { throw 'No users returned.' }

# --- Detect a working role endpoint -----------------------------------------
$rolePath = $null
foreach ($p in $RolePaths) {
    try {
        $probe = Invoke-Anypoint -Path ($p -replace '\{org\}', $OrgId -replace '\{user\}', $users[0].id) -AllowNotFound
        if ($null -ne $probe) { $rolePath = $p; break }
    }
    catch { continue }
}
if (-not $rolePath) {
    Write-Warning "No role endpoint worked; the 'Roles' column will be empty. Check `$RolePaths and the token's scopes."
}

# --- Build rows -------------------------------------------------------------
$rows = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($u in $users) {
    $i++
    Write-Progress -Activity 'Fetching user details' -Status "$i of $($users.Count)" -PercentComplete (($i / $users.Count) * 100)

    $detail = Invoke-Anypoint -Path "/accounts/api/users/$($u.id)"
    $d = if ($detail.user) { $detail.user } else { $detail }

    $memberships = @($d.memberOfOrganizations)
    if ($memberships.Count -eq 0 -and $d.organization) { $memberships = @($d.organization) }
    if ($memberships.Count -eq 0) { $memberships = @([pscustomobject]@{ id = $OrgId; name = $bgNames[$OrgId] }) }

    $rolesByOrg = @{}
    if ($rolePath) {
        try {
            $raw = Invoke-Anypoint -Path ($rolePath -replace '\{org\}', $OrgId -replace '\{user\}', $u.id) -AllowNotFound
        }
        catch { $raw = $null }
        $items = if ($raw -and $raw.data) { @($raw.data) } elseif ($raw -is [array]) { $raw } else { @() }
        foreach ($item in $items) {
            $oid = @($item.org_id, $item.organizationId, $OrgId | Where-Object { $_ })[0]
            $rname = @($item.name, $item.role_name, $item.roleName | Where-Object { $_ })[0]
            if (-not $rolesByOrg.ContainsKey($oid)) { $rolesByOrg[$oid] = New-Object System.Collections.Generic.List[string] }
            if ($rname) { $rolesByOrg[$oid].Add($rname) }
        }
    }

    foreach ($m in $memberships) {
        $bgName = if ($bgNames.ContainsKey($m.id)) { $bgNames[$m.id] } else { $m.name }
        $roles = if ($rolesByOrg.ContainsKey($m.id)) { ($rolesByOrg[$m.id] | Sort-Object -Unique) -join '; ' } else { '' }
        $rows.Add([pscustomobject][ordered]@{
            Username        = if ($d.username) { $d.username } else { $u.username }
            Email           = if ($d.email) { $d.email } else { $u.email }
            FirstName       = $d.firstName
            LastName        = $d.lastName
            Enabled         = if ($null -ne $d.enabled) { $d.enabled } else { $u.enabled }
            LastLogin       = $d.lastLogin
            BusinessGroupId = $m.id
            BusinessGroup   = $bgName
            Roles           = $roles
        })
    }
}
Write-Progress -Activity 'Fetching user details' -Completed

$rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "Wrote $($rows.Count) rows to $OutputPath" -ForegroundColor Green
