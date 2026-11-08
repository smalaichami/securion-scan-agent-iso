#!/usr/bin/env bash
# securion-netconfig — give the appliance a PREDICTABLE address with zero per-site config.
#
# It learns the subnet from the current (DHCP) lease and switches the box to a STATIC IP =
# the LAST usable host in that subnet (e.g. 192.168.0.254 on a /24), keeping the DHCP-
# provided gateway + DNS. So the operator always reaches a headless appliance at "the last
# IP of whatever LAN it's plugged into" — no monitor, no IP hunting, and it adapts to any
# site's subnet automatically.
#
# Safe by design — it will NOT strand itself:
#   • skips if it can't read the network yet,
#   • skips if it's already at the target static,
#   • skips if the target is already IN USE by another host (arping duplicate check),
#   • mDNS (securion-agent.local) still works as a fallback regardless.
# Disable entirely with SECURION_STATIC_LAST_IP=0 in /etc/securion/agent.env.
set -euo pipefail

log() { echo "securion-netconfig: $*"; }

# Opt-out hook.
if [[ -f /etc/securion/agent.env ]]; then
  # shellcheck disable=SC1091
  . /etc/securion/agent.env 2>/dev/null || true
fi
if [[ "${SECURION_STATIC_LAST_IP:-1}" == "0" ]]; then
  log "disabled via SECURION_STATIC_LAST_IP=0; leaving DHCP"
  exit 0
fi

iface=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
[[ -n "${iface:-}" ]] || { log "no default IPv4 route yet; skipping"; exit 0; }
cidr=$(ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}')
[[ -n "${cidr:-}" ]] || { log "no IPv4 on $iface; skipping"; exit 0; }
cur_ip=${cidr%/*}
prefix=${cidr#*/}
gw=$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')

# Only act on a real subnet that has a usable host range.
if ((prefix < 8 || prefix > 30)); then
  log "prefix /$prefix has no usable range here; skipping"
  exit 0
fi

ip2int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}
int2ip() {
  local n=$1
  echo "$(((n >> 24) & 255)).$(((n >> 16) & 255)).$(((n >> 8) & 255)).$((n & 255))"
}

ipint=$(ip2int "$cur_ip")
mask=$(((0xffffffff << (32 - prefix)) & 0xffffffff))
net=$((ipint & mask))
bcast=$((net | (~mask & 0xffffffff)))
target=$(int2ip $((bcast - 1))) # last usable host

if [[ "$cur_ip" == "$target" ]]; then
  log "already at last-usable static $target/$prefix; nothing to do"
  exit 0
fi

# Conflict check: another host already using the target? arping -D exits non-zero if in use.
if command -v arping >/dev/null 2>&1; then
  if ! arping -q -D -c 2 -w 2 -I "$iface" "$target" >/dev/null 2>&1; then
    log "target $target appears to be IN USE on $iface — keeping DHCP to avoid a clash"
    exit 0
  fi
fi

# DNS: reuse the resolver already in effect, else fall back to the gateway.
dns=$(resolvectl dns "$iface" 2>/dev/null | awk '{print $NF}' | grep -E '^[0-9]+\.' || true)
[[ -n "${dns:-}" ]] || dns="$gw"

log "assigning static $target/$prefix (gw $gw, dns $dns) on $iface"

if systemctl is-active --quiet NetworkManager 2>/dev/null && command -v nmcli >/dev/null 2>&1; then
  con=$(nmcli -t -g GENERAL.CONNECTION device show "$iface" 2>/dev/null | head -1)
  [[ -n "${con:-}" ]] || con="Wired connection 1"
  nmcli con mod "$con" ipv4.addresses "$target/$prefix" ipv4.gateway "$gw" ipv4.dns "$dns" ipv4.method manual
  nmcli con up "$con" >/dev/null
elif command -v netplan >/dev/null 2>&1; then
  cat >/etc/netplan/99-securion-static.yaml <<EOF
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: no
      addresses: [$target/$prefix]
      routes:
        - to: default
          via: $gw
      nameservers:
        addresses: [$dns]
EOF
  chmod 600 /etc/netplan/99-securion-static.yaml
  netplan apply
else
  log "no NetworkManager or netplan found; cannot set static — leaving DHCP"
  exit 0
fi

log "static address set: reach this box at $target (or securion-agent.local)"
