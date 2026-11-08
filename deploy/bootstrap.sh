#!/usr/bin/env bash
# Securion scan-agent appliance bootstrap — turns a fresh Debian/Ubuntu host into the
# agent in one shot: install scan tools, fetch the agent binary from the public
# distribution repo's latest release, write the systemd units + config, and enable the
# always-on sniffer + nightly scan.
#
# Self-contained (no repo checkout needed) — safe to run from cloud-init, Packer,
# pi-gen, or by hand:
#
#   curl -fsSL https://raw.githubusercontent.com/smalaichami/securion-scan-agent-iso/main/deploy/bootstrap.sh | sudo bash
#
# Optional environment overrides (never bake secrets into an image):
#   SECURION_AGENT_RELEASE  release tag to pin (default: latest)
#   SECURION_BACKEND_URL    override the backend (default: baked api.securion.ai/agents)
#
# NOTHING per-site is configured here — no Scan Key, no scope. At first boot, open the
# loopback web console (http://127.0.0.1:7878, SSH-tunnelled) and enter the org Scan Key;
# the scan scope defaults to the box's own LAN (auto-detected) and can be overridden in
# that same console. Re-runnable.
set -euo pipefail

ISO_REPO="smalaichami/securion-scan-agent-iso"
REL="${SECURION_AGENT_RELEASE:-latest}"

if [[ $EUID -ne 0 ]]; then
  echo "error: run as root (sudo)." >&2
  exit 1
fi

echo "==> installing scan tools (nmap, masscan, arp-scan)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
# avahi-daemon → reachable as securion-agent.local (mDNS); iputils-arping → the
# static-last-IP conflict check (see securion-netconfig below).
apt-get install -y --no-install-recommends nmap masscan arp-scan curl ca-certificates avahi-daemon iputils-arping

ARCH="$(dpkg --print-architecture)" # amd64 | arm64
case "$ARCH" in
  amd64 | arm64) ;;
  *)
    echo "error: unsupported arch '$ARCH' (need amd64 or arm64)." >&2
    exit 1
    ;;
esac

if [[ "$REL" == "latest" ]]; then
  url="https://github.com/${ISO_REPO}/releases/latest/download/securion-agent-linux-${ARCH}"
else
  url="https://github.com/${ISO_REPO}/releases/download/${REL}/securion-agent-linux-${ARCH}"
fi

echo "==> downloading agent ($ARCH) from $url"
tmp="$(mktemp)"
curl -fSL --retry 3 "$url" -o "$tmp"
install -m 0755 "$tmp" /usr/local/bin/securion-agent
rm -f "$tmp"
/usr/local/bin/securion-agent -h >/dev/null 2>&1 || true # smoke the binary runs on this arch

echo "==> config: /etc/securion + /var/lib/securion"
install -d -m 0750 /var/lib/securion
install -d /etc/securion

# No scope file: the scan scope is set from the web console (stored in the local SQLite)
# or auto-detected from the box's LAN — see the securion-scan.service note below. If you
# passed SCAN_ALLOW to this script, enter it in the console instead (one config point).

# Optional sniffer env (pin the LAN interface with -iface here if needed).
if [[ ! -f /etc/securion/agent.env ]]; then
  {
    echo "# Sniffer env (optional). Append '-iface eth0' to pin the capture interface."
    echo "# Set SECURION_STATIC_LAST_IP=0 to keep plain DHCP (skip the last-usable-IP step)."
    [[ -n "${SECURION_BACKEND_URL:-}" ]] && echo "SECURION_BACKEND_URL=${SECURION_BACKEND_URL}"
  } >/etc/securion/agent.env
fi

# Fixed hostname so the box is reachable at securion-agent.local (mDNS/avahi) regardless
# of its IP. Skip on a machine that clearly isn't a dedicated appliance would be nicer,
# but for the appliance this identity is intended.
hostnamectl set-hostname securion-agent 2>/dev/null || true

echo "==> installing securion-netconfig (predictable last-usable-IP static address)"
curl -fSL --retry 3 \
  "https://raw.githubusercontent.com/${ISO_REPO}/main/deploy/securion-netconfig.sh" \
  -o /usr/local/bin/securion-netconfig
chmod 0755 /usr/local/bin/securion-netconfig

echo "==> writing systemd units"
cat >/etc/systemd/system/securion-netconfig.service <<'UNIT'
[Unit]
Description=Securion appliance — assign the last usable LAN IP as a predictable static address
After=network-online.target
Wants=network-online.target
# Reach the console/sniffer at the predictable address right away.
Before=securion-dhcp-sniffer.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/securion-netconfig
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/securion-dhcp-sniffer.service <<'UNIT'
[Unit]
Description=Securion DHCP fingerprint sniffer + local console (passive, always-on)
Documentation=https://github.com/smalaichami/securion-scan-agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
StateDirectory=securion
EnvironmentFile=-/etc/securion/agent.env
# -scan-on-connect: when a brand-new device joins the LAN, auto-run a light scan of it
# (§V1.8g) and push it — so new devices surface without waiting for the nightly run.
# Scope = the console/auto scan scope; honours the exclude list.
ExecStart=/usr/local/bin/securion-agent -sniff -scan-on-connect
Restart=always
RestartSec=5
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/securion-vuln-update.service <<'UNIT'
[Unit]
Description=Securion scan-agent — refresh offline vulnerability feeds (NVD/KEV/EPSS)
Documentation=https://github.com/smalaichami/securion-scan-agent
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/securion-agent -vuln-update
TimeoutStartSec=30min
Nice=10
IOSchedulingClass=idle
UNIT

cat >/etc/systemd/system/securion-vuln-update.timer <<'UNIT'
[Unit]
Description=Daily Securion vulnerability-feed refresh

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

cat >/etc/systemd/system/securion-scan.service <<'UNIT'
[Unit]
Description=Securion scan-agent — nightly full scan (fingerbank + vuln correlation + push)
Documentation=https://github.com/smalaichami/securion-scan-agent
Wants=network-online.target
After=network-online.target
Wants=securion-vuln-update.service
After=securion-vuln-update.service

[Service]
Type=oneshot
WorkingDirectory=/var/lib/securion
# No -allow: the agent resolves the scan scope itself — the operator-set scope from the
# web console if present, otherwise the auto-detected local LAN subnet. So the console is
# the only thing to configure (Key + optional scope); nothing is baked into the image.
# -version-all: the nightly run is unattended, so use max nmap version intensity for the
# most thorough CVE/version coverage. Hosts still scan in parallel (default concurrency),
# so it stays reasonable. Drop -version-all for a faster interactive run.
ExecStart=/usr/local/bin/securion-agent -version-all -fingerbank -vuln -push -report /var/lib/securion/scan-report.txt
TimeoutStartSec=2h
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=6
UNIT

cat >/etc/systemd/system/securion-scan.timer <<'UNIT'
[Unit]
Description=Nightly Securion full network scan

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

echo "==> enabling services (sniffer now; feed + scan on their timers)"
systemctl daemon-reload
systemctl enable securion-netconfig.service
systemctl enable --now securion-dhcp-sniffer.service
systemctl enable --now securion-vuln-update.timer securion-scan.timer

cat <<'DONE'

==> Provisioned. The box is NOT yet enrolled.

Reach this headless box (no monitor needed) by NAME or by the predictable static IP it
takes on next boot (the last usable host of its LAN, e.g. .254 on a /24):
  # by name (mDNS — same LAN):
  ssh -L 7878:127.0.0.1:7878 securion@securion-agent.local
  # or by the last-usable IP once it has rebooted onto the LAN.

Then open http://127.0.0.1:7878 → paste the org Scan Key → "Linked to <org>".
(The scan scope defaults to this box's LAN; override it in the same console.)
Note: the static address is applied on the next boot; reboot once after provisioning.

Then verify a scan immediately (optional):
  sudo systemctl start securion-vuln-update.service   # first feed pull (~hundreds of MB)
  sudo systemctl start securion-scan.service
  journalctl -u securion-scan.service -f
DONE
