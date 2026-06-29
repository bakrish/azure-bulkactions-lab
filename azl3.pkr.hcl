packer {
  required_plugins {
    azure = {
      version = ">= 2.0.0"
      source  = "github.com/hashicorp/azure"
    }
  }
}

# =============================================================================
# ORCHESTRATION DISCRIMINATOR: AzureLinux 3.0 -> SIG (FAITHFUL capture)
# -----------------------------------------------------------------------------
# Purpose: take a KNOWN-FAST base (AZL 3.0 marketplace, orch p50 ~4-5.1) and put
# it through the SAME SIG/gallery path as rhel9opt, to isolate whether the ~9s
# orchestration latency tracks the gallery-resolution PATH or the image LINEAGE.
#   - AZL-SIG ~5  -> SIG path is neutral; rhel9opt is the artifact outlier.
#   - AZL-SIG ~9  -> gallery resolution imposes a floor regardless of base.
# DECISIVE READ = AZL-SIG vs rhel9opt-SIG fired SAME-WINDOW (cancels diurnal).
#
# This build is intentionally a FAITHFUL capture: deprovision/generalize ONLY,
# NO boot/GRUB/kdump tuning, so the only delta vs marketplace AZL is the SIG
# wrapper itself. Security-type parity with rhel9opt is held at the image
# DEFINITION level (azl3raw created with SecurityType=TrustedLaunchSupported,
# matching rhel9opt) so security type cannot confound orchestration.
# NOTE: AZL 3.0 is an in-guest DEAD-END (4.0 is a rearchitecture), but this test
# only measures ORCHESTRATION (control-plane, pre-hydration, lineage-based), for
# which 3.0 is valid and comparable to the existing AZL-mkt baseline.
# =============================================================================

variable "subscription_id" {
  type        = string
  description = "The target Azure Subscription ID where the image will be built and stored."
  # default     = "46427a45-8a0a-4c2e-b5ba-91ba905139f6"
}

variable "resource_group" {
  type        = string
  default     = "rg-images-prod"
  description = "Resource group that owns the destination Shared Image Gallery."
}

variable "location" {
  type        = string
  default     = "South East Asia"
  description = "The Azure region where the temporary build VM will spin up (also the SIG version source region)."
}

variable "sig_image_version" {
  type        = string
  default     = "1.0.0"
  description = "Version published to the azl3raw SIG image definition. SIG versions are IMMUTABLE -- bump for every build (azl3raw is new, so 1.0.0 is free initially)."
}

source "azure-arm" "azl3" {
  use_azure_cli_auth = true
  subscription_id    = var.subscription_id

  # Build VM region (also the SIG version's source region). Gallery sig_rhel home = southeastasia.
  location = var.location

  # Publish the captured image DIRECTLY into the Shared Image Gallery as a new
  # version of the azl3raw definition, replicating inline to SEA (build/source,
  # required) + uksouth (where the fleet is provisioned). No managed image, no
  # manual capture/replication. SIG versions are immutable; bump var.sig_image_version.
  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = var.resource_group
    gallery_name         = "sig_rhel"
    image_name           = "azl3raw"
    image_version        = var.sig_image_version
    storage_account_type = "Standard_LRS"

    # The build region MUST be a target region (primary/source replica)...
    target_region {
      name = lower(replace(var.location, " ", ""))
    }
    # ...and uksouth is where we provision the fleet from.
    target_region {
      name = "uksouth"
    }
  }

  # Baseline Source Image: Azure Linux 3.0, Gen2 (UEFI), plan-free. EXACT URN of
  # the marketplace AZL we already measured (mkt orch p50 ~4.0-5.1) so the SIG
  # capture's only variable is the gallery wrapper.
  image_publisher = "MicrosoftCBLMariner"
  image_offer     = "azure-linux-3"
  image_sku       = "azure-linux-3-gen2"
  image_version   = "latest"

  # Temporary VM sizing used exclusively for building the image
  os_type = "Linux"
  vm_size = "Standard_D2s_v5"
}

# Execution Pipeline -- FAITHFUL capture: generalize ONLY, no tuning.
build {
  sources = ["source.azure-arm.azl3"]

  provisioner "shell" {
    # `sh -e` aborts the build on the first failed command instead of silently
    # continuing (otherwise only the last command's exit code is ever checked).
    execute_command = "chmod +x {{ .Path }}; signup=1 sudo -E sh -e '{{ .Path }}'"

    inline = [
      "echo '======================================================'",
      "echo '==> Faithful capture: deprovision & generalize ONLY'",
      "echo '======================================================'",
      "export HISTSIZE=0",
      # AZL 3.0 provisions via CLOUD-INIT, not WALinuxAgent (no waagent binary).
      # Generalize the cloud-init way: clear instance state + seed + logs, and
      # reset machine-id (truncate to empty -> systemd regenerates on next boot),
      # so the captured image re-provisions cleanly (new admin user + SSH key) on
      # every fleet VM. This is the cloud-init analogue of `waagent -deprovision+user`.
      "cloud-init clean --logs --seed",
      "rm -rf /var/lib/cloud/instances /var/lib/cloud/instance",
      "truncate -s 0 /etc/machine-id",
      "rm -f /root/.bash_history"
    ]
  }
}
