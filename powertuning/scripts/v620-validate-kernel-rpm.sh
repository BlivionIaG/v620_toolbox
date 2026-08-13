#!/usr/bin/env bash
# Validate a built kernel RPM contains both the P2P config and the V620 powerfix.
#
# Usage:
#   ./v620-validate-kernel-rpm.sh <path-to-kernel-core-rpm>
#   ./v620-validate-kernel-rpm.sh --release <running-or-installed-release>
#
# Default: validates the running kernel.
#
# Checks:
#   1. /lib/modules/<rel>/config has all P2P config lines (HSA_AMD, PCI_P2PDMA, etc.)
#   2. /lib/modules/<rel>/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko contains
#      the V620 powerfix marker string
#
# Exits 0 if both checks pass, 1 if either fails, 2 on error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE_EOF'
Usage:
  ./v620-validate-kernel-rpm.sh <path-to-kernel-core-rpm>
  ./v620-validate-kernel-rpm.sh --release <release>
  ./v620-validate-kernel-rpm.sh --running

By default, validates the running kernel.

Options:
  --rpm <path>        Validate the given kernel-core RPM file
  --release <rel>     Validate the installed kernel at /lib/modules/<rel>
  --running           Validate the running kernel (default)
  -h, --help          Show help
USAGE_EOF
}

REQUIRED_CONFIG=(
  "CONFIG_HSA_AMD=y"
  "CONFIG_HSA_AMD_SVM=y"
  "CONFIG_HSA_AMD_P2P=y"
  "CONFIG_PCI_P2PDMA=y"
  "CONFIG_DMABUF_MOVE_NOTIFY=y"
  "CONFIG_DEVICE_PRIVATE=y"
  "CONFIG_ZONE_DEVICE=y"
)
REQUIRED_MARKER="V620 powerfix: allowing PPT limit down to"

MODE="running"
RPM_PATH=""
RELEASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpm)      RPM_PATH="${2:-}"; shift 2 ;;
    --release)  MODE="release"; RELEASE="${2:-}"; shift 2 ;;
    --running)  MODE="running"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          err "unknown arg: $1"; usage >&2; exit 2 ;;
  esac
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

case "${MODE}" in
  running)
    RELEASE="$(uname -r)"
    log "Validating running kernel: ${RELEASE}"
    CONFIG="/lib/modules/${RELEASE}/config"
    KO="/lib/modules/${RELEASE}/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
    ;;
  release)
    log "Validating installed kernel: ${RELEASE}"
    CONFIG="/lib/modules/${RELEASE}/config"
    KO="/lib/modules/${RELEASE}/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
    ;;
  *)
    err "Unknown mode: ${MODE}"
    exit 2
    ;;
esac

if [[ -n "${RPM_PATH}" ]]; then
  log "Extracting from RPM: ${RPM_PATH}"
  require_cmd rpm2cpio
  require_cmd cpio
  pushd "${WORKDIR}" >/dev/null
  rpm2cpio "${RPM_PATH}" | cpio -idmu --quiet
  popd >/dev/null

  # Fedora kernel splits /lib/modules/<rel>/config into kernel-core
  # and amdgpu.ko into kernel-modules. If the config is missing or
  # amdgpu.ko is missing, look for a sibling kernel-modules RPM and
  # extract it too.
  FOUND_CONFIG="$(find "${WORKDIR}/lib/modules" -type f -name config | head -n 1 || true)"
  FOUND_KO="$(find "${WORKDIR}/lib/modules" -type f \( -name amdgpu.ko -o -name 'amdgpu.ko.xz' \) | head -n 1 || true)"

  if [[ -z "${FOUND_CONFIG}" || -z "${FOUND_KO}" ]]; then
    RPM_DIR="$(dirname "${RPM_PATH}")"
    RPM_BASE="$(basename "${RPM_PATH}")"
    if [[ "${RPM_BASE}" == kernel-core-*.rpm ]]; then
      MODULES_RPM="${RPM_DIR}/kernel-modules${RPM_BASE#kernel-core}"
      if [[ -f "${MODULES_RPM}" ]]; then
        log "Also extracting: ${MODULES_RPM}"
        pushd "${WORKDIR}" >/dev/null
        rpm2cpio "${MODULES_RPM}" | cpio -idmu --quiet
        popd >/dev/null
        FOUND_CONFIG="$(find "${WORKDIR}/lib/modules" -type f -name config | head -n 1 || true)"
        FOUND_KO="$(find "${WORKDIR}/lib/modules" -type f \( -name amdgpu.ko -o -name 'amdgpu.ko.xz' \) | head -n 1 || true)"
      fi
    fi
  fi

  if [[ -z "${FOUND_CONFIG}" ]]; then
    err "Could not find config in ${RPM_PATH} (or sibling kernel-modules RPM)"
    exit 2
  fi
  CONFIG="${FOUND_CONFIG}"
  RELEASE="$(basename "$(dirname "${CONFIG}")")"

  if [[ -z "${FOUND_KO}" ]]; then
    err "Could not find amdgpu.ko in ${RPM_PATH} (or sibling kernel-modules RPM)"
    exit 2
  fi
  # Fedora ships kernel modules as .ko.xz; decompress to a temp file for grep.
  if [[ "${FOUND_KO}" == *.xz ]]; then
    DECOMPRESSED="${WORKDIR}/amdgpu.decompressed.ko"
    xz -dc "${FOUND_KO}" > "${DECOMPRESSED}"
    KO="${DECOMPRESSED}"
    log "Decompressed: ${FOUND_KO##*/} -> amdgpu.decompressed.ko"
  else
    KO="${FOUND_KO}"
  fi
fi

if [[ ! -f "${CONFIG}" ]]; then
  err "Config not found: ${CONFIG}"
  exit 2
fi
if [[ ! -f "${KO}" ]]; then
  err "amdgpu.ko not found: ${KO}"
  exit 2
fi

PASS=1

log "Check 1: P2P config lines in ${CONFIG}"
for required in "${REQUIRED_CONFIG[@]}"; do
  if grep -qF "${required}" "${CONFIG}"; then
    ok "  ${required}"
  else
    err "  MISSING: ${required}"
    PASS=0
  fi
done

log "Check 2: V620 powerfix marker in ${KO}"
if LC_ALL=C grep -aF "${REQUIRED_MARKER}" "${KO}" >/dev/null; then
  ok "  marker present"
else
  err "  marker NOT FOUND"
  PASS=0
fi

if [[ "${PASS}" == "1" ]]; then
  ok "All checks passed for release ${RELEASE}"
  exit 0
else
  err "Some checks failed"
  exit 1
fi
