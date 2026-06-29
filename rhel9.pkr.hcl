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
  # You can hardcode your ID below if you prefer not to pass it via CLI:
  # default     = "46427a45-8a0a-4c2e-b5ba-91ba905139f6"
}

variable "resource_group" {
  type        = string
  default     = "rg-images-prod"
  description = "The destination Resource Group for the final Managed Image."
}

variable "location" {
  type        = string
  default     = "South East Asia"
  description = "The Azure region where the temporary VM will spin up."
}

variable "sig_image_version" {
  type        = string
  default     = "1.0.5"
  description = "Version published to the SIG image definition. SIG versions are IMMUTABLE -- bump this for every build (1.0.0 - 1.0.4 already exist)."
}

# Source definition for Azure ARM builder
source "azure-arm" "rhel9" {
  # NATIVE AZURE CLI AUTHENTICATION
  use_azure_cli_auth = true
  subscription_id    = var.subscription_id

  # Build VM region (also the SIG version's source region). Gallery sig_rhel home = southeastasia.
  location = var.location

  # Publish the captured image DIRECTLY into the Shared Image Gallery as a new
  # version -- no intermediate managed image, no manual `az sig image-version create`
  # capture, and the uksouth replication is done inline (was a separate manual step).
  # NOTE: SIG versions are immutable; bump var.sig_image_version each build.
  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = var.resource_group
    gallery_name         = "sig_rhel"
    image_name           = "rhel9opt"
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

  # Baseline Source Image: Red Hat Enterprise Linux 9, non-LVM "raw" (single XFS
  # root partition), Gen2 (UEFI). Raw images live under the SEPARATE `rhel-raw`
  # offer (NOT `RHEL`), with minor-pinned SKUs (9_8 = latest minor, `-gen2` suffix
  # = Gen2); `latest` tracks its patch builds. Gen2-raw is the leanest baseline:
  # initrd ~2.8s (vs 4.6s on LVM-Gen1, which carried LVM dm-activation + BIOS
  # serial-probe waits). A/B baseline = the rhel-raw:9_8-gen2 marketplace run.
  image_publisher = "RedHat"
  image_offer     = "rhel-raw"
  image_sku       = "9_8-gen2"
  image_version   = "latest"

  # Temporary VM sizing used exclusively for building the image
  os_type = "Linux"
  vm_size = "Standard_D2s_v5"
}

# Execution Pipeline
build {
  sources = ["source.azure-arm.rhel9"]

  provisioner "shell" {
    # Forces execution via root environment wrappers across the Azure temporary admin framework.
    # `sh -e` aborts the build on the first failed command instead of silently
    # continuing (otherwise only the last command's exit code is ever checked).
    execute_command = "chmod +x {{ .Path }}; signup=1 sudo -E sh -e '{{ .Path }}'"

    inline = [
      "echo '======================================================'",
      "echo '==> 1. Tuning GRUB Timeout to 0 seconds (Instant Boot)'",
      "echo '======================================================'",
      # Set timeout configuration line item natively
      "sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub",
      # Suppress the GRUB menu UI unconditionally (independent of GRUB_TIMEOUT).
      # menu_auto_hide only hides the menu AFTER a prior successful boot; a fresh
      # cloud VM has had none, so the first (measured) boot can still flash/initialize
      # the menu even at timeout 0. Idempotent: RHEL ships /etc/default/grub WITHOUT
      # this key, so a plain sed-substitute would not add it -> delete-then-append.
      "sed -i '/^GRUB_TIMEOUT_STYLE=/d' /etc/default/grub",
      "echo 'GRUB_TIMEOUT_STYLE=hidden' >> /etc/default/grub",
      # Compile changes into the RHEL 9 legacy UEFI/BIOS config mapping destination 
      "grub2-mkconfig -o /boot/grub2/grub.cfg",

      "echo '======================================================'",
      "echo '==> 2. Boot-Speed Optimization (Spot / time-critical)'",
      "echo '======================================================'",
      # Remove the ~19s first-boot crash-kernel initramfs rebuild.
      # Portable: only affects kdump.img; the primary boot initramfs is untouched,
      # so the image stays bootable across all Gen2/x64 VM families.
      "systemctl disable kdump.service",

      # Block the per-boot RHUI client-package fetch (~80s of CPU/IO/network
      # contention at t=0). The base image is always built from the latest minor
      # RHEL release, so the RHUI client package is already current — nothing to
      # refresh on these short-lived Spot VMs.
      #
      # The work is launched by update-client-package.TIMER (TriggeredBy), NOT by a
      # multi-user.target.wants hook, so disabling the .service alone does nothing.
      # Disable the timer so the service is never activated, AND neutralize the
      # script as a trigger-proof backstop in case a systemd preset re-enables the
      # timer at first boot.
      # "systemctl disable update-client-package.timer",
      # "systemctl disable update-client-package.service",
      # "echo '#!/bin/sh' >  /usr/local/bin/update-client-package.sh",
      # "echo 'exit 0'    >> /usr/local/bin/update-client-package.sh",
      # "chmod 0755 /usr/local/bin/update-client-package.sh",

      "echo '======================================================'",
      "echo '==> 2b. Initrd slimming (dracut hostonly + Azure allowlist)'",
      "echo '======================================================'",
      # RHEL cloud images ship a GENERIC (hostonly=no) initramfs carrying drivers
      # for every platform (VMware, bare-metal SAS/FC/iSCSI, exotic RAID, ...).
      # This image only ever boots on Azure, so the initrd loads+probes far more
      # than it needs -> the ~3.1s initrd line in Table A, and the bimodal probe
      # tail. hostonly=yes tells dracut to build with only THIS platform's drivers.
      #
      # Pure auto-hostonly would bake in only the build host's storage path
      # (v5 = SCSI/hv_storvsc) and OMIT nvme -> a move to an NVMe-presenting SKU
      # (v6 series) could then fail to find root. So we hostonly for the slimness
      # but EXPLICITLY force-include the full set of drivers Azure could ever
      # present root/networking through. This stays bulletproof across any
      # Intel<->AMD swap and SCSI<->NVMe generation jump, while still dropping the
      # genuinely-useless non-Azure drivers. (Arm/Cobalt is a different arch and
      # needs its own image regardless -- intentionally out of scope.)
      #
      # CRITICAL: RHEL cloud images ship the `dracut-config-generic` package,
      # which drops /usr/lib/dracut/dracut.conf.d/02-generic-image.conf with
      # hostonly=no. dracut sources conf files alphabetically, LAST-WINS, across
      # BOTH /etc/dracut.conf.d and /usr/lib/dracut/dracut.conf.d -- so a plain
      # /etc/dracut.conf.d/01-azure.conf is OVERRIDDEN by 02-generic-image.conf
      # (proven: VMware/SAS/FC drivers survived a hostonly build). Fix = (a) remove
      # the generic-config package so the override is gone at the source, AND
      # (b) name our drop-in 99- so nothing can sort after it if a kernel update
      # ever pulls the package back.
      "dnf -y remove dracut-config-generic",
      "printf 'hostonly=\"yes\"\\nadd_drivers+=\" hv_vmbus hv_storvsc hv_netvsc hv_utils nvme nvme_core \"\\n' > /etc/dracut.conf.d/99-azure.conf",
      # Regenerate the initramfs for the installed kernel(s) with the new policy.
      "dracut --force --regenerate-all",

      "echo '======================================================'",
      "echo '==> 2c. cloud-init trim (in-guest workload-readiness)'",
      "echo '======================================================'",
      # MEASURED (cloud-init analyze show) on the optimized image:
      #   config-disk_setup  2.572s   <- mkfs/GPT on the ~75GB ephemeral resource
      #   config-mounts      0.431s      disk (/dev/sdb) EVERY first boot, then
      #                                  fstab-wires it at /mnt + sets up swap.
      # This is the single largest tunable cost in the whole boot. On a short-lived
      # Spot bulk VM that never reuses /mnt it is pure tax (~3.0s, mid init-network,
      # gating the workload). Remove BOTH modules from the cloud_init_modules run
      # list so the ephemeral disk is left untouched.
      #   TRADE-OFF: /dev/sdb is no longer auto-partitioned/formatted/mounted and no
      #   swap is created -- a workload that needs local-SSD scratch must format it
      #   itself. Accepted for this fast-boot fleet.
      # Editing the run list (not just the cloud-config) is the deterministic switch:
      # the module simply never executes regardless of datasource-injected config.
      "sed -i '/^[[:space:]]*-[[:space:]]*disk_setup[[:space:]]*$/d' /etc/cloud/cloud.cfg",
      "sed -i '/^[[:space:]]*-[[:space:]]*mounts[[:space:]]*$/d' /etc/cloud/cloud.cfg",
      # Pin the datasource so cloud-init-local does not probe non-Azure datasources.
      "printf 'datasource_list: [ Azure ]\\n' > /etc/cloud/cloud.cfg.d/90-datasource.cfg",
      # NetworkManager-wait-online sits on the critical chain (~0.6s) gating
      # network-online.target; cloud-init brings up + manages networking itself on
      # Azure, so the extra systemd wait is redundant here.
      "systemctl disable NetworkManager-wait-online.service",

      "echo '======================================================'",
      "echo '==> 3. Final Deprovisioning & Generalization'",
      "echo '======================================================'",
      # Strip out baseline execution shell tracking metadata records
      "rm -f /root/.bash_history",
      "rm -f /home/azureuser/.bash_history",
      "export HISTSIZE=0",

      # Signal Azure Linux Agent to purge deployment user structures & configurations safely
      "/usr/sbin/waagent -force -deprovision+user"
    ]
  }
}