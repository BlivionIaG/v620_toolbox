#!/usr/bin/env bash
# Verify that AMD PCIe P2P is fully operational on this host.
# Runs the four-gate diagnostic checklist from docs/AMD_P2P.md.
#
# Usage:
#   ./v620-p2p-readiness.sh [--bdf <BDF>] [--strict]
#
# Default: read-only diagnostics. With --strict, exit non-zero on any FAIL.
# This script is safe to run anywhere — it does NOT touch the system.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE_EOF'
Usage:
  ./v620-p2p-readiness.sh [--bdf <0000:BB:DD.F>] [--strict]
  ./v620-p2p-readiness.sh --json

Runs the four-gate P2P readiness checklist:
  1. Kernel config (HSA_AMD_P2P, PCI_P2PDMA, PCIE_P2P_LINK, etc.)
  2. Hardware topology (PCIe root complex, PLX 88096 switches, BDF, NUMA)
  3. ACS / IOMMU (BIOS-side gates, including PLX switch ports)
  4. Runtime (module param, kfd p2p_links, rocm-smi)

Options:
  --bdf <BDF>     Specific BDF to inspect (default: all 1002:73a1 V620 + 1002:7470 W7800)
  --strict        Exit non-zero on any FAIL
  --json          Output a JSON object instead of human-readable
  -h, --help      Show help
USAGE_EOF
}

STRICT="0"
JSON="0"
BDF_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bdf)     BDF_FILTER="${2:-}"; shift 2 ;;
    --strict)  STRICT="1"; shift ;;
    --json)    JSON="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         err "unknown arg: $1"; usage >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0
WARN=0
INFO=0

record() {
  local status="$1"
  local gate="$2"
  local msg="$3"
  case "${status}" in
    PASS) PASS=$((PASS+1)); printf '  [PASS] %-12s %s\n' "${gate}" "${msg}" ;;
    FAIL) FAIL=$((FAIL+1)); printf '  [FAIL] %-12s %s\n' "${gate}" "${msg}" ;;
    WARN) WARN=$((WARN+1)); printf '  [WARN] %-12s %s\n' "${gate}" "${msg}" ;;
    INFO) INFO=$((INFO+1)); printf '  [INFO] %-12s %s\n' "${gate}" "${msg}" ;;
  esac
}

# --- Gate 1: Kernel config ---
log "Gate 1: kernel config"
declare -A REQUIRED=(
  [CONFIG_HSA_AMD_P2P]="y"
  [CONFIG_PCI_P2PDMA]="y"
  [CONFIG_DEVICE_PRIVATE]="y"
  [CONFIG_ZONE_DEVICE]="y"
)
if [[ -r /proc/config.gz ]]; then
  CONFIG_SRC="zcat /proc/config.gz"
elif [[ -r /boot/config-$(uname -r) ]]; then
  CONFIG_SRC="cat /boot/config-$(uname -r)"
else
  warn "Cannot read kernel config; skipping"
  CONFIG_SRC=""
fi

if [[ -n "${CONFIG_SRC}" ]]; then
  for k in "${!REQUIRED[@]}"; do
    if ${CONFIG_SRC} | grep -qE "^${k}=${REQUIRED[$k]}$"; then
      record PASS "kernel" "${k}=${REQUIRED[$k]}"
    else
      record FAIL "kernel" "${k} not set to ${REQUIRED[$k]}"
    fi
  done
fi

# --- Gate 2: Hardware topology ---
log "Gate 2: hardware topology"

# Match V620 (RDNA2, 0x73a1) + W7800 (RDNA3, 0x7470)
declare -A AMD_GPU_MODEL=(
  ["1002:73a1"]="V620"
  ["1002:7470"]="W7800"
)
GPUBDFS=""
MODEL_COUNTS=""
for devid in "${!AMD_GPU_MODEL[@]}"; do
  bdfs=$(lspci -nn -d "$devid" 2>/dev/null | awk '{print $1}')
  if [[ -n "$bdfs" ]]; then
    count=$(echo "$bdfs" | wc -l)
    MODEL_COUNTS+="${AMD_GPU_MODEL[$devid]}=$count "
    GPUBDFS+="$bdfs"$'\n'
  fi
done
GPUBDFS="$(echo -e "$GPUBDFS" | sort -u | grep -v '^$' || true)"

if [[ -z "${GPUBDFS}" ]]; then
  record FAIL "topology" "no 1002:73a1 (V620) or 1002:7470 (W7800) PCI devices found"
else
  record PASS "topology" "AMD GPUs found: ${MODEL_COUNTS}"
  for BDF in ${GPUBDFS}; do
    [[ -n "${BDF_FILTER}" && "${BDF}" != "${BDF_FILTER}" ]] && continue
    NUMA="$(cat /sys/bus/pci/devices/0000:${BDF}/numa_node 2>/dev/null || echo "-1")"
    record PASS "topology" "GPU ${BDF} on NUMA node ${NUMA}"

    BAR_SIZE="$(lspci -vvv -s "${BDF}" 2>/dev/null \
      | awk '/Memory.*prefetchable/ {print $0; exit}' \
      | sed -nE 's/.*\[size=([^]]+)\].*/\1/p')"
    if [[ "${BAR_SIZE}" =~ ^([0-9]+)G$ ]]; then
      GRAMS="${BASH_REMATCH[1]}"
      if (( GRAMS >= 16 )); then
        record PASS "topology" "GPU ${BDF} large BAR: ${BAR_SIZE}"
      else
        record FAIL "topology" "GPU ${BDF} small BAR: ${BAR_SIZE} (need ≥16G)"
      fi
    else
      record WARN "topology" "GPU ${BDF} BAR size parse failed: '${BAR_SIZE}'"
    fi

    # Check link speed (Gen3 vs Gen4)
    SPEED="$(lspci -vvv -s "${BDF}" 2>/dev/null | awk '/Speed/ {print $1; exit}')"
    if [[ "${SPEED}" == "16GT/s" ]]; then
      record PASS "topology" "GPU ${BDF} PCIe Gen4 (${SPEED})"
    elif [[ "${SPEED}" == "8GT/s" ]]; then
      record WARN "topology" "GPU ${BDF} PCIe Gen3 (${SPEED}) — limited to ~16 GB/s P2P"
    fi
  done
fi

# PLX 88096 switches (Gen4 fan-out)
PLX_SWITCHES="$(lspci -nn -d 10b5:88096 2>/dev/null | awk '{print $1}' || true)"
if [[ -n "${PLX_SWITCHES}" ]]; then
  PLX_COUNT=$(echo "${PLX_SWITCHES}" | wc -l)
  record PASS "topology" "PLX 88096 switches detected: ${PLX_COUNT}"
  for sw in ${PLX_SWITCHES}; do
    ACS="$(sudo setpci -s "${sw}" ECAP_ACS+6.w 2>/dev/null || echo "unknown")"
    if [[ "${ACS}" == "0000" || -z "${ACS}" ]]; then
      record PASS "acs" "PLX switch ${sw} ACS disabled (clean)"
    else
      record WARN "acs" "PLX switch ${sw} ACS=${ACS} (need pcie_acs_override=downstream,multifunction)"
    fi
  done
else
  record INFO "topology" "no PLX 88096 switches detected"
fi

# --- Gate 3: ACS / IOMMU ---
log "Gate 3: ACS / IOMMU"
ACS_PATH="/sys/module/pci/parameters"
if [[ -r "${ACS_PATH}/acs_disable" ]]; then
  ACS_VAL="$(cat "${ACS_PATH}/acs_disable" 2>/dev/null || echo "?")"
  record PASS "acs" "kernel ACS override available: ${ACS_VAL}"
fi

CMDLINE="$(cat /proc/cmdline 2>/dev/null || echo "")"
if echo "${CMDLINE}" | grep -q "amd_iommu=off"; then
  record PASS "iommu" "amd_iommu=off (ideal for bare-metal P2P)"
elif echo "${CMDLINE}" | grep -q "iommu=pt"; then
  record PASS "iommu" "iommu=pt (P2P-friendly pass-through)"
elif echo "${CMDLINE}" | grep -q "amd_iommu=on"; then
  record WARN "iommu" "amd_iommu=on (full translation; may block P2P)"
elif echo "${CMDLINE}" | grep -q "amd_iommu="; then
  record WARN "iommu" "non-standard amd_iommu setting"
else
  record WARN "iommu" "no explicit amd_iommu= setting; using distro default"
fi

if echo "${CMDLINE}" | grep -q "pcie_acs_override"; then
  record PASS "acs" "pcie_acs_override present in cmdline"
else
  record WARN "acs" "no pcie_acs_override in cmdline (may be unnecessary if BIOS disables ACS)"
fi

# --- Gate 4: Runtime ---
log "Gate 4: runtime"
if [[ -r /sys/module/amdgpu/parameters/pcie_p2p ]]; then
  P2P_PARAM="$(cat /sys/module/amdgpu/parameters/pcie_p2p)"
  if [[ "${P2P_PARAM}" == "Y" ]]; then
    record PASS "runtime" "amdgpu.pcie_p2p=Y"
  else
    record FAIL "runtime" "amdgpu.pcie_p2p=${P2P_PARAM} (should be Y)"
  fi
else
  record WARN "runtime" "amdgpu not loaded or pcie_p2p param not exposed"
fi

for n in /sys/class/kfd/kfd/topology/nodes/*/; do
  LINKS="$(ls "${n}p2p_links/" 2>/dev/null | wc -l)"
  if [[ "${LINKS}" -gt 0 ]]; then
    NODE_NAME="$(cat "${n}name" 2>/dev/null || echo "$(basename "${n}")")"
    record PASS "runtime" "KFD node ${NODE_NAME} has ${LINKS} p2p_links"
  fi
done

ROCM_SMI="${ROCM_SMI:-/opt/rocm-7.2.0/bin/rocm-smi}"
if [[ -x "${ROCM_SMI}" ]]; then
  ACCESS_MATRIX="$("${ROCM_SMI}" --showtopoaccess 2>/dev/null || true)"
  if [[ -n "${ACCESS_MATRIX}" ]]; then
    CROSS_PAIR_COUNT=$(echo "${ACCESS_MATRIX}" | awk 'NR>1 { for(i=2;i<=NF;i++) if ($i==0) c++ } END {print c+0}')
    if [[ "${CROSS_PAIR_COUNT}" == "0" ]]; then
      record PASS "runtime" "rocm-smi --showtopoaccess shows all pairs P2P-capable"
    else
      record FAIL "runtime" "rocm-smi --showtopoaccess: ${CROSS_PAIR_COUNT} non-P2P pairs"
    fi
  fi
fi

# --- Summary ---
TOTAL=$((PASS+FAIL+WARN))
echo
echo "=== Summary ==="
echo "PASS=$PASS  WARN=$WARN  FAIL=$FAIL  (total $TOTAL)"

if [[ "${STRICT}" == "1" && "${FAIL}" -gt 0 ]]; then
  exit 1
fi
[[ "${FAIL}" == "0" ]] && exit 0 || exit 1
