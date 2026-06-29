# Quick scaffold: provision N Spot VMs in UK South on the persistent rg-infra subnet.
# Uses an Azure Marketplace (gallery) image -- NOT a custom/managed image.
#   -Image default: RedHat:RHEL:810-gen2:latest  (Gen2, official Red Hat publisher)
#   Eviction: Deallocate (keeps the disk so the VM can be restarted on capacity)
#   Max price: -1  (pay up to the on-demand price; never evicted on price, only capacity)
# VMs go into a DISPOSABLE test RG but join the persistent VNet/subnet created by
# setup-infra.ps1 (rg-infra) -- so this RG can be torn down/recreated freely.
# CustomData (customdata-stamp.sh) stamps the workload-start instant; measurement
# is run separately afterward (measure-ssh.ps1 / fleet-measure.py).
#
# Provisioning is PARALLEL: all creates are submitted with --no-wait (each az call
# returns as soon as the ARM request is accepted), then a single wait phase blocks
# on `az vm wait --created` per VM. Wall time collapses from sum-of-creates to about
# the slowest single create -- the measurement harness is unaffected (it reads each
# VM's own timeCreated, so parallel birth is fine).
#
# Examples:
#   ./provision-rhel810-spot.ps1
#   ./provision-rhel810-spot.ps1 -Image Ubuntu2204 -NamePrefix ubuntu-spot -Count 5
#   ./provision-rhel810-spot.ps1 -Image Debian12 -Size Standard_D2as_v5
[CmdletBinding()]
param(
  [string] $Image              = "RedHat:RHEL:810-gen2:latest",
  [string] $NamePrefix         = "vm-spot",
  [int]    $Count              = 10,
  [string] $Size               = "Standard_D2ads_v5",
  [string] $ResourceGroup      = "rg-test",    # disposable: holds only the VMs
  [string] $InfraResourceGroup = "rg-infra",   # persistent: vnet/subnet/jump (setup-infra.ps1)
  [string] $Vnet               = "vnet-rhel",
  [string] $Subnet             = "sub-rhel",
  [string] $Region             = "uksouth",
  [string] $Admin              = "azureuser"
)

$customData = Join-Path $PSScriptRoot 'customdata-stamp.sh'

# Reference the persistent subnet by resource ID (lives in rg-infra).
$subnetId = az network vnet subnet show -g $InfraResourceGroup --vnet-name $Vnet -n $Subnet --query id -o tsv
if (-not $subnetId) { throw "Subnet not found -- run setup-infra.ps1 first." }

az group create -n $ResourceGroup -l $Region -o none

# Phase 1: submit all creates in parallel (--no-wait returns once ARM accepts the
# request; actual provisioning runs server-side concurrently). The loop fires the
# az calls one after another, so --generate-ssh-keys generates the local key once
# on the first call and the rest reuse it -- no key-generation race.
$submitted = @()
for ($i = 1; $i -le $Count; $i++) {
  $vm = "$NamePrefix-$i"
  Write-Host "--- Submitting $vm (Spot, $Size, $Image) ---"
  az vm create -g $ResourceGroup -n $vm `
      --image $Image `
      --size $Size `
      --priority Spot `
      --eviction-policy Deallocate `
      --max-price -1 `
      --admin-username $Admin `
      --generate-ssh-keys `
      --subnet $subnetId `
      --nsg '""' `
      --public-ip-address '""' `
      --os-disk-caching ReadOnly `
      --custom-data "@$customData" `
      --no-wait `
      -o none
  if ($LASTEXITCODE -ne 0) {
    Write-Host ("  {0}: SUBMIT FAILED (exit {1})" -f $vm, $LASTEXITCODE) -ForegroundColor Yellow
    continue
  }
  $submitted += $vm
  Write-Host ("  {0}: submitted" -f $vm) -ForegroundColor Green
}

# Phase 2: wait for all in-flight creates to finish. Since provisioning is already
# running concurrently server-side, waiting on each in turn costs ~the slowest VM,
# not the sum. `az vm wait --created` blocks until provisioningState == Succeeded.
Write-Host "`nWaiting for $($submitted.Count) VM(s) to finish provisioning..."
$ok = 0
foreach ($vm in $submitted) {
  az vm wait -g $ResourceGroup -n $vm --created -o none
  if ($LASTEXITCODE -ne 0) {
    Write-Host ("  {0}: PROVISION FAILED -- likely Spot capacity" -f $vm) -ForegroundColor Yellow
  } else {
    $ok++
    Write-Host ("  {0}: ready" -f $vm) -ForegroundColor Green
  }
}

Write-Host ("`nProvisioned {0}/{1} VM(s)." -f $ok, $Count)
Write-Host "Cleanup: az group delete -n $ResourceGroup --yes --no-wait"
