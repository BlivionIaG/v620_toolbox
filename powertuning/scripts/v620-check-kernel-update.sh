#!/usr/bin/env bash
# Check the Fedora kernel dist-git repo for new commits that may invalidate
# the V620 powerfix patch.
#
# Usage:
#   ./v620-check-kernel-update.sh [--branch <f43|f44|rawhide>]
#   ./v620-check-kernel-update.sh --auto-rebuild
#
# Default: reports the latest pkgrelease on the host's branch and compares
# it to the cached value. If newer, optionally triggers a rebuild.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

BRANCH=""
AUTO_REBUILD="0"
KERNEL_DIR="${BUILD_DIR:-$HOME/build}/kernel"
CACHE_DIR="${POWERTUNING_ROOT}/.cache"
CACHE_FILE="${CACHE_DIR}/last-known-pkgrelease.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)        BRANCH="${2:-}"; shift 2 ;;
    --auto-rebuild)  AUTO_REBUILD="1"; shift ;;
    --kernel-dir)    KERNEL_DIR="${2:-}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               err "unknown arg: $1"; usage >&2; exit 2 ;;
  esac
done

if [[ ! -d "${KERNEL_DIR}" ]]; then
  err "Kernel repo not found: ${KERNEL_DIR}"
  exit 2
fi
mkdir -p "${CACHE_DIR}"

if [[ -z "${BRANCH}" ]]; then
  if [[ -r /etc/os-release ]]; then
    HOST_VER="$(awk -F= '/^VERSION_ID=/{gsub(/"/, "", $2); split($2, a, "."); print a[1]; exit}' /etc/os-release)"
    if [[ -n "${HOST_VER}" ]]; then
      BRANCH="f${HOST_VER}"
    fi
  fi
fi
[[ -z "${BRANCH}" ]] && BRANCH="f44"

log "Checking branch: ${BRANCH}"
pushd "${KERNEL_DIR}" >/dev/null

git fetch origin "${BRANCH}" 2>/dev/null || warn "fetch failed (offline?)"

PKGRELEASE="$(
  git show "origin/${BRANCH}:kernel.spec" 2>/dev/null \
    | awk '/^%define pkgrelease /{print $3; exit}'
)"
SPECRPMVERSION="$(
  git show "origin/${BRANCH}:kernel.spec" 2>/dev/null \
    | awk '/^%define specrpmversion /{print $3; exit}'
)"

popd >/dev/null

if [[ -z "${PKGRELEASE}" ]]; then
  err "Could not read pkgrelease from origin/${BRANCH}"
  exit 1
fi

LAST_PKGRELEASE=""
[[ -r "${CACHE_FILE}" ]] && LAST_PKGRELEASE="$(<"${CACHE_FILE}")"

log "Latest: ${SPECRPMVERSION}-${PKGRELEASE}"
log "Cached: ${LAST_PKGRELEASE:-<none>}"

if [[ "${PKGRELEASE}" == *rc* ]]; then
  warn "Latest pkgrelease is RC: ${PKGRELEASE}; not tracking"
  exit 0
fi

if [[ "${LAST_PKGRELEASE}" == "${PKGRELEASE}" ]]; then
  log "No change. Cache file: ${CACHE_FILE}"
  exit 0
fi

log "CHANGE DETECTED"
log "  Old: ${LAST_PKGRELEASE:-<none>}"
log "  New: ${PKGRELEASE}"

if [[ "${AUTO_REBUILD}" == "1" ]]; then
  log "Auto-rebuild requested"
  log "Step 1: update cache"
  echo "${PKGRELEASE}" > "${CACHE_FILE}"

  log "Step 2: invoke v620-kernel-bake.sh"
  exec "${SCRIPTS_DIR}/v620-kernel-bake.sh" \
      --build-dir "${KERNEL_DIR}" \
      --buildid .p2p \
      --patch "${PATCHES_DIR}/v620-powercap-min-120W.patch"
else
  echo "${PKGRELEASE}" > "${CACHE_FILE}"
  log "Cache updated. To rebuild: ./v620-kernel-bake.sh --build-dir ${KERNEL_DIR}"
  exit 10
fi
