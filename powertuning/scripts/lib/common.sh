#!/usr/bin/env bash
# Shared helpers for the powertuning scripts.
# Source this from each script:  source "$(dirname "$0")/lib/common.sh"

set -euo pipefail

# Project root (one level above scripts/)
POWERTUNING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCHES_DIR="${POWERTUNING_ROOT}/patches"
SCRIPTS_DIR="${POWERTUNING_ROOT}/scripts"
DOCS_DIR="${POWERTUNING_ROOT}/docs"

# Default per-card identity (matches the guide's match string)
DEFAULT_VENDOR="0x1002"
DEFAULT_DEVICE="0x73a1"
DEFAULT_SUBSYSTEM_VENDOR="0x1002"
DEFAULT_SUBSYSTEM_DEVICE="0x0e34"
DEFAULT_REVISION="0x00"

# Active targets on : BDFs we are NOT touching
# (bus 0x83 hosts the active job; guard against accidental patching)
DEFAULT_ACTIVE_BDFS=("0000:83:00.0")

# log helpers
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
err()  { log "ERROR: $*" >&2; }
warn() { log "WARN: $*" >&2; }
ok()   { log "OK: $*"; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "missing required command: $1"
    return 2
  fi
}

require_path() {
  if [[ ! -e "$1" ]]; then
    err "missing required path: $1"
    return 2
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    err "this step needs root and sudo is not available"
    return 2
  fi
}

# Read /sys/bus/pci/devices/<BDF>/{vendor,device,subsystem_vendor,subsystem_device,revision}
# Returns 0 and prints "<vendor> <device> <subv> <subd> <rev>" on success.
pci_identity() {
  local bdf="$1"
  local dev="/sys/bus/pci/devices/${bdf}"
  if [[ ! -d "${dev}" ]]; then
    return 2
  fi
  printf '%s %s %s %s %s\n' \
    "$(<"${dev}/vendor")" \
    "$(<"${dev}/device")" \
    "$(<"${dev}/subsystem_vendor")" \
    "$(<"${dev}/subsystem_device")" \
    "$(<"${dev}/revision")"
}

# Print "V<D> SD<S> r<R>" in the patch's match-string format
pci_identity_match_string() {
  local bdf="$1"
  local id
  if ! id="$(pci_identity "${bdf}")"; then
    return 2
  fi
  read -r v d sv sd r <<<"${id}"
  printf '%s:%s:%s:%s rev %s\n' "${v}" "${d}" "${sv}" "${sd}" "${r}"
}

# Active-job detection: returns the BDFs currently drawing >150 W
# Usage: mapfile -t ACTIVE < <(active_bdfs)
active_bdfs() {
  local rocm_smi="${ROCM_SMI:-/opt/rocm-7.2.0/bin/rocm-smi}"
  if [[ ! -x "${rocm_smi}" ]]; then
    err "rocm-smi not found at ${rocm_smi}"
    return 2
  fi
  "${rocm_smi}" --showpower 2>/dev/null \
    | awk '
      /GPU\[[0-9]+\].*: Average Graphics Package Power \(W\):/ {
        match($0, /GPU\[([0-9]+)\]/, g);
        for (i=1; i<=NF; i++) {
          if ($i ~ /^[0-9]+$/ && $i+0 > 150) {
            print g[1];
            break;
          }
        }
      }
    '
}

# Map a rocm-smi GPU index to a PCI BDF
gpu_index_to_bdf() {
  local idx="$1"
  local rocm_smi="${ROCM_SMI:-/opt/rocm-7.2.0/bin/rocm-smi}"
  if [[ ! -x "${rocm_smi}" ]]; then
    return 2
  fi
  "${rocm_smi}" --showbus 2>/dev/null \
    | awk -v idx="${idx}" '
      $1 == "GPU["idx"]" {
        for (i=1; i<=NF; i++) {
          if ($i ~ /^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]+$/) {
            print $i;
            exit
          }
        }
      }
    '
}

# Run as root via sudo unless already root
run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Print the active patch file (default canonical)
active_patch_file() {
  printf '%s\n' "${PATCHES_DIR}/v620-powercap-min-120W.patch"
}
