#!/usr/bin/env bash
# verify-p2p.sh — full PASS/FAIL summary for the pcie_p2p stack.
#
# Runs checks 1-8 from README.md §"Verify" in sequence and prints a
# PASS/FAIL tally. Exits with the FAIL count.
#
# Respects these env vars (see README.md §"Prerequisites" → "Path overrides" for
# the defaults — override them in the calling shell if your layout
# differs):
#   $BUILD_DIR      kernel build dir
#   $ROCM_HOME      ROCm 7.14 install root (default /opt/rocm/core-7.14)
#   $XDG_CACHE_HOME cache root
set +e

# Defaults — override via env var before calling if needed
ROCM_HOME=${ROCM_HOME:-/opt/rocm/core-7.14}

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

echo "=== 1. kernel"
check "uname has .p2p buildid" "p2p" "$(uname -r)"
check "dnf exclude" "kernel kernel-core kernel-modules" "$(grep ^exclude /etc/dnf/dnf.conf 2>/dev/null)"

echo "=== 2. kernel-config"
DELTA=$(grep -cE '^CONFIG_(HSA_AMD_P2P|PCI_P2PDMA)=' /boot/config-$(uname -r))
check "HSA_P2P + PCI_P2PDMA both =y" "2" "$DELTA"

echo "=== 3. hardware"
# Pre-gfx1030: device IDs 0x6XXX (gfx1030+ starts at 0x7300)
PRE_GFX10X=$(lspci -nn | grep -cE '1002:6[0-9a-f]{3}')
check "no pre-gfx1030 ASIC" "0" "$PRE_GFX10X"
V620S=$(lspci -nn | grep -c '1002:73a1:1002:0e34')
if [ "$V620S" -ge 2 ]; then
  echo "  PASS  ≥2 V620 ($V620S)"
  PASS=$((PASS+1))
else
  echo "  FAIL  only $V620S V620"
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
  echo "  PASS  ≥5 KFD nodes ($NODES)"
  PASS=$((PASS+1))
else
  echo "  FAIL  only $NODES KFD nodes"
  FAIL=$((FAIL+1))
fi

echo "=== 6. amd-smi runtime P2P"
AMD=$(LD_LIBRARY_PATH=$ROCM_HOME/lib $ROCM_HOME/bin/amd-smi topology 2>&1)
DISABLED=$(echo "$AMD" | grep -c DISABLED)
if [ "$DISABLED" -eq 0 ]; then
  echo "  PASS  no DISABLED in amd-smi access table"
  PASS=$((PASS+1))
else
  echo "  FAIL  $DISABLED DISABLED cells"
  FAIL=$((FAIL+1))
fi

echo "=== 7. amdgpu module params"
PCIE_P2P=$(cat /sys/module/amdgpu/parameters/pcie_p2p 2>/dev/null)
check "pcie_p2p=Y" "Y" "$PCIE_P2P"

echo "=== 8. HSA agents"
ROCM_OUT=$(LD_LIBRARY_PATH=$ROCM_HOME/lib $ROCM_HOME/bin/rocminfo 2>&1)
GPUCOUNT=$(echo "$ROCM_OUT" | grep -c 'Device Type:             GPU')
if [ "$GPUCOUNT" -eq "$V620S" ]; then
  echo "  PASS  $GPUCOUNT GPU agents"
  PASS=$((PASS+1))
else
  echo "  FAIL  expected $V620S GPU agents, got $GPUCOUNT"
  FAIL=$((FAIL+1))
fi

echo
echo "=== summary: $PASS PASS, $FAIL FAIL"
exit $FAIL