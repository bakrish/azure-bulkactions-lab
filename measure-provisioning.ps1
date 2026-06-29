<#
  measure-provisioning.ps1 -- provisioning-agnostic readiness measurement.

  Measures, for one or more EXISTING VMs, the immutable guest-side milestones and
  subtracts the control-plane create time. Works regardless of HOW the VM was
  provisioned (az vm create, bulk actions, ARM/Bicep, portal, ...), because every
  signal is read from the guest after the fact -- none of it depends on the
  mutable instanceView ProvisioningState stamp or the (delayed) Activity Log.

  Anchors collected per VM:
    Created        timeCreated (control plane, immutable)
    Boot           uptime -s
    ReportReady    cloud-init.log "ready to Azure fabric"  == fabric "Provisioning succeeded"
    CustomData     /var/lib/customdata-start.stamp         (needs customdata-stamp.sh supplied)
    CloudInitDone  status.json -> v1.modules-final.finished

  Reported deltas (seconds from Created):
    PreBoot   = Boot          - Created   (allocation + firmware + kernel)
    Ready     = ReportReady   - Created   <-- headline E2E (fabric provisioned)
    Workload  = CustomData    - Created   (time until user-data can run)
    CIDone    = CloudInitDone - Created   (cloud-init fully complete)

  Note: guest-recorded epochs use the guest clock; Created uses Azure's. NTP keeps
  these within ~1s, which is acceptable here. ReportReady wording is Azure-datasource
  /cloud-init-version specific; the CustomData stamp is the portable cross-distro anchor.

  Usage:
    ./measure-provisioning.ps1 -ResourceGroup rg-rhel810-spotv2
    ./measure-provisioning.ps1 -ResourceGroup my-rg -Name vm1,vm2
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]   $ResourceGroup,
  [string[]] $Name
)

# Guest-side collector: waits for cloud-init, then Python prints ONE JSON line of
# deltas (seconds from Created; the $created epoch is prepended per VM below).
# Missing signals come back as null, so mixed distro/agent fleets still tabulate.
$collect = @'
command -v cloud-init >/dev/null 2>&1 && cloud-init status --wait >/dev/null 2>&1
# cloud-init itself is a Python app, so any cloud-init image has Python. Resolve
# whichever name exists (covers RHEL 8 platform-python and python/python3 symlinks).
py=$(command -v python3 || command -v python || echo /usr/libexec/platform-python)
"$py" - "$created" <<'PY'
import json, sys, datetime, subprocess
created = float(sys.argv[1])
def delta(t): return None if t is None else round(t - created, 1)

def boot():
    s = subprocess.check_output(["uptime", "-s"]).decode().strip()
    return datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S").timestamp()

def report_ready():           # fabric "Provisioning succeeded"
    # The image retains build-time cloud-init entries, so take the LAST match
    # (this boot appends to the end), not the first.
    ts = None
    try:
        for line in open("/var/log/cloud-init.log"):
            lo = line.lower()
            if "report" in lo and "ready" in lo:
                try:
                    ts = datetime.datetime.strptime(line[:19], "%Y-%m-%d %H:%M:%S").timestamp()
                except Exception:
                    pass
    except Exception:
        pass
    return ts

def cloud_init_done():        # status.json v1.modules-final.finished
    try:
        return json.load(open("/var/lib/cloud/data/status.json"))["v1"]["modules-final"]["finished"]
    except Exception:
        return None

def workload():               # customdata-stamp.sh wrote this
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

if (-not $Name -or $Name.Count -eq 0) {
  $Name = az vm list -g $ResourceGroup --query "[].name" -o tsv
}

function Median($arr) {
  $s = @($arr | Where-Object { $_ -ne $null } | Sort-Object); $n = $s.Count
  if ($n -eq 0) { return $null }
  if ($n % 2) { return $s[[int][math]::Floor($n / 2)] }
  return [math]::Round(($s[$n / 2 - 1] + $s[$n / 2]) / 2, 1)
}

# Stage collector body once; the per-VM Created epoch is prepended as a shell var.
$tmp = (New-TemporaryFile).FullName

$rows = @()
foreach ($vm in $Name) {
  Write-Host "`n--- $vm ---"
  $created = az vm show -g $ResourceGroup -n $vm --query timeCreated -o tsv
  if (-not $created) { Write-Host "  skip: no timeCreated (VM not found?)" -ForegroundColor Yellow; continue }
  $cEpoch = ([datetimeoffset]$created).ToUnixTimeMilliseconds() / 1000.0

  Set-Content -Path $tmp -Value "#!/bin/bash`ncreated=$cEpoch`n$collect" -Encoding ASCII
  $msg = az vm run-command invoke -g $ResourceGroup -n $vm --command-id RunShellScript `
           --scripts "@$tmp" --query "value[0].message" -o tsv
  if ($LASTEXITCODE -ne 0 -or -not $msg) {
    Write-Host "  run-command failed (VM stopped/deallocated?)" -ForegroundColor Yellow; continue
  }

  # The guest prints one JSON line -- grab it and convert. No regex.
  $line = $msg.Split("`n") | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1
  if (-not $line) { Write-Host "  no JSON from guest (python3 missing?)" -ForegroundColor Yellow; continue }
  $r = $line | ConvertFrom-Json

  $row = [pscustomobject]@{
    VM = $vm; PreBoot = $r.PreBoot; Ready = $r.Ready; Workload = $r.Workload; CIDone = $r.CIDone
  }
  $rows += $row
  Write-Host ("  PreBoot={0}s  Ready={1}s  Workload={2}s  CIDone={3}s" -f `
    $row.PreBoot, $row.Ready, $row.Workload, $row.CIDone)
}

Remove-Item $tmp -ErrorAction SilentlyContinue

if ($rows.Count) {
  Write-Host "`n=== MEDIANS (n=$($rows.Count)) ==="
  Write-Host ("PreBoot={0}s  Ready={1}s  Workload={2}s  CIDone={3}s" -f `
    (Median $rows.PreBoot), (Median $rows.Ready), (Median $rows.Workload), (Median $rows.CIDone))
  $rows | Format-Table -AutoSize
}
