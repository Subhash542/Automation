<#
.SYNOPSIS
  Copies Anypoint MQ destinations (queues, exchanges, bindings) between
  Business Groups / environments, region for region.
  Lists everything first, then copies all at once or one by one.

.EXAMPLE
  .\Copy-AnypointMQ.ps1 -DryRun
  .\Copy-AnypointMQ.ps1
#>
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$Base = "https://anypoint.mulesoft.com"

# Token prompt is visible
$Token   = (Read-Host "Anypoint token").Trim()
$Headers = @{ Authorization = "Bearer $Token" }

function Invoke-Api {
    param([string]$Method, [string]$Path, $Body = $null)
    $params = @{ Method = $Method; Uri = "$Base$Path"; Headers = $Headers }
    if ($null -ne $Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = "application/json"
    }
    Invoke-RestMethod @params
}

function Select-Item {
    param([string]$Label, [array]$Items, [string]$Prop = "name")
    Write-Host "`n$Label" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $Items[$i].$Prop)
    }
    while ($true) {
        $sel = Read-Host "Select number"
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $Items.Count) {
            return $Items[[int]$sel - 1]
        }
    }
}

function Get-MqPath {
    param($Org, $Env, $Region)
    "/mq/admin/api/v1/organizations/$Org/environments/$Env/regions/$Region"
}

function Copy-Queue {
    param($Item)
    $detail = Invoke-Api GET "$($Item.Src)/destinations/queues/$($Item.Id)"
    $body = @{}
    foreach ($k in "defaultTtl", "defaultLockTtl", "encrypted", "fifo", "deadLetterQueueId", "maxDeliveries") {
        if ($null -ne $detail.$k) { $body[$k] = $detail.$k }
    }
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would create queue '$($Item.Id)' with: $($body | ConvertTo-Json -Compress)"
    } else {
        Invoke-Api PUT "$($Item.Tgt)/destinations/queues/$($Item.Id)" $body | Out-Null
        Write-Host "OK    queue '$($Item.Id)' [$($Item.Region)]" -ForegroundColor Green
    }
}

function Copy-Exchange {
    param($Item)
    $id     = $Item.Id
    $detail = Invoke-Api GET "$($Item.Src)/destinations/exchanges/$id"
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would create exchange '$id'"
    } else {
        Invoke-Api PUT "$($Item.Tgt)/destinations/exchanges/$id" @{ encrypted = [bool]$detail.encrypted } | Out-Null
        Write-Host "OK    exchange '$id' [$($Item.Region)]" -ForegroundColor Green
    }
    # Verify this bindings path against the MQ Admin API docs
    $bindings = @(Invoke-Api GET "$($Item.Src)/destinations/exchanges/$id/bindings")
    foreach ($b in $bindings) {
        $qid  = if ($b.queueId) { $b.queueId } else { $b.destinationId }
        $rule = if ($b.rule) { $b.rule } else { @{} }
        if ($DryRun) {
            Write-Host "[DRY-RUN]   Would bind exchange '$id' -> queue '$qid'"
        } else {
            Invoke-Api PUT "$($Item.Tgt)/destinations/exchanges/$id/bindings/$qid" @{ rule = $rule } | Out-Null
            Write-Host "OK      binding '$id' -> '$qid'" -ForegroundColor Green
        }
    }
}

if ($DryRun) { Write-Host "`n*** DRY-RUN MODE: no changes will be made ***" -ForegroundColor Yellow }

# --- Business groups and environments ---
$acct = Invoke-Api GET "/accounts/api/profile"
$orgs = @($acct.user.memberOfOrganizations)

$srcOrg = Select-Item "Source Business Group" $orgs
$tgtOrg = Select-Item "Target Business Group" $orgs
$srcEnv = Select-Item "Source environment" @((Invoke-Api GET "/accounts/api/organizations/$($srcOrg.id)/environments").data)
$tgtEnv = Select-Item "Target environment" @((Invoke-Api GET "/accounts/api/organizations/$($tgtOrg.id)/environments").data)

# --- Regions: same as source ---
$srcRegions   = @(Invoke-Api GET "/mq/admin/api/v1/organizations/$($srcOrg.id)/environments/$($srcEnv.id)/regions")
$tgtRegions   = @(Invoke-Api GET "/mq/admin/api/v1/organizations/$($tgtOrg.id)/environments/$($tgtEnv.id)/regions")
$tgtRegionIds = @($tgtRegions | ForEach-Object { $_.regionId })

Write-Host "`nSource: $($srcOrg.name) / $($srcEnv.name)"
Write-Host "Target: $($tgtOrg.name) / $($tgtEnv.name)"

# --- Build the plan ---
$plan = New-Object System.Collections.Generic.List[object]

foreach ($r in $srcRegions) {
    $region = $r.regionId
    if ($tgtRegionIds -notcontains $region) {
        Write-Host "Region $region is not available in the target environment. Skipping." -ForegroundColor Yellow
        continue
    }
    $src = Get-MqPath $srcOrg.id $srcEnv.id $region
    $tgt = Get-MqPath $tgtOrg.id $tgtEnv.id $region

    $srcDests = @(Invoke-Api GET "$src/destinations")
    $tgtIds   = @(Invoke-Api GET "$tgt/destinations") | ForEach-Object { $_.destinationId }

    $queues    = @($srcDests | Where-Object { $_.type -eq "queue" })
    $exchanges = @($srcDests | Where-Object { $_.type -eq "exchange" })

    # Dead-letter queues first so references resolve
    $dlqIds = @($queues | Where-Object { $_.deadLetterQueueId } | ForEach-Object { $_.deadLetterQueueId })
    $queues = @($queues | Sort-Object { if ($dlqIds -contains $_.destinationId) { 0 } else { 1 } })

    foreach ($d in @($queues) + @($exchanges)) {
        $plan.Add([pscustomobject]@{
            Region = $region
            Type   = $d.type
            Id     = $d.destinationId
            Exists = ($tgtIds -contains $d.destinationId)
            Status = if ($tgtIds -contains $d.destinationId) { "Exists in target - will skip" } else { "New - will copy" }
            Src    = $src
            Tgt    = $tgt
        })
    }
}

if ($plan.Count -eq 0) { Write-Host "No destinations found in source." ; exit }

# --- Show the plan ---
Write-Host "`nDestinations found in source:" -ForegroundColor Cyan
$plan | Format-Table -AutoSize @{ N = "#"; E = { $plan.IndexOf($_) + 1 } }, Region, Type, Id, Status

$toCopy = @($plan | Where-Object { -not $_.Exists })
Write-Host ("To copy: {0}   Already in target (skipped): {1}" -f $toCopy.Count, ($plan.Count - $toCopy.Count))
if ($toCopy.Count -eq 0) { Write-Host "Nothing to copy."; exit }

# --- Choose how to run ---
Write-Host "`nHow do you want to proceed?"
Write-Host "  A = copy all listed 'New' destinations"
Write-Host "  O = one by one (confirm each)"
Write-Host "  Q = quit"
do { $mode = (Read-Host "Choice (A/O/Q)").Trim().ToUpper() } while ($mode -notin "A", "O", "Q")
if ($mode -eq "Q") { Write-Host "Cancelled."; exit }

$summary  = @{ Created = 0; Skipped = $plan.Count - $toCopy.Count; Declined = 0; Failed = 0 }
$copyRest = ($mode -eq "A")

foreach ($item in $toCopy) {
    if (-not $copyRest) {
        Write-Host ""
        $ans = ""
        do {
            $ans = (Read-Host "Copy $($item.Type) '$($item.Id)' [$($item.Region)]?  (Y)es / (N)o / (A)ll remaining / (Q)uit").Trim().ToUpper()
        } while ($ans -notin "Y", "N", "A", "Q")

        if ($ans -eq "Q") { Write-Host "Stopped by user."; break }
        if ($ans -eq "N") { $summary.Declined++; Write-Host "SKIP  $($item.Type) '$($item.Id)' (declined)" -ForegroundColor Yellow; continue }
        if ($ans -eq "A") { $copyRest = $true }
    }

    try {
        if ($item.Type -eq "queue") { Copy-Queue $item } else { Copy-Exchange $item }
        $summary.Created++
    } catch {
        Write-Host "FAIL  $($item.Type) '$($item.Id)': $($_.Exception.Message)" -ForegroundColor Red
        $summary.Failed++
    }
}

Write-Host ("`nDone. Created: {0}  Already existed: {1}  Declined: {2}  Failed: {3}" -f $summary.Created, $summary.Skipped, $summary.Declined, $summary.Failed)
if ($DryRun) { Write-Host "This was a dry run. Re-run without -DryRun to apply." -ForegroundColor Yellow }
