#!/usr/bin/env bash
# install.sh — set up v620-powertuning on Proxmox VE 9.x
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root." >&2
	exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG=v620-powertuning
VER=1.0
DEST="/usr/src/${PKG}-${VER}"

echo "==> Checking prerequisites"
NEED_PKGS=()
command -v dkms      >/dev/null 2>&1 || NEED_PKGS+=(dkms)
command -v make       >/dev/null 2>&1 || NEED_PKGS+=(build-essential)
command -v gcc        >/dev/null 2>&1 || true
command -v patch      >/dev/null 2>&1 || NEED_PKGS+=(patch)
command -v curl       >/dev/null 2>&1 || NEED_PKGS+=(curl)

# Headers matching the running kernel. proxmox-default-headers tracks
# whatever kernel series is currently the default; if you're on an opt-in
# kernel series (e.g. 7.0 while 6.17 is still default) install
# proxmox-headers-<series> / pve-headers-<series> explicitly instead.
KVER="$(uname -r)"
if [ ! -d "/usr/src/linux-headers-${KVER}" ]; then
	NEED_PKGS+=(proxmox-default-headers)
fi

if [ "${#NEED_PKGS[@]}" -gt 0 ]; then
	echo "==> Installing: ${NEED_PKGS[*]}"
	apt-get update
	apt-get install -y "${NEED_PKGS[@]}"
fi

if [ ! -d "/usr/src/linux-headers-${KVER}" ]; then
	echo "No headers found for running kernel ${KVER}." >&2
	echo "If you're on an opt-in kernel series, install e.g.:" >&2
	echo "  apt install proxmox-headers-7.0" >&2
	exit 1
fi

echo "==> Staging DKMS module at ${DEST}"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$HERE/dkms.conf" "$DEST/"
cp "$HERE/pre-build.sh" "$DEST/"
chmod +x "$DEST/pre-build.sh"
cp -r "$HERE/patches" "$DEST/"

echo "==> Installing runtime files"
install -Dm755 "$HERE/usr-local-sbin/v620-cap-apply.sh" /usr/local/sbin/v620-cap-apply.sh
install -Dm644 "$HERE/etc-systemd-system/v620-powercap.service" /etc/systemd/system/v620-powercap.service
if [ ! -f /etc/default/v620-powertuning ]; then
	install -Dm644 "$HERE/etc-default/v620-powertuning" /etc/default/v620-powertuning
else
	echo "    /etc/default/v620-powertuning already exists, leaving it alone"
fi
install -Dm755 "$HERE/initramfs-tools/hooks/v620_powertuning" /usr/share/initramfs-tools/hooks/v620_powertuning
install -Dm755 "$HERE/initramfs-tools/scripts/init-premount/v620_powertuning" /usr/share/initramfs-tools/scripts/init-premount/v620_powertuning

echo "==> Registering with DKMS"
dkms remove "${PKG}/${VER}" --all >/dev/null 2>&1 || true
dkms add "${DEST}"
dkms build "${PKG}/${VER}" -k "${KVER}"
dkms install "${PKG}/${VER}" -k "${KVER}"

echo "==> Unload currently loaded Driver"
modprobe -r snd_hda_intel
modprobe -r radeon
modprobe -r amdgpu

echo "==> Reload recompiled Driver"
sleep 5
modprobe amdgpu
modprobe radeon
modprobe snd_hda_intel
sleep 5

echo "==> Enabling systemd unit"
systemctl daemon-reload
systemctl enable --now v620-powercap.service

sleep 5

systemctl restart v620-powercap.service

echo
echo "==> Done."
echo "Verify with:"
echo "  dmesg | grep 'V620 powerfix'"
echo "  cat /sys/class/hwmon/hwmon*/power1_cap_min"
echo "  cat /sys/class/hwmon/hwmon*/power1_cap"
echo
echo "Future kernel updates (proxmox-kernel-*) will trigger an automatic"
echo "DKMS rebuild via the kernel package's postinst hook (dkms autoinstall)."
