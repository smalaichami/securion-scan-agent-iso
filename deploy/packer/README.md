# Packer — Securion appliance OVA

Builds a ready-to-run **VirtualBox OVA**: OS + scan tools + the Securion agent + systemd
units all baked in. Import it, boot, open the web console, enter the Scan Key — done.
Nothing per-site is baked (no Key, no scope — the box auto-detects its LAN).

Full background: [`docs/vm-appliance-auto-install.md`](../../docs/vm-appliance-auto-install.md).

## Prerequisites (on your Windows build box)

- **VirtualBox** (7.x) + its extension pack.
- **Packer** (`choco install packer`, or from hashicorp.com).
- Internet (downloads the Ubuntu ISO + the agent from the public release).

## Build

```powershell
cd deploy\packer
packer init securion-appliance.pkr.hcl
packer build securion-appliance.pkr.hcl
```

Output: `output-securion-appliance\securion-appliance.ova` (~1–2 GB). Build takes ~15–30 min
(ISO download + unattended install + provision + export).

Override specs if you like:

```powershell
packer build -var cpus=4 -var memory=4096 -var disk_size=20000 securion-appliance.pkr.hcl
```

## Deploy the OVA

1. VirtualBox → **File ▸ Import Appliance** → pick the `.ova`.
2. **Set the network adapter to _Bridged_** (⚠️ not NAT) on the NIC facing the LAN to scan.
3. Boot.
4. From your machine, tunnel to the loopback console and enter the Key:
   ```bash
   ssh -L 7878:127.0.0.1:7878 securion@<vm-ip>      # default build password: securion
   # open http://127.0.0.1:7878 → paste the Scan Key → "Linked to <org>"
   # scan scope defaults to the box's LAN; override it in the same console.
   ```
5. The nightly scan runs on its timer; to test now: `sudo systemctl start securion-scan.service`.

## What's baked in

- Ubuntu Server 24.04 (minimal, headless), `nmap` / `masscan` / `arp-scan`.
- `/usr/local/bin/securion-agent` + the sniffer, nightly-scan, and feed-refresh systemd units.
- **Offline CVE feeds** (NVD/KEV/EPSS, in `/var/lib/securion/feeds`) — so the **first** scan
  already correlates CVEs instead of waiting for the deploy-time download. They're shared
  data (not per-box identity), and the nightly `securion-vuln-update.timer` keeps them
  current on the deployed box. (This is the main reason the OVA is ~hundreds of MB larger
  and the build takes a few minutes longer.)
- **No secrets, no scope** — entered once at the console.
- Appliance hygiene (`scripts/seal.sh`): machine-id + SSH host keys regenerate per deployed
  clone, logs/history cleared, build-time passwordless sudo removed.

The OVA always bakes the **latest** `securion-agent` from the iso release, so every build
automatically carries the current agent behaviour:

- **Parallel host scanning** (default 6 at once) + `-T4` / masscan rate 5000 — a /24 scans
  in minutes, not ~an hour. Tunable with `-concurrency` / `-rate` on the scan unit.
- **Deep nightly scan** — `securion-scan.service` runs `-version-all` (max version/CVE
  intensity) for the unattended nightly run; still parallel, so it stays fast.
- **Console action buttons** — "Run scan now" + "Refresh CVE feeds".

To pick up newer agent behaviour in a future image, just rebuild — it pulls the newest
release.

## Notes / gotchas

- **ISO filename drifts.** Ubuntu bumps the 24.04 point release (…24.04.3 → .4). If the
  download 404s, update `iso_url` in the template to the current file at
  <https://releases.ubuntu.com/24.04/>; the `file:` checksum matches it automatically.
- **Can't build on Apple Silicon.** VirtualBox needs an x86-64 host (your Windows box) — a
  Mac M-series can't build this OVA.
- **boot_command is version-sensitive.** The GRUB command-line boot works for 24.04
  live-server; if a future ISO changes the boot path you may need to tweak it.
- **Security (before shipping to customers):** the image has a default `securion/securion`
  login for the console tunnel — change the password and/or move to key-only SSH, and
  consider re-adding mount-namespace hardening to the units.
