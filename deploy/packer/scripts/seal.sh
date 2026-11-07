#!/usr/bin/env bash
# Appliance hygiene run at the end of the Packer build, so every deployed clone of the OVA
# is unique and clean — not a carbon copy that shares identity/keys with every other box.
set -euo pipefail

echo "==> apt: clean caches"
apt-get -y autoremove --purge || true
apt-get -y clean || true
rm -rf /var/lib/apt/lists/*

echo "==> reset machine-id (regenerated per boot -> unique DHCP lease / identity)"
: >/etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

echo "==> remove SSH host keys + ensure they regenerate on first boot (unique per box)"
rm -f /etc/ssh/ssh_host_*
cat >/etc/systemd/system/regen-ssh-hostkeys.service <<'UNIT'
[Unit]
Description=Regenerate SSH host keys on first boot (sealed appliance image)
ConditionFileNotEmpty=|!/etc/ssh/ssh_host_ed25519_key
Before=ssh.service
[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl enable regen-ssh-hostkeys.service || true

# The 'securion' user stays usable — the operator SSHes in to tunnel to the loopback
# console (http://127.0.0.1:7878). Drop the build-time passwordless sudo so sudo prompts
# for the password. NOTE (production): change this default password and/or switch to
# key-only SSH before shipping — the OVA ships with a known default (securion/securion).
echo "==> drop build-time passwordless sudo (operator sudo now requires the password)"
rm -f /etc/sudoers.d/securion-build || true

echo "==> clear cloud-init state (deployed VM re-inits network cleanly; our setup is already baked)"
cloud-init clean --logs || true

echo "==> truncate logs + shell history"
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
rm -f /root/.bash_history /home/securion/.bash_history || true

echo "seal: done"
