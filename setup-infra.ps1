<#
  setup-infra.ps1 -- persistent measurement infrastructure (build once, keep).

  Creates ONE resource group holding everything that should outlive the test
  fleet: the VNet/subnet, an NSG (inbound 22 locked to your IP), and a jump VM
  with a public IP. Test VMs are provisioned into a SEPARATE, disposable RG and
  simply join this subnet -- so you can delete/recreate the test RG freely while
  the jump, key, and network stay put.

  Layout:
    rg-infra (this script)            rg-test (provision-rhel810-spot.ps1)
      vnet-rhel / sub-rhel              N spot VMs --> join sub-rhel
      nsg-rhel (inbound 22 from you)
      jump (Ubuntu, public IP, azureuser)

  Usage:
    ./setup-infra.ps1
    ./setup-infra.ps1 -ResourceGroup rg-infra -Location uksouth
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup = 'rg-infra',
  [string] $Location      = 'uksouth',
  [string] $Vnet          = 'vnet-rhel',
  [string] $Subnet        = 'sub-rhel',
  [string] $Nsg           = 'nsg-rhel',
  [string] $JumpName      = 'jump',
  [string] $User          = 'azureuser',
  [string] $AllowCidr                          # default: auto-detect this machine's /32
)

$ErrorActionPreference = 'Stop'

if (-not $AllowCidr) {
  try   { $AllowCidr = (Invoke-RestMethod 'https://api.ipify.org').Trim() + '/32' }
  catch { throw "Could not auto-detect your public IP; pass -AllowCidr <ip/cidr>." }
}
Write-Host "Infra RG=$ResourceGroup  region=$Location  SSH allowed from $AllowCidr" -ForegroundColor Cyan

az group create -n $ResourceGroup -l $Location -o none

# NSG: allow inbound 22 from your IP only.
az network nsg create -g $ResourceGroup -n $Nsg -o none
az network nsg rule create -g $ResourceGroup --nsg-name $Nsg -n allow-ssh `
    --priority 300 --access Allow --protocol Tcp --direction Inbound `
    --source-address-prefixes $AllowCidr --destination-port-ranges 22 -o none

# VNet + subnet (NSG attached at subnet level).
az network vnet create -g $ResourceGroup -n $Vnet --address-prefix 10.0.0.0/16 `
    --subnet-name $Subnet --subnet-prefix 10.0.0.0/24 --nsg $Nsg -o none
$subnetId = az network vnet subnet show -g $ResourceGroup --vnet-name $Vnet -n $Subnet --query id -o tsv

# Jump VM: same admin user as the fleet so one -User covers both SSH hops.
az vm create -g $ResourceGroup -n $JumpName `
    --image Ubuntu2204 `
    --admin-username $User `
    --subnet $subnetId `
    --nsg '""' `
    --generate-ssh-keys `
    --public-ip-sku Standard `
    -o none
$jumpIp = az vm list-ip-addresses -g $ResourceGroup -n $JumpName `
    --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv

Write-Host "`nInfra ready." -ForegroundColor Green
Write-Host "  Jump public IP : $jumpIp"
Write-Host "  Subnet ID      : $subnetId"
Write-Host "`nNext:" -ForegroundColor Green
Write-Host "  ./provision-rhel810-spot.ps1                       # creates rg-test VMs on this subnet"
Write-Host "  ./measure-ssh.ps1 -ResourceGroup rg-test -JumpHost $jumpIp"
