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
#   # or:  sudo SCAN_ALLOW=192.168.1.0/24 bash deploy/bootstrap.sh
#
# Per-deployment values come from the environment (never baked into an image):
#   SCAN_ALLOW              scan scope CIDR (default 192.168.0.0/24) — EDIT THIS
#   SCAN_EXCLUDE            optional never-scan CIDR/IP (e.g. the gateway)
#   SECURION_AGENT_RELEASE  release tag to pin (default: latest)
#   SECURION_BACKEND_URL    override the backend (default: baked api.securion.ai/agents)
#
# The org Scan Key is NOT set here — enroll at first boot via the loopback console
# (http://127.0.0.1:7878, SSH-tunnelled). Re-runnable.
set -euo pipefail

ISO_REPO="smalaichami/securion-scan-agent-iso"
REL="${SECURION_AGENT_RELEASE:-latest}"
SCAN_ALLOW="${SCAN_ALLOW:-192.168.0.0/24}"

if [[ $EUID -ne 0 ]]; then
  echo "error: run as root (sudo)." >&2
  exit 1
fi

echo "==> installing scan tools (nmap, masscan, arp-scan)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends nmap masscan arp-scan curl ca-certificates

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

# Nightly-scan scope. Kept if it already exists (re-runs won't clobber an edited scope).
if [[ ! -f /etc/securion/scan.env ]]; then
  {
    echo "# Securion scan-agent — nightly scan scope. EDIT SCAN_ALLOW for your LAN."
    echo "SCAN_ALLOW=${SCAN_ALLOW}"
    [[ -n "${SCAN_EXCLUDE:-}" ]] && echo "SCAN_EXCLUDE=${SCAN_EXCLUDE}"
  } >/etc/securion/scan.env
fi

# Optional sniffer env (pin the LAN interface with -iface here if needed).
if [[ ! -f /etc/securion/agent.env ]]; then
  {
    echo "# Sniffer env (optional). Append '-iface eth0' to pin the capture interface."
    [[ -n "${SECURION_BACKEND_URL:-}" ]] && echo "SECURION_BACKEND_URL=${SECURION_BACKEND_URL}"
  } >/etc/securion/agent.env
fi

echo "==> writing systemd units"
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
ExecStart=/usr/local/bin/securion-agent -sniff
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
EnvironmentFile=/etc/securion/scan.env
WorkingDirectory=/var/lib/securion
ExecStart=/usr/local/bin/securion-agent -allow ${SCAN_ALLOW} -fingerbank -vuln -push -report /var/lib/securion/scan-report.txt
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
systemctl enable --now securion-dhcp-sniffer.service
systemctl enable --now securion-vuln-update.timer securion-scan.timer

cat <<'DONE'

==> Provisioned. The box is NOT yet enrolled.

Next (one time), enroll the org Scan Key via the loopback console:
  # from your laptop:
  ssh -L 7878:127.0.0.1:7878 <user>@<this-host>
  # then open http://127.0.0.1:7878 and paste the Scan Key  →  "Linked to <org>"

Then verify a scan immediately (optional):
  sudo systemctl start securion-vuln-update.service   # first feed pull (~hundreds of MB)
  sudo systemctl start securion-scan.service
  journalctl -u securion-scan.service -f

Edit the scan scope any time in /etc/securion/scan.env (SCAN_ALLOW=...), then:
  sudo systemctl restart securion-scan.service   # or wait for the nightly timer
DONE
