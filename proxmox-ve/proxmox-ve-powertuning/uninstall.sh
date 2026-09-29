#!/usr/bin/env bash
# uninstall.sh — remove v620-powertuning
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root." >&2
	exit 1
fi

PKG=v620-powertuning
VER=1.0

systemctl disable --now v620-powercap.service 2>/dev/null || true
rm -f /etc/systemd/system/v620-powercap.service
systemctl daemon-reload

dkms remove "${PKG}/${VER}" --all 2>/dev/null || true
rm -rf "/usr/src/${PKG}-${VER}"

rm -f /usr/local/sbin/v620-cap-apply.sh
rm -f /usr/share/initramfs-tools/hooks/v620_powertuning
rm -f /usr/share/initramfs-tools/scripts/init-premount/v620_powertuning

echo "Rebuilding initramfs for running kernel..."
update-initramfs -u -k "$(uname -r)"

echo "Done. /etc/default/v620-powertuning was left in place; remove it manually if desired."
echo "The in-tree amdgpu module will be used again after a reboot."
