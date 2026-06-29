<#
  measure-ssh.ps1 -- fleet readiness measurement over SSH (ProxyJump).

  Same anchors/output as measure-provisioning.ps1, but instead of the slow,
  serial run-command control-plane round trip, it SSHes straight into each VM's
  PRIVATE IP through a jump host (ssh -J). The VMs were created with
  --generate-ssh-keys, so your LOCAL ~/.ssh/id_rsa authenticates BOTH hops --
  nothing needs copying onto the jump host.

  Topology:
    your workstation --ssh -J--> jumpHost(public IP, SAME vnet, ANY rg) --> spotVM(private IP)

  Per VM it runs the identical Python collector and prints one JSON line of deltas
  (seconds from the control-plane timeCreated):
    PreBoot  = boot          - Created
    Ready    = reportReady   - Created   (fabric "Provisioning succeeded")
    Workload = customdata     - Created   (needs customdata-stamp.sh)
    CIDone   = modules-final  - Created

  Prereqs:
    - A jump VM in the SAME vnet (e.g. vnet-rhel/sub-rhel) with a public IP and
      NSG inbound 22 from your IP. It may live in a different resource group, e.g.:
        az group create -n rg-jump -l uksouth
        $subnetId = az network vnet subnet show -g rg-rhel810-spotv3 `
            --vnet-name vnet-rhel -n sub-rhel --query id -o tsv
        az vm create -g rg-jump -n jump --image Ubuntu2204 `
            --subnet $subnetId --generate-ssh-keys --public-ip-sku Standard
    - OpenSSH client on PATH (ssh.exe).

  Usage:
    ./measure-ssh.ps1 -ResourceGroup rg-rhel810-spotv3 -JumpHost <jump-public-ip>
    ./measure-ssh.ps1 -ResourceGroup rg-rhel810-spotv3 -JumpHost jump.example.com -User azureuser

  NOTE: create the jump VM with the SAME admin user as the fleet so one -User
  covers both hops, e.g. az vm create ... --admin-username azureuser.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $JumpHost,
  [string] $User = 'azureuser',                # admin user for BOTH hops (jump + fleet)
  [string] $IdentityFile
)

# Identical guest collector; reads Created as $1 (passed via `bash -s -- <epoch>`).
$collect = @'
created="$1"
command -v cloud-init >/dev/null 2>&1 && cloud-init status --wait >/dev/null 2>&1
py=$(command -v python3 || command -v python || echo /usr/libexec/platform-python)
"$py" - "$created" <<'PY'
import json, sys, datetime, subprocess, time
created = float(sys.argv[1])
def delta(t): return None if t is None else round(t - created, 1)

def boot():
    # Sub-second boot epoch (now - uptime). `uptime -s` floors to the whole
    # second, which skews the AZL3 boot-relative CIDone reconstruction.
    up = float(open("/proc/uptime").read().split()[0])
    return time.time() - up

def report_ready():           # fabric "Provisioning succeeded"; last match = this boot
    ts = None
    try:
        # cloud-init.log is root-only (0640); over SSH we are the admin user, so
        # read it via passwordless sudo (Azure Linux images grant NOPASSWD).
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

def cloud_init_done():        # status.json v1.modules-final.finished
    # Newer cloud-init (e.g. Azure Linux 3) records stage times as seconds since
    # boot, not an absolute epoch; reconstruct absolute time from boot when so.
    try:
        f = json.load(open("/var/lib/cloud/data/status.json"))["v1"]["modules-final"]["finished"]
    except Exception:
        return None
    if f is None:
        return None
    return f if f > 1e9 else boot() + f

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
# bash needs LF, not CRLF. We base64 the (LF) script and pass it as a single
# remote-command token decoded by `base64 -d` -- piping via stdin would let
# PowerShell re-inject CRLF at the native-command boundary and break bash.
$body = $collect -replace "`r`n", "`n"
$b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))

function Median($arr) {
  $s = @($arr | Where-Object { $_ -ne $null } | Sort-Object); $n = $s.Count
  if ($n -eq 0) { return $null }
  if ($n % 2) { return $s[[int][math]::Floor($n / 2)] }
  return [math]::Round(($s[$n / 2 - 1] + $s[$n / 2]) / 2, 1)
}

# Throwaway known_hosts so parallel/non-interactive SSH never prompts.
$kh = Join-Path $env:TEMP 'measure_known_hosts'
$sshBase = @(
  '-J', "$User@$JumpHost",
  '-o', 'StrictHostKeyChecking=no',
  '-o', "UserKnownHostsFile=$kh",
  '-o', 'BatchMode=yes',
  '-o', 'ConnectTimeout=15'
)
if ($IdentityFile) { $sshBase += @('-i', $IdentityFile) }

# Enumerate the fleet: name, private IP, create time, power state -- one call.
$vms = az vm list -g $ResourceGroup -d `
         --query "[].{name:name, ip:privateIps, created:timeCreated, power:powerState}" -o json |
       ConvertFrom-Json

$rows = @()
foreach ($v in $vms) {
  Write-Host "`n--- $($v.name) ---"
  if ($v.power -and $v.power -notmatch 'running') {
    Write-Host "  skip: $($v.power) (not running)" -ForegroundColor Yellow; continue
  }
  $ip = ($v.ip -split ',')[0].Trim()
  if (-not $ip) { Write-Host "  skip: no private IP" -ForegroundColor Yellow; continue }
  $cEpoch = ([datetimeoffset]$v.created).ToUnixTimeMilliseconds() / 1000.0

  $sshArgs = $sshBase + @("$User@$ip", "echo $b64 | base64 -d | bash -s -- $cEpoch")
  $out = & ssh @sshArgs 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $out) {
    Write-Host "  ssh/collect failed" -ForegroundColor Yellow; continue
  }

  $line = @($out) | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1
  if (-not $line) { Write-Host "  no JSON from guest" -ForegroundColor Yellow; continue }
  $r = $line | ConvertFrom-Json

  $row = [pscustomobject]@{
    VM = $v.name; PreBoot = $r.PreBoot; Ready = $r.Ready; Workload = $r.Workload; CIDone = $r.CIDone
  }
  $rows += $row
  Write-Host ("  PreBoot={0}s  Ready={1}s  Workload={2}s  CIDone={3}s" -f `
    $row.PreBoot, $row.Ready, $row.Workload, $row.CIDone)
}

if ($rows.Count) {
  Write-Host "`n=== MEDIANS (n=$($rows.Count)) ==="
  Write-Host ("PreBoot={0}s  Ready={1}s  Workload={2}s  CIDone={3}s" -f `
    (Median $rows.PreBoot), (Median $rows.Ready), (Median $rows.Workload), (Median $rows.CIDone))
  $rows | Format-Table -AutoSize
}
