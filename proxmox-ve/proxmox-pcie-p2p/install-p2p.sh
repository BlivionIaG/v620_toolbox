#!/usr/bin/env bash
# install-p2p.sh — enable PCIe P2P between V620 cards on Proxmox VE 9.x
# (light path only — see README.md "Heavy path" if preflight fails)
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root." >&2
	exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Running preflight"
if ! "$HERE/scripts/v620-p2p-preflight.sh"; then
	echo
	echo "Preflight failed or this kernel needs the heavy path. See README.md" >&2
	echo "'Heavy path' section before proceeding further." >&2
	exit 1
fi

echo
echo "==> Making sure the v620-powertuning DKMS module (power cap fix) is installed"
if ! dkms status 2>/dev/null | grep -q '^v620-powertuning'; then
	echo "v620-powertuning DKMS module not found."
	echo "Run ../proxmox-ve-powertuning/install.sh first (this P2P module reuses the same patch/service)." >&2
	exit 1
fi
echo "    OK: $(dkms status 2>/dev/null | grep '^v620-powertuning')"

echo
echo "==> Installing amdgpu pcie_p2p module param"
install -Dm644 "$HERE/etc-modprobe.d/v620-p2p.conf" /etc/modprobe.d/v620-p2p.conf

echo "==> Rebuilding initramfs so the param is picked up before amdgpu loads"
update-initramfs -u -k "$(uname -r)"

echo "==> Installing verify script"
install -Dm755 "$HERE/scripts/verify-p2p.sh" /usr/local/sbin/v620-verify-p2p.sh

echo
echo "==> Done. Reboot, then run:"
echo "  sudo v620-verify-p2p.sh"
