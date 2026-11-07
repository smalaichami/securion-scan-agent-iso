# securion-scan-agent-iso

**Distribution / packaging** repo for the Securion on-prem scan agent appliance.
Source code lives in the private `securion-scan-agent` repo; this public repo holds:

- **Prebuilt binaries** as GitHub **Release** assets — `securion-agent-linux-amd64`
  and `securion-agent-linux-arm64` — so cloud-init / Packer / pi-gen can download them
  with no auth.
- **`deploy/bootstrap.sh`** — self-contained appliance installer (deps + binary download
  + systemd units + enable).
- **`deploy/cloud-init/`** — `user-data.yaml` provisioner + test notes.

## Quick start (auto-installing VM / appliance)

Boot a stock Ubuntu/Debian cloud image with `deploy/cloud-init/user-data.yaml` as the
cloud-init user-data (edit `SCAN_ALLOW` to your LAN first), or on any fresh Debian/Ubuntu
host run:

```sh
curl -fsSL https://raw.githubusercontent.com/smalaichami/securion-scan-agent-iso/main/deploy/bootstrap.sh | sudo bash
```

The **org Scan Key is never baked in** — enroll it at first boot via the loopback console
(`http://127.0.0.1:7878`). A VM scanner's network adapter must be **bridged** (not NAT).

See `deploy/cloud-init/README.md` for VirtualBox / multipass test steps.
