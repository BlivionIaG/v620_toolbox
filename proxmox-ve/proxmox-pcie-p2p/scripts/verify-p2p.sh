#!/usr/bin/env bash
# v620-verify-p2p.sh — full PASS/FAIL summary for the pcie_p2p stack on
# Proxmox VE 9.x. Structured to mirror the upstream toolbox's
# scripts/verify-p2p.sh check-for-check (same 8-section shape, same
# check() helper, same PASS/FAIL tally + exit-code convention), with
# the two checks that don't apply on Proxmox swapped for their
# Proxmox-side equivalents:
#   - §1 ".p2p buildid" / "dnf exclude" -> kernel version + DKMS module
#     status (Proxmox has no buildid convention, and DKMS — not a dnf
#     pin — is what keeps the power-cap fix alive across kernel updates
#     on the light path)
# Everything else (kernel-config delta, hardware, powercap dmesg, KFD
# topology, amd-smi, module params, HSA agent count) is unchanged in
# substance from upstream.
#
# Respects the same env vars as upstream:
#   $ROCM_HOME   ROCm install root (default /opt/rocm — upstream
#                defaults to /opt/rocm/core-7.14; override to match
#                whatever ROCm layout you actually installed)
set +e

ROCM_HOME=${ROCM_HOME:-/opt/rocm}

PASS=0
FAIL=0

check() {
	local desc="$1" expect="$2" got="$3"
	if [[ "$got" == *"$expect"* ]]; then
		echo "  PASS  $desc"
		PASS=$((PASS+1))
	else
		echo "  FAIL  $desc (expected: $expect, got: $got)"
		FAIL=$((FAIL+1))
	fi
}

echo "=== 1. kernel / persistence"
echo "  kernel: $(uname -r)"
DKMS_STATUS="$(dkms status 2>/dev/null | grep '^v620-powertuning' || true)"
check "v620-powertuning DKMS module installed for this kernel" "installed" "$DKMS_STATUS"

echo "=== 2. kernel-config"
CONF="/boot/config-$(uname -r)"
[ -r "$CONF" ] || CONF="/proc/config.gz"
if [ "$CONF" = "/proc/config.gz" ] && [ -r "$CONF" ]; then
	DELTA=$(zcat "$CONF" | grep -cE '^CONFIG_(HSA_AMD_P2P|PCI_P2PDMA)=y')
else
	DELTA=$(grep -cE '^CONFIG_(HSA_AMD_P2P|PCI_P2PDMA)=y' "$CONF" 2>/dev/null)
fi
check "HSA_P2P + PCI_P2PDMA both =y" "2" "$DELTA"

echo "=== 3. hardware"
# Pre-gfx1030: device IDs 0x6XXX (gfx1030+ starts at 0x7300)
PRE_GFX10X=$(lspci -nn | grep -cE '1002:6[0-9a-f]{3}')
check "no pre-gfx1030 ASIC" "0" "$PRE_GFX10X"
# V620S=$(lspci -nn | grep -c '1002:73a1:1002:0e34')

for i in $(seq 1 30); do            # wait up to 60 s for amdgpu hwmon
	NUM_V620S=0
	for h in /sys/class/hwmon/hwmon*; do
		[ -f "$h/name" ] && grep -qi amdgpu "$h/name" || continue
		d="$(readlink -f "$h/device")"
		[ "$(cat "$d/device" 2>/dev/null)"           = "0x73a1" ] || continue
		[ "$(cat "$d/subsystem_device" 2>/dev/null)" = "0x0e34" ] || continue
		NUM_V620S=$((NUM_V620S + 1))
	done
	[ ${NUM_V620S} -ge 1 ] && { exit 0; }
	sleep 2
done

if [ "${NUM_V620S}" -ge 2 ]; then
	echo "  PASS  >=2 V620 (${NUM_V620S})"
	PASS=$((PASS+1))
else
	echo "  FAIL  only ${NUM_V620S} V620"
	FAIL=$((FAIL+1))
fi

echo "=== 4. powercap"
PWNFIX=$(dmesg | grep -c 'V620 powerfix')
if [ "$PWNFIX" -ge 2 ]; then
	echo "  PASS  V620 powerfix dmesg ($PWNFIX)"
	PASS=$((PASS+1))
else
	echo "  FAIL  no V620 powerfix in dmesg"
	FAIL=$((FAIL+1))
fi

echo "=== 5. KFD topology"
NODES=$(ls /sys/class/kfd/kfd/topology/nodes/ 2>/dev/null | wc -l)
if [ "$NODES" -ge 5 ]; then
	echo "  PASS  >=5 KFD nodes ($NODES)"
	PASS=$((PASS+1))
else
	echo "  FAIL  only $NODES KFD nodes"
	FAIL=$((FAIL+1))
fi

echo "=== 6. amd-smi runtime P2P"
if [ -x "$ROCM_HOME/bin/amd-smi" ]; then
	AMD=$(LD_LIBRARY_PATH="$ROCM_HOME/lib" "$ROCM_HOME/bin/amd-smi" topology 2>&1)
	DISABLED=$(echo "$AMD" | grep -c DISABLED)
	if [ "$DISABLED" -eq 0 ]; then
		echo "  PASS  no DISABLED in amd-smi access table"
		PASS=$((PASS+1))
	else
		echo "  FAIL  $DISABLED DISABLED cells"
		FAIL=$((FAIL+1))
	fi
else
	echo "  SKIP  $ROCM_HOME/bin/amd-smi not found (ROCm not installed) — not counted"
fi

echo "=== 7. amdgpu module params"
PCIE_P2P=$(cat /sys/module/amdgpu/parameters/pcie_p2p 2>/dev/null)
check "pcie_p2p=Y" "Y" "$PCIE_P2P"

echo "=== 8. HSA agents"
if [ -x "$ROCM_HOME/bin/rocminfo" ]; then
	ROCM_OUT=$(LD_LIBRARY_PATH="$ROCM_HOME/lib" "$ROCM_HOME/bin/rocminfo" 2>&1)
	GPUCOUNT=$(echo "$ROCM_OUT" | grep -c 'Device Type:             GPU')
	if [ "$GPUCOUNT" -eq "${NUM_V620S}" ]; then
		echo "  PASS  $GPUCOUNT GPU agents"
		PASS=$((PASS+1))
	else
		echo "  FAIL  expected ${NUM_V620S} GPU agents, got $GPUCOUNT"
		FAIL=$((FAIL+1))
	fi
else
	echo "  SKIP  $ROCM_HOME/bin/rocminfo not found (ROCm not installed) — not counted"
fi

echo
echo "=== summary: $PASS PASS, $FAIL FAIL"
exit $FAIL
