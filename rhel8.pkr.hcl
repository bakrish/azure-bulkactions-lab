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

# Source definition for Azure ARM builder
source "azure-arm" "rhel8" {
  # NATIVE AZURE CLI AUTHENTICATION
  use_azure_cli_auth = true
  subscription_id    = var.subscription_id

  # Destination Managed Image configuration
  managed_image_name                = "rhel8-optimized-image"
  managed_image_resource_group_name = var.resource_group
  location                          = var.location

  # Baseline Source Image: Official Red Hat Enterprise Linux 8 (Gen2 Architectural Profile)
  image_publisher = "RedHat"
  image_offer     = "RHEL"
  image_sku       = "8-lvm-gen2"
  image_version   = "latest"

  # Temporary VM sizing used exclusively for building the image
  os_type         = "Linux"
  vm_size         = "Standard_D2s_v5"
}

# Execution Pipeline
build {
  sources = ["source.azure-arm.rhel8"]

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
      # Compile changes into the RHEL 8 legacy UEFI/BIOS config mapping destination 
      "grub2-mkconfig -o /boot/grub2/grub.cfg",

      "echo '======================================================'",
      "echo '==> 2. Mitigating Systemd Journal Queue Bottlenecks'",
      "echo '======================================================'",
      # Rotate current active memory pools and drop the persistent byte indexes to 10MB
      "journalctl --rotate",
      "journalctl --vacuum-size=10M",

      "echo '======================================================'",
      "echo '==> 3. Boot-Speed Optimization (Spot / time-critical)'",
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
      "systemctl disable update-client-package.timer",
      "systemctl disable update-client-package.service",
      "echo '#!/bin/sh' >  /usr/local/bin/update-client-package.sh",
      "echo 'exit 0'    >> /usr/local/bin/update-client-package.sh",
      "chmod 0755 /usr/local/bin/update-client-package.sh",

      "echo '======================================================'",
      "echo '==> 4. Final Deprovisioning & Generalization'",
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