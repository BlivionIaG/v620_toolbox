#!/usr/bin/env bash
#
# v620-p2p-preflight.sh
#
# Determines which path this host needs for PCIe P2P between V620 cards:
#
#   LIGHT PATH  — the running kernel already has CONFIG_HSA_AMD_P2P=y and
#                 CONFIG_PCI_P2PDMA=y compiled in (true for stock Proxmox VE
#                 9.x kernels, which track Ubuntu >=24.04 where these are on
#                 by default). Nothing to rebuild; just enable the amdgpu
#                 module param and confirm hardware prerequisites.
#
#   HEAVY PATH  — those configs are NOT compiled into vmlinuz on this host
#                 (e.g. a hand-rolled or unusually stripped-down kernel).
#                 These are core-kernel bool Kconfig symbols, not modules —
#                 DKMS cannot add them after the fact. A custom-built
#                 proxmox-kernel package with a config delta is required,
#                 the same way the Fedora guide rebuilds the entire kernel
#                 RPM. See the README's "Heavy path" section.
#
# Also runs the hardware preconditions from the upstream guide regardless
# of path (pre-gfx1030 ASIC removed, >=2 V620 present).

set -uo pipefail

CONF="/boot/config-$(uname -r)"
FAIL=0

echo "== v620 PCIe P2P preflight =="
echo "Kernel: $(uname -r)"
echo

if [ ! -r "$CONF" ]; then
	echo "WARN: $CONF not readable (need linux-image-*-dbg or the running"
	echo "      kernel's own /boot/config-* — usually present on Proxmox)."
	echo "      Falling back to /proc/config.gz if available."
	CONF="/tmp/.v620-runtime-config"
	if [ -r /proc/config.gz ]; then
		zcat /proc/config.gz > "$CONF"
	else
		echo "FAIL: cannot read kernel config from anywhere; cannot determine path."
		exit 2
	fi
fi

echo "-- Kernel config --"
HSA_P2P="$(grep -E '^CONFIG_HSA_AMD_P2P=' "$CONF" || true)"
PCI_P2PDMA="$(grep -E '^CONFIG_PCI_P2PDMA=' "$CONF" || true)"
DMABUF_MN="$(grep -E '^CONFIG_DMABUF_MOVE_NOTIFY=' "$CONF" || true)"

echo "  CONFIG_HSA_AMD_P2P:        ${HSA_P2P:-<not set>}"
echo "  CONFIG_PCI_P2PDMA:         ${PCI_P2PDMA:-<not set>}"
echo "  CONFIG_DMABUF_MOVE_NOTIFY: ${DMABUF_MN:-<not set / removed upstream on newer kernels, benign>}"
echo

if [ "$HSA_P2P" = "CONFIG_HSA_AMD_P2P=y" ] && [ "$PCI_P2PDMA" = "CONFIG_PCI_P2PDMA=y" ]; then
	echo "RESULT: LIGHT PATH — kernel already has what's needed."
	PATH_RESULT=light
else
	echo "RESULT: HEAVY PATH — this kernel lacks CONFIG_HSA_AMD_P2P and/or"
	echo "        CONFIG_PCI_P2PDMA. A custom-built proxmox-kernel package is"
	echo "        required; see README.md 'Heavy path'. Stopping here — the"
	echo "        rest of this installer only handles the light path."
	PATH_RESULT=heavy
	FAIL=1
fi

echo
echo "-- Hardware preconditions --"

PRE_GFX10X="$(lspci -nn 2>/dev/null | grep -cE '1002:6[0-9a-f]{3}')"
if [ "$PRE_GFX10X" -eq 0 ]; then
	echo "  PASS: no pre-gfx1030 AMD ASIC present"
else
	echo "  FAIL: $PRE_GFX10X pre-gfx1030 AMD GPU(s) present — ROCm 7.x KFD"
	echo "        registration fails with any of these installed alongside"
	echo "        the V620s. Remove them before continuing."
	FAIL=1
fi

# COUNT="$(lspci -nn 2>/dev/null | grep -c '1002:73a1:1002:0e34')"
for i in $(seq 1 30); do            # wait up to 60 s for amdgpu hwmon
	NUM_V620S=0
	for h in /sys/class/hwmon/hwmon*; do
		[ -f "$h/name" ] && grep -qi amdgpu "$h/name" || continue
		d="$(readlink -f "$h/device")"
		[ "$(cat "$d/device" 2>/dev/null)"           = "0x73a1" ] || continue
		[ "$(cat "$d/subsystem_device" 2>/dev/null)" = "0x0e34" ] || continue
		NUM_V620S=$((NUM_V620S + 1))
	done
	[ ${NUM_V620S} -eq 1 ] && { exit 0; }
	sleep 2
done

if [ "${NUM_V620S}" -ge 2 ]; then
	echo "  PASS: ${NUM_V620S} V620 present"
elif [ "${NUM_V620S}" -eq 1 ]; then
	echo "  WARN: only 1 V620 present — P2P needs >=2 to do anything."
else
	echo "  FAIL: no V620 (subsystem 1002:0e34) found via lspci"
	FAIL=1
fi

echo
if [ "$PATH_RESULT" = "light" ] && [ "$FAIL" -eq 0 ]; then
	echo "Preflight OK — run install-p2p.sh to finish enabling P2P."
	exit 0
else
	echo "Preflight found issues — see above."
	exit 1
fi
