<#
  measure-bulk.ps1 -- BulkActions fleet measurement, rebased onto the single API call.

  The existing harness (measure-ssh.ps1) measures each VM from its OWN control-plane
  timeCreated, which normalizes away the one thing that matters for BulkActions: how the
  fleet fans out from the SINGLE bulk API invocation. This wrapper adds that missing
  left-hand side.

  It takes the launchBulkInstancesOperation id, reads the operation resource's server-
  stamped origin (properties.createdTime = T0), discovers the fleet authoritatively via
  the operation's listVirtualMachines child, and computes the NEW leading anchor:

      Orchestration = VM.timeCreated - T0      (API call -> VM resource created)

  reported as a DISTRIBUTION (p50/p90/p99, min/max, spread) plus a fleet fill curve --
  not a mean -- because at scale the engine trades simultaneity for throughput and the
  tail/straggler, not the average, defines when the fleet is actually usable.

  With -WithGuest it then WRAPS (does not replace) the existing guest collector over the
  same ssh -J jump path, and rebases every boot/init anchor onto T0:

      <anchor>FromT0 = Orchestration + <anchor>     for Boot / Ready / Workload / CIDone

  so you see true API-call -> Ready end-to-end, not the per-VM-origin understatement.

  Telemetry sources (all confirmed against a live 200):
    - T0            : GET launchBulkInstancesOperations/{id} -> properties.createdTime
    - fleet+status  : GET .../launchBulkInstancesOperations/{id}/virtualMachines (id,name,operationStatus)
    - per-VM created: control-plane VM.timeCreated (az vm list)
    - boot/init     : the unchanged guest collector (uptime, cloud-init.log, status.json)

  Usage:
    ./measure-bulk.ps1 -OperationId 17b9b2ad-...-df6d33e6844d
    ./measure-bulk.ps1 -OperationId 17b9b2ad-... -WithGuest -JumpHost <jump-public-ip>

  NOTE: read-only. Uses the regional ARM endpoint (https://<region>.management.azure.com)
  with an explicit --resource token, exactly like provision-bulk.ps1.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $OperationId,
  [string] $ResourceGroup = 'rg-test',
  [string] $Region        = 'uksouth',
  [switch] $WithGuest,
  [string] $JumpHost,
  [string] $User          = 'azureuser',
  [string] $IdentityFile,
  [int]    $CollectRetries   = 3,
  [int]    $CollectRetryDelay = 20
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2026-02-01-preview'
$armHost    = "https://$Region.management.azure.com"
$armRes     = "https://management.azure.com/"

if ($WithGuest -and -not $JumpHost) { throw "-WithGuest requires -JumpHost <jump-public-ip>." }

# --- helpers ----------------------------------------------------------------
function To-Epoch([string]$s) { return [double]([datetimeoffset]$s).ToUnixTimeMilliseconds() / 1000.0 }

function Pctile($arr, [double]$p) {
  $s = @($arr | Where-Object { $_ -ne $null } | Sort-Object)
  $n = $s.Count
  if ($n -eq 0) { return $null }
  if ($n -eq 1) { return [math]::Round([double]$s[0], 1) }
  $rank = [math]::Ceiling($p / 100.0 * $n)
  if ($rank -lt 1) { $rank = 1 } elseif ($rank -gt $n) { $rank = $n }
  return [math]::Round([double]$s[$rank - 1], 1)
}

function Stat-Row([string]$name, $arr) {
  $s = @($arr | Where-Object { $_ -ne $null })
  if (-not $s.Count) {
    return [pscustomobject]@{ Anchor = $name; p50 = '-'; p90 = '-'; p99 = '-'; min = '-'; max = '-'; spread = '-'; n = 0 }
  }
  $min = [math]::Round(($s | Measure-Object -Minimum).Minimum, 1)
  $max = [math]::Round(($s | Measure-Object -Maximum).Maximum, 1)
  [pscustomobject]@{
    Anchor = $name
    p50    = (Pctile $s 50); p90 = (Pctile $s 90); p99 = (Pctile $s 99)
    min    = $min; max = $max; spread = [math]::Round($max - $min, 1); n = $s.Count
  }
}

function Show-FillCurve($deltas) {
  $s = @($deltas | Where-Object { $_ -ne $null } | Sort-Object)
  $n = $s.Count
  if (-not $n) { Write-Host "  (no data)"; return }
  $max = [double]$s[-1]
  if ($max -le 0) { $max = 1 }
  $buckets = 12
  $width = $max / $buckets
  for ($b = 1; $b -le $buckets; $b++) {
    $edge = $width * $b
    $cum  = @($s | Where-Object { $_ -le $edge }).Count
    $bar  = '#' * [int][math]::Round(($cum / $n) * 30)
    Write-Host ("  +{0,6:n1}s  {1,-30} {2}/{3}" -f $edge, $bar, $cum, $n)
  }
}

# --- 1) operation resource -> T0 -------------------------------------------
$subId = az account show --query id -o tsv
if (-not $subId) { throw "Not logged in -- run 'az login'." }

$opUri = "$armHost/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.ComputeBulkActions/locations/$Region/launchBulkInstancesOperations/${OperationId}?api-version=$apiVersion"
$op = az rest --method get --uri $opUri --resource $armRes -o json | ConvertFrom-Json
if (-not $op.properties.createdTime) { throw "Operation $OperationId has no createdTime (not found, or wrong rg/region)." }

$t0      = To-Epoch $op.properties.createdTime
$capacity = $op.properties.capacity
$provState = $op.properties.provisioningState

# --- 2) authoritative fleet + status ---------------------------------------
$vmUri = "$armHost/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.ComputeBulkActions/locations/$Region/launchBulkInstancesOperations/${OperationId}/virtualMachines?api-version=$apiVersion"
$fleet = (az rest --method get --uri $vmUri --resource $armRes -o json | ConvertFrom-Json).value
$byStatus = $fleet | Group-Object operationStatus | ForEach-Object { "$($_.Name)=$($_.Count)" }
$succeeded = @($fleet | Where-Object { $_.operationStatus -eq 'Succeeded' })

# --- 3) control-plane timeCreated (+ ip/power for guest) -------------------
# Orchestration only needs timeCreated, which is on the base VM resource -- so we
# do NOT pass -d here. The -d (show-details) flag resolves every VM's NIC, and a
# single dangling NIC (e.g. left by a prior failed op) makes the whole call error
# out and drop all rows. Network details are fetched separately only for -WithGuest.
$cp = az vm list -g $ResourceGroup `
        --query "[].{name:name, created:timeCreated}" -o json |
      ConvertFrom-Json
$cpByName = @{}
foreach ($v in $cp) { $cpByName[$v.name] = $v }

if ($WithGuest) {
  # ip/power require instance/network details; tolerate per-VM failures.
  $cpDetail = az vm list -g $ResourceGroup -d `
                --query "[].{name:name, ip:privateIps, power:powerState}" -o json 2>$null |
              ConvertFrom-Json
  foreach ($v in @($cpDetail)) {
    if ($cpByName.ContainsKey($v.name)) {
      $cpByName[$v.name] | Add-Member -NotePropertyName ip    -NotePropertyValue $v.ip    -Force
      $cpByName[$v.name] | Add-Member -NotePropertyName power -NotePropertyValue $v.power -Force
    }
  }
}

# --- 4) orchestration deltas -----------------------------------------------
$rows = @()
foreach ($f in ($fleet | Sort-Object name)) {
  $v = $cpByName[$f.name]
  $orch = $null
  if ($v -and $v.created) { $orch = [math]::Round((To-Epoch $v.created) - $t0, 1) }
  $rows += [pscustomobject]@{
    VM            = ($f.name -replace [regex]::Escape("$OperationId"), '#')  # -> #_0, #_1, ...
    Status        = $f.operationStatus
    Orchestration = $orch
  }
}

Write-Host "Bulk operation : $OperationId"
Write-Host "T0 (createdTime): $($op.properties.createdTime)"
Write-Host ("Requested {0} | delivered {1} | provisioningState {2} | status [{3}]" -f `
  $capacity, $succeeded.Count, $provState, ($byStatus -join ' '))

Write-Host "`n=== ORCHESTRATION: API call -> VM created (seconds from T0) ===" -ForegroundColor Green
$rows | Format-Table -AutoSize
Write-Host "Distribution:" -ForegroundColor Cyan
@(Stat-Row 'Orchestration' $rows.Orchestration) | Format-Table -AutoSize
Write-Host "Fleet fill curve (cumulative VMs created since T0):" -ForegroundColor Cyan
Show-FillCurve $rows.Orchestration

if (-not $WithGuest) {
  Write-Host "`n(boot/init not collected; add -WithGuest -JumpHost <ip> for rebased end-to-end.)"
  return
}

# --- 5) guest collector (identical to measure-ssh.ps1) ---------------------
$collect = @'
created="$1"
command -v cloud-init >/dev/null 2>&1 && cloud-init status --wait >/dev/null 2>&1
py=$(command -v python3 || command -v python || echo /usr/libexec/platform-python)
"$py" - "$created" <<'PY'
import json, sys, datetime, subprocess, time
created = float(sys.argv[1])
def delta(t): return None if t is None else round(t - created, 1)
def boot():
    up = float(open("/proc/uptime").read().split()[0])
    return time.time() - up
def report_ready():
    ts = None
    try:
        data = subprocess.check_output(["sudo", "-n", "cat", "/var/log/cloud-init.log"]).decode(errors="ignore")
        for line in data.splitlines():
            lo = line.lower()
            if "report" in lo and "ready" in lo:
                try:
                    ts = datetime.datetime.strptime(line[:19], "%Y-%m-%d %H:%M:%S").timestamp()
                except Exception:
                    pass
    except Exception:
        pass
    return ts
def cloud_init_done():
    try:
        f = json.load(open("/var/lib/cloud/data/status.json"))["v1"]["modules-final"]["finished"]
    except Exception:
        return None
    if f is None:
        return None
    return f if f > 1e9 else boot() + f
def workload():
    try:
        return float(open("/var/lib/customdata-start.stamp").read())
    except Exception:
        return None
print(json.dumps({
    "PreBoot":  delta(boot()),
    "Ready":    delta(report_ready()),
    "Workload": delta(workload()),
    "CIDone":   delta(cloud_init_done()),
}))
PY
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($collect -replace "`r`n", "`n")))

$kh = Join-Path $env:TEMP 'measure_bulk_known_hosts'
$sshBase = @(
  '-J', "$User@$JumpHost",
  '-o', 'StrictHostKeyChecking=no',
  '-o', "UserKnownHostsFile=$kh",
  '-o', 'BatchMode=yes',
  '-o', 'ConnectTimeout=15'
)
if ($IdentityFile) { $sshBase += @('-i', $IdentityFile) }

$e2e = @()
foreach ($f in ($succeeded | Sort-Object name)) {
  $v = $cpByName[$f.name]
  $idx = ($f.name -replace [regex]::Escape("$OperationId"), '#')
  Write-Host "`n--- $idx ---"
  if (-not $v) { Write-Host "  skip: no control-plane record" -ForegroundColor Yellow; continue }
  if ($v.power -and $v.power -notmatch 'running') { Write-Host "  skip: $($v.power)" -ForegroundColor Yellow; continue }
  $ip = ($v.ip -split ',')[0].Trim()
  if (-not $ip) { Write-Host "  skip: no private IP" -ForegroundColor Yellow; continue }

  $cEpoch = (To-Epoch $v.created)
  $orch   = [math]::Round($cEpoch - $t0, 1)
  $sshArgs = $sshBase + @("$User@$ip", "echo $b64 | base64 -d | bash -s -- $cEpoch")
  # ssh writes a harmless "Permanently added ... to known hosts" line to stderr; under
  # $ErrorActionPreference='Stop' that native stderr write is promoted to a terminating
  # NativeCommandError (PS 5.1 quirk), so relax the preference and MERGE stderr into the
  # capture (2>&1) instead of discarding it, so real failures are visible below.
  # Slow-booting VMs can time out the proxied hop ("banner exchange" / port 65535) on the
  # first try, so retry the collect with backoff before giving up.
  $line = $null; $exit = $null; $out = @()
  for ($attempt = 1; $attempt -le $CollectRetries; $attempt++) {
    $raw = & {
      $ErrorActionPreference = 'Continue'
      & ssh @sshArgs 2>&1
    }
    $exit = $LASTEXITCODE
    # normalize: ErrorRecords (stderr) -> their string text; keep stdout strings as-is.
    $out = @($raw | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ }
      })
    $line = $out | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1
    if ($exit -eq 0 -and $line) { break }
    if ($attempt -lt $CollectRetries) {
      Write-Host "  collect attempt $attempt/$CollectRetries failed (ssh exit $exit); retrying in ${CollectRetryDelay}s ..." -ForegroundColor DarkYellow
      Start-Sleep -Seconds $CollectRetryDelay
    }
  }
  if ($exit -ne 0 -or -not $line) {
    Write-Host "  ssh/collect failed after $CollectRetries attempts (ssh exit $exit) -- raw output:" -ForegroundColor Yellow
    if ($out.Count) { $out | ForEach-Object { Write-Host "    | $_" -ForegroundColor DarkGray } }
    else { Write-Host "    | <no output at all>" -ForegroundColor DarkGray }
    continue
  }
  $r = $line | ConvertFrom-Json

  $add = { param($a) if ($null -eq $a) { $null } else { [math]::Round($orch + $a, 1) } }
  $row = [pscustomobject]@{
    VM       = $idx
    Orch     = $orch
    BootT0   = (& $add $r.PreBoot)
    ReadyT0  = (& $add $r.Ready)
    WorkT0   = (& $add $r.Workload)
    CIDoneT0 = (& $add $r.CIDone)
  }
  $e2e += $row
  Write-Host ("  Orch={0}s  Boot={1}s  Ready={2}s  Workload={3}s  CIDone={4}s  (all from T0)" -f `
    $row.Orch, $row.BootT0, $row.ReadyT0, $row.WorkT0, $row.CIDoneT0)
}

if ($e2e.Count) {
  Write-Host "`n=== END-TO-END, rebased onto T0 (seconds from the bulk API call) ===" -ForegroundColor Green
  $e2e | Format-Table -AutoSize
  Write-Host "Distribution (from T0):" -ForegroundColor Cyan
  @(
    Stat-Row 'Orchestration' $e2e.Orch
    Stat-Row 'Boot'          $e2e.BootT0
    Stat-Row 'Ready'         $e2e.ReadyT0
    Stat-Row 'Workload'      $e2e.WorkT0
    Stat-Row 'CIDone'        $e2e.CIDoneT0
  ) | Format-Table -AutoSize
}
