packer {
  required_plugins {
    azure = {
      version = ">= 2.0.0"
      source  = "github.com/hashicorp/azure"
    }
  }
}

# Variable declaration for clean execution configuration
variable "subscription_id" {
  type        = string
  description = "The target Azure Subscription ID where the image will be built and stored."
  # default     = "46427a45-8a0a-4c2e-b5ba-91ba905139f6"
}

variable "resource_group" {
  type        = string
  default     = "rg-images-prod"
  description = "The destination Resource Group that owns the Shared Image Gallery."
}

variable "location" {
  type        = string
  default     = "South East Asia"
  description = "The Azure region where the temporary build VM spins up (also the SIG version source region). Gallery sig_rhel home = southeastasia."
}

variable "sig_image_version" {
  type        = string
  default     = "2.0.0"
  description = "Version published to the SIG image definition. SIG versions are IMMUTABLE -- bump this for every build. (1.0.x = the experimental hand-tuned line, RETIRED; 2.0.0 = faithful pass-through capture of Canonical Ubuntu Minimal, no tuning -- see build block.)"
}

# Source definition for Azure ARM builder
source "azure-arm" "ubuntu" {
  # NATIVE AZURE CLI AUTHENTICATION
  use_azure_cli_auth = true
  subscription_id    = var.subscription_id

  # Build VM region (also the SIG version's source region). Gallery sig_rhel home = southeastasia.
  location = var.location

  # Publish the captured image DIRECTLY into the Shared Image Gallery as a new
  # version -- no intermediate managed image, no manual capture, uksouth replication
  # done inline. NOTE: SIG versions are immutable; bump var.sig_image_version each build.
  # PREREQ: the `ubuntuopt` image DEFINITION must already exist in gallery sig_rhel
  #   (V2 / x64 / Linux / Generalized, SecurityType=TrustedLaunchSupported), e.g.
  #   az sig image-definition create -g rg-images-prod -r sig_rhel -i ubuntuopt \
  #     --publisher me --offer ubuntu --sku 24_04-opt --os-type Linux \
  #     --os-state Generalized --hyper-v-generation V2 --architecture x64 \
  #     --features SecurityType=TrustedLaunchSupported
  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = var.resource_group
    gallery_name         = "sig_rhel"
    image_name           = "ubuntuopt"
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

  # Source Image: Canonical Ubuntu 24.04 LTS *Minimal*, Gen2 (UEFI). This is the
  # official, supported Canonical SKU -- NOT a hand-tuned build. Minimal ships a
  # reduced package set and (critically) does NOT snap-seed on first boot, which is
  # where ~all of its "~40% faster boot than standard server" comes from. It is
  # plan-free (no Marketplace terms) and tracks Canonical's normal support/security
  # maintenance. We capture it 1:1 (deprovision only) so the customer's gallery
  # image stays a faithful mirror with no per-release re-validation burden.
  image_publisher = "Canonical"
  image_offer     = "ubuntu-24_04-lts"
  image_sku       = "minimal"
  image_version   = "latest"

  # Temporary VM sizing used exclusively for building the image
  os_type = "Linux"
  vm_size = "Standard_D2s_v5"
}

# Execution Pipeline
build {
  sources = ["source.azure-arm.ubuntu"]

  provisioner "shell" {
    # `sh -e` aborts the build on the first failed command instead of silently
    # continuing (otherwise only the last command's exit code is ever checked).
    execute_command = "chmod +x {{ .Path }}; sudo -E sh -e '{{ .Path }}'"

    inline = [
      "echo '======================================================'",
      "echo '==> Faithful capture of Ubuntu Minimal + snap pre-seed'",
      "echo '======================================================'",
      # TIER-1 / NO-SNOWFLAKE POLICY: this image removes NOTHING and changes no OS
      # behaviour. It captures Canonical's supported Ubuntu Minimal SKU into the
      # customer's own Shared Image Gallery (for governance / image scanning /
      # region control) and makes exactly ONE, capability-preserving change: it
      # COMPLETES Canonical's own snap seed at build time instead of deferring it
      # to the fleet's first boot.
      #
      #   WHY: the marketplace "Minimal = no snap seeding" claim does NOT hold in
      #   this provisioning context. MEASURED: snapd.seeded.service still runs and
      #   sits ~43s ON the first-boot critical chain (bimodal; p50 sd-Total ~54s,
      #   right on top of stock server ~57s). That 43s is the one-time seed of the
      #   snaps Canonical stages into the image.
      #
      #   FIX (zero functionality lost): `snap wait system seed.loaded` blocks until
      #   seeding finishes HERE, during the build. The captured image then ships
      #   already-seeded, so the fleet's first-boot snapd.seeded finds the work done
      #   and returns in <1s -- reclaiming the ~43s WHILE keeping snap fully
      #   functional (snap install / refresh / Ubuntu Pro Livepatch all work). We
      #   deliberately do NOT purge snapd: that would also kill Livepatch and any
      #   snap-delivered tooling. apt/dpkg OS+app patching is unaffected either way.
      #
      #   Still NO GRUB / initramfs / cloud-init / networkd / AppArmor edits -- that
      #   is where the real per-release maintenance/snowflake risk lived, and it
      #   stays out. The hand-tuned 1.0.x line is RETIRED (preserved in git).

      # Complete Canonical's staged snap seed now so the fleet's first boot does not
      # pay the ~43s snapd.seeded tax. Capability-preserving: snapd stays installed
      # and fully functional. Blocks until seeding is done (the build host has
      # network). Guarded so a future base image without snapd will not fail here.
      "command -v snap >/dev/null 2>&1 && snap wait system seed.loaded || echo 'snap not present; skipping pre-seed'",

      # Strip baseline shell history.
      "rm -f /root/.bash_history",
      "rm -f /home/azureuser/.bash_history",
      "export HISTSIZE=0",

      # Ubuntu marketplace images carry the Microsoft Azure Linux Agent
      # (walinuxagent). Deprovision + remove the build user for a clean generalize.
      "/usr/sbin/waagent -force -deprovision+user"
    ]
  }
}
