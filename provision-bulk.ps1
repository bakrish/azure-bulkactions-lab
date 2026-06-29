<#
  provision-bulk.ps1 -- bulk Spot VM launch via the (preview) BulkActions API.

  Uses the launchBulkInstancesOperations RESOURCE (PUT), exactly as the BulkActions SDK does
  -- NOT the virtualMachinesBulkCreate action verb (whose passthrough body fails per-VM RG
  resolution on this subscription). The resource lives in the Microsoft.ComputeBulkActions RP
  and is served ONLY from the REGIONAL ARM endpoint (https://<region>.management.azure.com).
  It is created with `az rest --method put`:
      PUT https://<region>.management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ComputeBulkActions/locations/<loc>/launchBulkInstancesOperations/<operationId>
  (api-version 2026-02-01-preview). RG + location come from the URL.

  The body mirrors the SDK model: properties.computeProfile.virtualMachineProfile is the
  standard VM template; capacity/capacityType set the count; vmSizesProfile sets sizing;
  priorityProfile.type='Spot' makes them Spot. The RP auto-generates the VM resource names,
  so the measurement harness (measure-ssh.ps1 / fleet-measure.py) enumerates them unchanged.

  Unlike `az vm create`, BulkActions needs an EXISTING SSH public key (no --generate-ssh-keys)
  and base-64 CustomData -- this wrapper supplies both.

  Examples:
    ./provision-bulk.ps1
    ./provision-bulk.ps1 -Image "Canonical:ubuntu-24_04-lts:server:latest" -Count 10
    ./provision-bulk.ps1 -Size Standard_D4ads_v5 -Count 25

  PREVIEW: requires the Microsoft.ComputeBulkActions provider registered on the subscription
  (az provider register --namespace Microsoft.ComputeBulkActions).
#>
[CmdletBinding()]
param(
  [string] $Image              = "RedHat:RHEL:810-gen2:latest",
  [int]    $Count              = 10,
  [string] $Size               = "Standard_D2ads_v5",
  [int]    $OsDiskSizeGB        = 0,            # 0 = use image default; else EXPAND to this (cannot shrink below image size)
  [string] $ResourcePrefix     = "vmbulk",
  [string] $ResourceGroup      = "rg-test",    # disposable: holds only the VMs
  [string] $InfraResourceGroup = "rg-infra",   # persistent: vnet/subnet/jump (setup-infra.ps1)
  [string] $Vnet               = "vnet-rhel",
  [string] $Subnet             = "sub-rhel",
  [string] $Region             = "uksouth",
  [string] $Admin              = "azureuser",
  [string] $PublicKeyPath      = "$HOME\.ssh\id_rsa.pub",
  [switch] $UsePlan,
  [switch] $UseAttributes,
  [int]    $MinVCpu            = 2,
  [int]    $MaxVCpu            = 4,
  [double] $MinMemGiB          = 4,
  [double] $MaxMemGiB          = 16,
  [string] $Arch               = 'X64',
  [int]    $PollSeconds        = 15,
  [int]    $MaxPolls           = 60
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2026-02-01-preview'

# --- Image: Marketplace URN (Publisher:Offer:Sku:Version) OR a full image resource ID
#     (Azure Compute Gallery image version or managed image, e.g. in rg-image-prod) -----
if ($Image -like '/subscriptions/*') {
  # Gallery image version or managed image -> reference by ARM resource id.
  $imageReference = [ordered]@{ id = $Image }
}
else {
  $parts = $Image -split ':'
  if ($parts.Count -ne 4) {
    throw "Image must be a full URN 'Publisher:Offer:Sku:Version' or a full image resource ID (got '$Image')."
  }
  $imgPublisher, $imgOffer, $imgSku, $imgVersion = $parts
  $imageReference = [ordered]@{
    publisher = $imgPublisher
    offer     = $imgOffer
    sku       = $imgSku
    version   = $imgVersion
  }
  # Marketplace plan (name=sku, product=offer, publisher=publisher). Only used when -UsePlan.
  $planRef = [ordered]@{ name = $imgSku; product = $imgOffer; publisher = $imgPublisher }
}

# --- SSH public key ---------------------------------------------------------
if (-not (Test-Path $PublicKeyPath)) {
  throw "SSH public key not found at $PublicKeyPath. Generate one with: ssh-keygen -t rsa -b 4096"
}
$pubKey = (Get-Content -Raw $PublicKeyPath).Trim()

# --- CustomData (LF-normalized, base64) ------------------------------------
$customDataPath = Join-Path $PSScriptRoot 'customdata-stamp.sh'
if (-not (Test-Path $customDataPath)) { throw "customdata-stamp.sh not found next to this script." }
$cdBody = (Get-Content -Raw $customDataPath) -replace "`r`n", "`n"
$customDataB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cdBody))

# --- Subscription + subnet --------------------------------------------------
$subId = az account show --query id -o tsv
if (-not $subId) { throw "Not logged in -- run 'az login'." }
$subnetId = az network vnet subnet show -g $InfraResourceGroup --vnet-name $Vnet -n $Subnet --query id -o tsv
if (-not $subnetId) { throw "Subnet not found -- run setup-infra.ps1 first." }

# --- Disposable RG ----------------------------------------------------------
az group create -n $ResourceGroup -l $Region -o none

# --- operation id: names the launchBulkInstancesOperations resource ---------
$operationId = [guid]::NewGuid().ToString()

# computerName prefix: keep short so the RP can append a per-VM suffix.
$cn = $ResourcePrefix
if ($cn.Length -gt 11) { $cn = $cn.Substring(0, 11) }

# --- Build the LaunchBulkInstancesOperation body ---------------------------
# properties.computeProfile.virtualMachineProfile is the standard VM template;
# capacity/capacityType set the count; vmSizesProfile sets sizing; Spot via
# priorityProfile.type. RG + location come from the URL (no RG field in the body).
$body = [ordered]@{
  properties = [ordered]@{
    capacityType    = 'VM'
    capacity        = $Count
    priorityProfile = [ordered]@{ type = 'Spot' }
    vmSizesProfile  = @(
      [ordered]@{ name = $Size }
    )
    computeProfile = [ordered]@{
      virtualMachineProfile = [ordered]@{
        storageProfile = [ordered]@{
          imageReference = $imageReference
          osDisk = [ordered]@{
            osType       = 'Linux'
            createOption = 'FromImage'
            deleteOption = 'Delete'
            caching      = 'ReadWrite'
            managedDisk  = @{ storageAccountType = 'Premium_LRS' }
          }
        }
        osProfile = [ordered]@{
          computerName  = $cn
          adminUsername = $Admin
          customData    = $customDataB64
          linuxConfiguration = [ordered]@{
            disablePasswordAuthentication = $true
            ssh = @{
              publicKeys = @(
                [ordered]@{
                  path    = "/home/$Admin/.ssh/authorized_keys"
                  keyData = $pubKey
                }
              )
            }
          }
        }
        networkProfile = [ordered]@{
          networkApiVersion = '2020-11-01'
          networkInterfaceConfigurations = @(
            [ordered]@{
              name       = 'nic'
              properties = [ordered]@{
                primary            = $true
                enableIPForwarding = $true
                ipConfigurations = @(
                  [ordered]@{
                    name       = 'ip'
                    properties = [ordered]@{
                      primary = $true
                      subnet  = @{ id = $subnetId }
                    }
                  }
                )
              }
            }
          )
        }
      }
    }
  }
}

# Optional OS-disk expansion (cannot shrink below the image's native size).
if ($OsDiskSizeGB -gt 0) {
  $body.properties.computeProfile.virtualMachineProfile.storageProfile.osDisk.diskSizeGB = $OsDiskSizeGB
}

# Attribute-based selection: describe the VM shape instead of pinning a SKU.
# vmAttributes is a sibling of vmSizesProfile under properties and is mutually
# exclusive with it -- so drop vmSizesProfile when -UseAttributes is set.
if ($UseAttributes) {
  $body.properties.Remove('vmSizesProfile') | Out-Null
  $body.properties.vmAttributes = [ordered]@{
    vCpuCount         = [ordered]@{ min = $MinVCpu;   max = $MaxVCpu }
    memoryInGiB       = [ordered]@{ min = $MinMemGiB; max = $MaxMemGiB }
    architectureTypes = @($Arch)
  }
}

# Optional Marketplace plan (required by some images, e.g. Flatcar). Plan is a
# top-level sibling of 'properties' on the bulk resource (ResourcePlanProperty).
if ($UsePlan) {
  if (-not $planRef) { throw "-UsePlan requires a Marketplace URN image, not an image resource id." }
  Write-Host "Accepting Marketplace terms for $Image ..."
  az vm image terms accept --urn $Image -o none
  if ($LASTEXITCODE -ne 0) { throw "Failed to accept Marketplace terms for $Image." }
  $body.plan = $planRef
}

$json    = $body | ConvertTo-Json -Depth 40
$tmpBody = [System.IO.Path]::GetTempFileName()
Set-Content -Path $tmpBody -Value $json -Encoding UTF8

# --- Submit: PUT the launchBulkInstancesOperations resource (LRO) -----------
# The BulkActions preview type is served only from the REGIONAL ARM endpoint
# (https://<region>.management.azure.com), not the global management.azure.com.
$armHost = "https://$Region.management.azure.com"
$putUri = "$armHost/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.ComputeBulkActions/locations/$Region/launchBulkInstancesOperations/${operationId}?api-version=$apiVersion"
$sizeDesc = if ($UseAttributes) { "attrs[vCpu $MinVCpu-$MaxVCpu, mem $MinMemGiB-$MaxMemGiB GiB, $Arch]" } else { $Size }
Write-Host "Submitting bulk launch ($operationId): $Count x $sizeDesc ($Image), Spot ..."
$createRaw = & { $ErrorActionPreference='Continue'; az rest --method put --uri $putUri --resource "https://management.azure.com/" --headers "Content-Type=application/json" --body "@$tmpBody" -o json 2>&1 }
$putExit = $LASTEXITCODE
Remove-Item $tmpBody -Force -ErrorAction SilentlyContinue
if ($putExit -ne 0) {
  Write-Host "Bulk launch PUT failed (exit $putExit) -- raw response:" -ForegroundColor Yellow
  foreach ($l in @($createRaw)) { Write-Host "    | $l" -ForegroundColor Yellow }
  exit $putExit
}

# --- Poll the bulk action's VM list until all reach a terminal state --------
# Best-effort: the authoritative result is the `az vm list` below.
$vmListUri = "$armHost/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.ComputeBulkActions/locations/$Region/launchBulkInstancesOperations/${operationId}/virtualMachines?api-version=$apiVersion"
Write-Host "Polling bulk action VM status ..."
for ($i = 0; $i -lt $MaxPolls; $i++) {
  $listRaw = az rest --method get --uri $vmListUri --resource "https://management.azure.com/" -o json 2>$null
  if ($LASTEXITCODE -eq 0 -and $listRaw) {
    $list = $listRaw | ConvertFrom-Json
    $vms  = @($list.value)
    $succeeded = @($vms | Where-Object { $_.operationStatus -eq 'Succeeded' -or $_.properties.operationStatus -eq 'Succeeded' }).Count
    $failed    = @($vms | Where-Object { $_.operationStatus -eq 'Failed'    -or $_.properties.operationStatus -eq 'Failed' }).Count
    $creating  = @($vms | Where-Object { $_.operationStatus -eq 'Creating'  -or $_.properties.operationStatus -eq 'Creating' }).Count
    Write-Host ("  [{0:d2}] total {1}  succeeded {2}  creating {3}  failed {4}" -f $i, $vms.Count, $succeeded, $creating, $failed)
    if ($vms.Count -ge $Count -and $creating -eq 0) { break }
  }
  Start-Sleep -Seconds $PollSeconds
}

# --- Report -----------------------------------------------------------------
Write-Host "`nVMs in ${ResourceGroup}:" -ForegroundColor Green
az vm list -g $ResourceGroup -d --query "[].{name:name, power:powerState, ip:privateIps}" -o table

Write-Host "`nbulk operationId: $operationId"
Write-Host "Measure:  ./measure-ssh.ps1 -ResourceGroup $ResourceGroup -JumpHost <jump-ip>"
Write-Host "Cleanup:  az group delete -n $ResourceGroup --yes --no-wait"
