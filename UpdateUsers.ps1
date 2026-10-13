<#
.SYNOPSIS
  Exports all Anypoint Platform users and their teams to CSV.

.DESCRIPTION
  One CSV row per user with the columns: Name, UserName, Email, Status, Teams.
  Teams lists every team the user belongs to across all business groups,
  separated by semicolons. Works on Windows PowerShell 5.1 and PowerShell 7+.

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
  .\Get-AnypointUsersReport.ps1 -Token $Token -OutputPath .\users_report.csv
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

function Get-AllPages {
    param([string]$Path)
    $all = New-Object System.Collections.Generic.List[object]
    $off = 0
    do {
        $p = Invoke-Anypoint -Path $Path -Query @{ limit = $PageSize; offset = $off } -AllowNotFound
        $items = if ($p -and $p.data) { @($p.data) } else { @() }
        foreach ($x in $items) { $all.Add($x) }
        $off += $items.Count
    } while ($items.Count -gt 0 -and $p.total -and $off -lt $p.total)
    return $all
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

# --- Users ------------------------------------------------------------------
$users = Get-AllPages -Path "/accounts/api/organizations/$OrgId/users"
Write-Host "$($users.Count) users, $($bgNames.Count) business groups" -ForegroundColor Cyan
if ($users.Count -eq 0) { throw 'No users returned.' }

# --- Teams (per business group) ---------------------------------------------
# $teamLookup["<userId or username>"] = list of team names across all business groups
$teamLookup = @{}
$bgIndex = 0
foreach ($bgId in @($bgNames.Keys)) {
    $bgIndex++
    Write-Progress -Activity 'Fetching teams' -Status "$bgIndex of $($bgNames.Count): $($bgNames[$bgId])" -PercentComplete (($bgIndex / $bgNames.Count) * 100)
    try { $teams = Get-AllPages -Path "/accounts/api/organizations/$bgId/teams" }
    catch { Write-Warning "Could not list teams for '$($bgNames[$bgId])': $($_.Exception.Message)"; continue }

    foreach ($t in $teams) {
        $tid   = if ($t.team_id) { $t.team_id } else { $t.id }
        $tname = if ($t.team_name) { $t.team_name } else { $t.name }
        try { $members = Get-AllPages -Path "/accounts/api/organizations/$bgId/teams/$tid/members" }
        catch { Write-Warning "Could not list members of team '$tname' in '$($bgNames[$bgId])'"; continue }
        foreach ($mem in $members) {
            foreach ($k in @($mem.id, $mem.username)) {
                if (-not $k) { continue }
                if (-not $teamLookup.ContainsKey($k)) { $teamLookup[$k] = New-Object System.Collections.Generic.List[string] }
                if (-not $teamLookup[$k].Contains($tname)) { $teamLookup[$k].Add($tname) }
            }
        }
    }
}
Write-Progress -Activity 'Fetching teams' -Completed

# --- Build rows (one per user) ----------------------------------------------
$rows = foreach ($u in $users) {
    $d = $u
    # The user list normally includes names; only look up details if it doesn't.
    if (-not $u.firstName -and -not $u.lastName) {
        try {
            $detail = Invoke-Anypoint -Path "/accounts/api/organizations/$OrgId/users/$($u.id)" -AllowNotFound
            if ($detail) { $d = if ($detail.user) { $detail.user } else { $detail } }
        }
        catch { }
    }

    $teamList = New-Object System.Collections.Generic.List[string]
    foreach ($k in @($u.id, $u.username)) {
        if ($k -and $teamLookup.ContainsKey($k)) { foreach ($tn in $teamLookup[$k]) { $teamList.Add($tn) } }
    }

    $enabled = if ($null -ne $d.enabled) { $d.enabled } else { $u.enabled }
    [pscustomobject][ordered]@{
        Name     = ("$($d.firstName) $($d.lastName)").Trim()
        UserName = if ($d.username) { $d.username } else { $u.username }
        Email    = if ($d.email) { $d.email } else { $u.email }
        Status   = if ($null -eq $enabled) { '' } elseif ($enabled) { 'Active' } else { 'Disabled' }
        Teams    = ($teamList | Sort-Object -Unique) -join '; '
    }
}

$rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "Wrote $(@($rows).Count) rows to $OutputPath" -ForegroundColor Green
