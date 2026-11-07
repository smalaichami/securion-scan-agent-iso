# Cloud-init appliance — testing

`user-data.yaml` turns a stock Ubuntu/Debian cloud image into a Securion scan-agent on
first boot. Full background in
[`docs/vm-appliance-auto-install.md`](../../docs/vm-appliance-auto-install.md).

## Prerequisites

1. The public repo **`smalaichami/securion-scan-agent-iso`** exists and hosts:
   - `deploy/bootstrap.sh` (on the `main` branch — the raw URL the user-data fetches), and
   - a **release** with assets `securion-agent-linux-amd64` and `securion-agent-linux-arm64`
     (published by `.github/workflows/release.yml` in this repo, or uploaded by hand).
2. Edit `SCAN_ALLOW` in `user-data.yaml` to the subnet you want to scan.

> **Networking:** give the VM a **BRIDGED** adapter (not NAT) so it gets an IP on the
> real LAN and can arp-scan / masscan / DHCP-sniff it. With NAT the scan finds nothing.

## Test A — multipass (fastest)

```bash
multipass launch --name securion-agent --network en0 --cloud-init user-data.yaml
#   --network <iface>  attaches a bridged NIC on the host interface facing your LAN
multipass shell securion-agent
systemctl status securion-dhcp-sniffer.service
```

## Test B — any hypervisor via a seed ISO (portable)

```bash
# meta-data can be minimal:
printf 'instance-id: securion-agent\nlocal-hostname: securion-agent\n' > meta-data
cloud-localds seed.iso user-data.yaml meta-data     # from the cloud-image-utils package

# download an Ubuntu/Debian cloud image (qcow2/img), then boot it with seed.iso
# attached as a SECOND drive, adapter = Bridged. cloud-init runs user-data on first boot.
```

Then on the VM:

```bash
cloud-init status --wait            # provisioning done
uname -m                            # aarch64 (arm64) or x86_64 (amd64)
systemctl list-timers 'securion-*'  # scan + feed timers armed
```

## Testing before the iso repo exists

The cloud-init form fetches `bootstrap.sh` from the iso repo. To test earlier, copy a
built binary to the VM and run the bootstrap locally — it only needs the binary release
for the download step, which you can skip by placing the binary yourself:

```bash
# build + copy a binary for the VM's arch (amd64 for a PC VM)
GOOS=linux GOARCH=amd64 go build -o securion-agent ./cmd/agent
scp securion-agent <user>@<vm>:/tmp/
# on the VM: install it where bootstrap expects, then run bootstrap (it keeps an existing binary)
sudo install -m0755 /tmp/securion-agent /usr/local/bin/securion-agent
sudo SCAN_ALLOW=192.168.1.0/24 bash deploy/bootstrap.sh   # re-downloads unless you pre-place it
```

(Once the release assets are published, `bootstrap.sh` downloads the binary itself and
no manual copy is needed.)

## After provisioning — enroll

The box is installed but not enrolled. Enter the org Scan Key via the loopback console:

```bash
ssh -L 7878:127.0.0.1:7878 <user>@<this-host>
# open http://127.0.0.1:7878 → paste the Scan Key → "Linked to <org>"
```
