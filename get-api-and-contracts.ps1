<#
.SYNOPSIS
  Lists API Manager APIs and their contracts for a Business Group / environment.
  Read-only: only GET requests are made.
#>

[CmdletBinding()]
param(
    [string]$BaseUrl    = "https://anypoint.mulesoft.com",   # EU: https://eu1.anypoint.mulesoft.com
    [string]$OutputFile = ".\ApiContracts_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

$ErrorActionPreference = 'Stop'

# ---------- Input ----------
$token = (Read-Host "Enter Anypoint bearer token").Trim()
if ($token -like 'Bearer *') { $token = $token.Substring(7) }
$headers = @{ Authorization = "Bearer $token"; Accept = "application/json" }

function Invoke-Anypoint {
    param([string]$Uri)
    try {
        Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        throw "GET $Uri failed (HTTP $status): $($_.Exception.Message)"
    }
}

# ---------- Business Group selection ----------
$me = Invoke-Anypoint "$BaseUrl/accounts/api/me"
$orgs = @()
$orgs += [pscustomobject]@{ Id = $me.user.organization.id; Name = $me.user.organization.name }
foreach ($o in @($me.user.memberOfOrganizations)) {
    if ($o.id -and ($orgs.Id -notcontains $o.id)) { $orgs += [pscustomobject]@{ Id = $o.id; Name = $o.name } }
}
foreach ($o in @($me.user.contributorOfOrganizations)) {
    if ($o.id -and ($orgs.Id -notcontains $o.id)) { $orgs += [pscustomobject]@{ Id = $o.id; Name = $o.name } }
}

Write-Host "`nAvailable Business Groups:" -ForegroundColor Cyan
$orgs | ForEach-Object { Write-Host ("  {0}  ({1})" -f $_.Name, $_.Id) }

$bgInput = (Read-Host "`nBusiness Group (name or ID)").Trim()
$bg = $orgs | Where-Object { $_.Id -eq $bgInput -or $_.Name -eq $bgInput } | Select-Object -First 1
if (-not $bg) { throw "Business Group '$bgInput' not found." }

# ---------- Environment selection ----------
$envs = (Invoke-Anypoint "$BaseUrl/accounts/api/organizations/$($bg.Id)/environments").data
Write-Host "`nEnvironments in '$($bg.Name)':" -ForegroundColor Cyan
$envs | ForEach-Object { Write-Host ("  {0}  ({1})" -f $_.name, $_.id) }

$envInput = (Read-Host "`nEnvironment (name or ID)").Trim()
$envObj = $envs | Where-Object { $_.id -eq $envInput -or $_.name -eq $envInput } | Select-Object -First 1
if (-not $envObj) { throw "Environment '$envInput' not found in '$($bg.Name)'." }

$apiBase = "$BaseUrl/apimanager/api/v1/organizations/$($bg.Id)/environments/$($envObj.id)"

# ---------- Get APIs (paged) ----------
Write-Host "`nRetrieving APIs..." -ForegroundColor Cyan
$apis   = @()
$offset = 0
$limit  = 100
do {
    $page  = Invoke-Anypoint "$apiBase/apis?limit=$limit&offset=$offset"
    $count = 0
    foreach ($asset in @($page.assets)) {
        foreach ($api in @($asset.apis)) {
            $count++
            $apis += [pscustomobject]@{
                ApiId             = $api.id
                AssetId           = $asset.assetId
                ExchangeAssetName = $asset.exchangeAssetName
                AssetVersion      = $api.assetVersion
                ProductVersion    = $api.productVersion
                InstanceLabel     = $api.instanceLabel
                Status            = $api.status
                Technology        = $api.technology
            }
        }
    }
    $offset += $limit
} while ($count -gt 0 -and $offset -lt [int]$page.total)

Write-Host "Found $($apis.Count) API instance(s)."

# ---------- Get contracts per API ----------
$rows = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($api in $apis) {
    $i++
    Write-Progress -Activity "Retrieving contracts" -Status "$i / $($apis.Count): $($api.ExchangeAssetName)" -PercentComplete (($i / [math]::Max($apis.Count,1)) * 100)

    $contracts = @()
    try {
        $resp = Invoke-Anypoint "$apiBase/apis/$($api.ApiId)/contracts"
        if ($resp -is [System.Array])  { $contracts = $resp }
        elseif ($resp.contracts)       { $contracts = @($resp.contracts) }
    } catch {
        Write-Warning "Could not read contracts for API $($api.ApiId): $($_.Exception.Message)"
    }

    $base = [ordered]@{
        BusinessGroup     = $bg.Name
        Environment       = $envObj.name
        ApiId             = $api.ApiId
        ExchangeAssetName = $api.ExchangeAssetName
        AssetId           = $api.AssetId
        AssetVersion      = $api.AssetVersion
        InstanceLabel     = $api.InstanceLabel
        ApiStatus         = $api.Status
    }

    if ($contracts.Count -eq 0) {
        $rows.Add([pscustomobject]($base + [ordered]@{
            ContractId = ''; ApplicationId = ''; ApplicationName = ''
            ContractStatus = ''; RequestedTierId = ''; ApprovedDate = ''
        }))
    } else {
        foreach ($c in $contracts) {
            $rows.Add([pscustomobject]($base + [ordered]@{
                ContractId      = $c.id
                ApplicationId   = $c.applicationId
                ApplicationName = $c.application.name
                ContractStatus  = $c.status
                RequestedTierId = $c.requestedTierId
                ApprovedDate    = $c.approvedDate
            }))
        }
    }
}
Write-Progress -Activity "Retrieving contracts" -Completed

# ---------- Output ----------
$rows | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-Host "`nDone. $($rows.Count) row(s) written to: $((Resolve-Path $OutputFile).Path)" -ForegroundColor Green
