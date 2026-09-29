#!/usr/bin/env bash
#
# heavy-kernel-build.sh — build a custom proxmox-kernel .deb with
# CONFIG_HSA_AMD_P2P=y, CONFIG_PCI_P2PDMA=y, CONFIG_DMABUF_MOVE_NOTIFY=y
# added, for hosts where v620-p2p-preflight.sh reported the HEAVY PATH
# (i.e. the stock kernel doesn't already have these compiled in).
#
# This is the Proxmox equivalent of the upstream guide's
# `v620-kernel-bake.sh` + Fedora SRPM rebuild — but using Proxmox's own
# kernel packaging (git.proxmox.com/pve-kernel), which is a Debian
# source package with a git submodule for the actual kernel tree, not
# an RPM spec. Confirmed against pve-kernel's own README and the
# Proxmox forum's kernel-build tutorial.
#
# IMPORTANT — read before running:
#   - This is a multi-hour build (kernel source is large; expect similar
#     build times to the Fedora guide's ~10-20 min per-driver bake, but
#     for a FULL kernel this is more like 1-3+ hours depending on cores).
#   - Needs ~15-20 GB free disk and 16+ GB RAM, similar to the upstream
#     guide's sizing.
#   - This only patches the *config*, not amdgpu source — the
#     v620-powercap patch is applied separately by the v620-powertuning
#     DKMS module (../proxmox-ve-powertuning/install.sh), which still works fine against a
#     custom-built kernel as long as its headers package is also
#     installed/built (dpkg-buildpackage produces matching
#     proxmox-headers-<ver> .debs alongside the kernel .deb).
#   - Proxmox kernel builds occasionally hit `abicheck` failures on a
#     first build (per Proxmox forum reports) — if so, check
#     `debian/rules` around the `abicheck` target; this is a known rough
#     edge of building pve-kernel out-of-band from Proxmox's own CI.
#   - You are now maintaining your own kernel branch. Future
#     proxmox-kernel-* updates from Proxmox's repos will NOT carry your
#     config delta — you'll need to re-run this against the new
#     upstream tag and reinstall, then re-run ../proxmox-ve-powertuning/install.sh's dkms
#     build against the new kernel.
#
# Usage:
#   sudo ./heavy-kernel-build.sh [branch-or-tag]
# With no argument, builds against the currently checked-out default
# branch of git.proxmox.com/pve-kernel.git (i.e. whatever matches your
# running Proxmox VE 9.x series — check with `apt-cache policy
# proxmox-kernel-6.17` or similar before choosing a branch/tag).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root." >&2
	exit 1
fi

BRANCH="${1:-}"
BUILD_DIR="${BUILD_DIR:-/root/build}/pve-kernel-v620-p2p"

echo "==> Installing build dependencies"
apt-get update
apt-get install -y devscripts equivs git build-essential

mkdir -p "$(dirname "$BUILD_DIR")"
if [ ! -d "$BUILD_DIR" ]; then
	echo "==> Cloning git.proxmox.com/pve-kernel.git"
	git clone git://git.proxmox.com/git/pve-kernel.git "$BUILD_DIR"
fi
cd "$BUILD_DIR"

if [ -n "$BRANCH" ]; then
	echo "==> Checking out ${BRANCH}"
	git checkout "$BRANCH"
fi

echo "==> Fetching kernel source submodule (this is the big download)"
git submodule update --init

echo "==> Installing package build-dependencies from debian/control.in"
mk-build-deps --install --tool="apt-get -y" debian/control.in || true

echo "==> Creating build-dir from templates"
make build-dir-fresh

echo "==> Adding config delta: CONFIG_HSA_AMD_P2P, CONFIG_PCI_P2PDMA, CONFIG_DMABUF_MOVE_NOTIFY"
CONFIG_RULES="debian/rules.d/$(ls debian/rules.d | grep -m1 'config\|Config' || true)"
echo
echo "!! MANUAL STEP REQUIRED !!"
echo "Proxmox applies config deltas via -e/-d flags to a config-modification"
echo "target inside debian/rules (see PVE_CONFIG_OPTS in the pve-kernel README"
echo "and forum thread https://forum.proxmox.com/threads/building-the-pve-kernel-on-proxmox-ve-6-x.76137/"
echo "for the exact syntax, which has moved between Proxmox releases)."
echo
echo "Open debian/rules in ${BUILD_DIR} now, find the config-options list, and add:"
echo "  -e CONFIG_HSA_AMD_P2P -e CONFIG_PCI_P2PDMA -e CONFIG_DMABUF_MOVE_NOTIFY"
echo
echo "This step is intentionally not automated here: the exact target/variable"
echo "name has changed across Proxmox VE major versions, and blindly sed-ing"
echo "debian/rules risks silently producing a kernel that doesn't build or"
echo "doesn't actually carry the config change. Confirm the syntax against the"
echo "README in this checkout (${BUILD_DIR}/README) for your checked-out branch"
echo "before continuing."
echo
read -r -p "Press Enter once you've added the config delta to debian/rules... "

echo "==> Building (this will take a while)"
cd build
dpkg-buildpackage -b -uc -us --no-pre-clean

echo
echo "==> Build finished. Resulting .deb files are in $(dirname "$BUILD_DIR")/"
echo "Install the kernel + matching headers packages, e.g.:"
echo "  dpkg -i proxmox-kernel-*.deb proxmox-headers-*.deb"
echo "Then set it as default (proxmox-boot-tool refresh handles this on"
echo "Proxmox's systemd-boot/grub setups) and reboot."
echo
echo "After reboot, re-run:"
echo "  ../scripts/v620-p2p-preflight.sh"
echo "to confirm LIGHT PATH now applies, then ./install-p2p.sh."
