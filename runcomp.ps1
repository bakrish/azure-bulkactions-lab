# Reference-build harness: 5x AZL 3.0 in the RECOMMENDED config, ON-DEMAND so the
# number is stable/defensible. (Single-SKU Spot is intrinsically noisy -- that's a
# Fleet-basket concern, not a boot concern, so we don't measure it here.)
#   Trusted Launch (--security-type TrustedLaunch): Secure Boot + vTPM, basic, no
#     guest-attestation extension. Adds ~2s to guest boot.
#   Pre-staged subnet (--subnet ... --nsg ""): zero inline network creation.
#   ReadOnly OS cache (--os-disk-caching ReadOnly): sensible read-heavy-boot default.
# VMs persist (cleanup = final RG delete). Footprint = 5 x D2s_v5 = 10 vCPU.
$image = "MicrosoftCBLMariner:azure-linux-3:azure-linux-3-gen2:latest"

function Measure-Arm {
  param($Label, $Rg, $Count, [string[]]$Extra)
  $rows = @()
  for ($i = 1; $i -le $Count; $i++) {
    $vm = "$Label-$i"
    az vm create -g $Rg -n $vm --image $image --size Standard_D2s_v5 `
        --admin-username azureuser --generate-ssh-keys --public-ip-address '""' @Extra -o none
    if ($LASTEXITCODE -ne 0) {
      Write-Host ("  {0}: CREATE FAILED (exit {1}) -- likely Spot capacity" -f $vm, $LASTEXITCODE) -ForegroundColor Yellow
      continue
    }
    $iv      = az vm get-instance-view -g $Rg -n $vm -o json | ConvertFrom-Json
    $created = [datetimeoffset]$iv.timeCreated
    $succ    = [datetimeoffset]($iv.instanceView.statuses | ? code -eq 'ProvisioningState/succeeded').time
    $msg     = az vm run-command invoke -g $Rg -n $vm --command-id RunShellScript --scripts "uptime -s" --query "value[0].message" -o tsv
    $stamp   = ([regex]'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}').Match($msg).Value
    $boot    = [datetimeoffset]($stamp.Replace(' ','T') + "Z")
    $row = [pscustomobject]@{
      VM      = $vm
      PreBoot = [math]::Round(($boot - $created).TotalSeconds, 1)
      Guest   = [math]::Round(($succ - $boot).TotalSeconds, 1)
      E2E     = [math]::Round(($succ - $created).TotalSeconds, 1)
    }
    $rows += $row
    Write-Host ("  {0}: PreBoot={1}s Guest={2}s E2E={3}s" -f $vm, $row.PreBoot, $row.Guest, $row.E2E)
  }
  return $rows
}

function Median($arr) {
  $s = @($arr | Sort-Object); $n = $s.Count
  if ($n -eq 0) { return $null }
  if ($n % 2) { return $s[[int][math]::Floor($n/2)] }
  return [math]::Round(($s[$n/2 - 1] + $s[$n/2]) / 2, 1)
}

$region = "uksouth"; $rg = "rg-boottest-spot"
az group create -n $rg -l $region -o none

# Pre-stage a shared VNet/subnet (+NSG on the subnet) once, up front.
az network nsg create -g $rg -n nsg-boot -o none
az network vnet create -g $rg -n vnet-boot --address-prefix 10.0.0.0/16 `
    --subnet-name sub-boot --subnet-prefix 10.0.0.0/24 --nsg nsg-boot -o none
$subnetId = az network vnet subnet show -g $rg --vnet-name vnet-boot -n sub-boot --query id -o tsv

$ref = @('--subnet', $subnetId, '--nsg', '""',
         '--security-type', 'TrustedLaunch', '--os-disk-caching', 'ReadOnly')

Write-Host "`n--- AZL 3.0 reference build (on-demand, Trusted Launch, pre-staged subnet, ReadOnly cache) ---"
$arm = Measure-Arm -Label "ref" -Rg $rg -Count 5 -Extra $ref

Write-Host "`n=== MEDIANS (AZL 3.0 reference build, n=5) ==="
Write-Host ("Ref: PreBoot={0}s  Guest={1}s  E2E={2}s" -f (Median $arm.PreBoot), (Median $arm.Guest), (Median $arm.E2E))
Write-Host "`nCleanup: az group delete -n $rg --yes --no-wait"