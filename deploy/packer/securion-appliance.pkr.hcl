# Packer template — builds a Securion scan-agent appliance OVA for VirtualBox.
#
# What it produces: an .ova you Import into VirtualBox, set the NIC to BRIDGED, boot, open
# the web console, enter the Scan Key — done. OS + nmap/masscan/arp-scan + the agent +
# systemd units are all baked in (via deploy/bootstrap.sh). No Scan Key or scope is baked:
# the box auto-detects its LAN and the console is the only config point.
#
# Run on a machine with VirtualBox + Packer (your Windows box):
#   packer init securion-appliance.pkr.hcl
#   packer build securion-appliance.pkr.hcl
#
# NOTE: the Ubuntu point-release filename changes over time — check
# https://releases.ubuntu.com/24.04/ and update `iso_url` if the build 404s. The
# `file:` checksum auto-matches whatever filename you set from that same SHA256SUMS.

packer {
  required_plugins {
    virtualbox = {
      source  = "github.com/hashicorp/virtualbox"
      version = "~> 1"
    }
  }
}

variable "iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-amd64.iso"
}
variable "iso_checksum" {
  type    = string
  default = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
}
variable "cpus" {
  type    = number
  default = 4
}
variable "memory" {
  type    = number
  default = 4096
}
variable "disk_size" {
  type    = number
  default = 20000 # MB
}

source "virtualbox-iso" "securion" {
  guest_os_type = "Ubuntu_64"
  iso_url       = var.iso_url
  iso_checksum  = var.iso_checksum

  cpus      = var.cpus
  memory    = var.memory
  disk_size = var.disk_size

  headless = true
  format   = "ova"

  # Serve the Subiquity autoinstall config (http/user-data + http/meta-data).
  http_directory = "http"

  # Boot the Ubuntu live-server installer into unattended autoinstall by dropping to the
  # GRUB command line and pointing cloud-init's NoCloud datasource at Packer's HTTP server.
  boot_wait = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz autoinstall \"ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/\" ---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  # Build-time SSH login (created by the autoinstall identity). Removed/locked by seal.sh.
  ssh_username             = "securion"
  ssh_password             = "securion"
  ssh_timeout              = "40m"
  ssh_handshake_attempts   = 200
  shutdown_command         = "echo 'securion' | sudo -S shutdown -P now"
  guest_additions_mode     = "disable"
  virtualbox_version_file  = ""

  vboxmanage = [
    ["modifyvm", "{{ .Name }}", "--nat-localhostreachable1", "on"],
    ["modifyvm", "{{ .Name }}", "--audio-driver", "none"],
  ]
}

build {
  name    = "securion-appliance"
  sources = ["source.virtualbox-iso.securion"]

  # 1) Install the agent exactly as a real deployment would (deps + binary + systemd).
  provisioner "shell" {
    execute_command = "echo 'securion' | sudo -S -E bash '{{ .Path }}'"
    inline = [
      "cloud-init status --wait || true",
      "curl -fsSL https://raw.githubusercontent.com/smalaichami/securion-scan-agent-iso/main/deploy/bootstrap.sh | bash",
    ]
  }

  # 2) Appliance hygiene: unique machine-id + SSH host keys per deployed clone, clean logs.
  provisioner "shell" {
    execute_command = "echo 'securion' | sudo -S -E bash '{{ .Path }}'"
    script          = "scripts/seal.sh"
  }
}
