#!/usr/bin/env bash
# v620-module-install.sh — build & install the V620 powercap-min fix as an
# out-of-tree amdgpu.ko override for the CURRENTLY RUNNING kernel.
#
# Portable: no machine-specific values. Works on any Fedora-family machine
# with Radeon PRO V620 cards (PCI 0x1002:0x73a1, subsystem 0x1002:0x0e34).
#
# Requirements:
#   - kernel-devel matching `uname -r`   (dnf install kernel-devel-$(uname -r))
#   - kernel source tarball for the SAME base version, e.g. linux-7.1.7.tar.xz
#     (only drivers/gpu/drm/amd is extracted; the Red Hat/Fedora patch is not
#     needed for the amdgpu out-of-tree build unless it touches amd/)
#   - gcc, make, git, xz, tar, objdump (binutils)
#
# Usage:
#   sudo ./v620-module-install.sh --tarball /path/to/linux-7.1.7.tar.xz [--reload]
#
# What it does (idempotent):
#   1. extract drivers/gpu/drm/amd from the tarball into WORKDIR
#   2. apply v620-powercap-min-120W.patch (skipped if already applied)
#   3. copy amdgpu_trace.h into the kernel-devel mirror
#      (M= builds resolve TRACE_INCLUDE_PATH relative to kernel-devel;
#       Fedora ships only a partial drivers/ mirror there)
#   4. build amdgpu.ko against /lib/modules/$(uname -r)/build
#   5. install to /lib/modules/$(uname -r)/extra/amdgpu.ko
#   6. write /etc/depmod.d/00-v620.conf  (extra-first module search order)
#   7. depmod -a && dracut --force       (initramfs must embed the FIXED
#      module, otherwise boot silently loads the stock one)
#   8. optionally reload amdgpu (--reload) — only if no process holds GPUs
#
# Rollback:  sudo ./v620-module-install.sh --uninstall  (removes extra module,
#            rebuilds initramfs, reboot to return to stock amdgpu)
#
# NOTE: a kernel rpm install/reinstall WIPES /lib/modules/<kver>/extra/ and
# regenerates the initramfs — re-run this script after every kernel update,
# or use v620-kernel-bake.sh to bake the fix into the kernel rpm itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/v620-powercap-min-120W.patch"
KREL="$(uname -r)"
KVER="${KREL%%-*}"                       # e.g. 7.1.7
KDEVEL="/usr/src/kernels/$KREL"
AMD_SUB="drivers/gpu/drm/amd"
PPT_REL="$AMD_SUB/pm/swsmu/smu11/sienna_cichlid_ppt.c"
WORKDIR="${WORKDIR:-$HOME/v620-build}"
DEPMOD_CONF="/etc/depmod.d/00-v620.conf"
DO_RELOAD=0
DO_UNINSTALL=0
TARBALL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tarball)   TARBALL="$2"; shift 2 ;;
    --reload)    DO_RELOAD=1; shift ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

if [ "$DO_UNINSTALL" = 1 ]; then
  echo "== uninstall =="
  rm -f "/lib/modules/$KREL/extra/amdgpu.ko"
  depmod -a "$KREL"
  dracut --force
  echo "removed extra/amdgpu.ko and rebuilt initramfs."
  echo "reboot to return to the stock in-tree amdgpu."
  exit 0
fi

[ -n "$TARBALL" ] || { echo "--tarball /path/to/linux-$KVER.tar.xz is required" >&2; exit 2; }
[ -f "$TARBALL" ] || { echo "tarball not found: $TARBALL" >&2; exit 1; }
[ -d "$KDEVEL" ] || { echo "kernel-devel missing for $KREL (dnf install kernel-devel-$KREL)" >&2; exit 1; }
[ -f "$PATCH_FILE" ] || { echo "patch file missing: $PATCH_FILE" >&2; exit 1; }

SRC="$WORKDIR/linux-$KVER"
echo "== 1/8 extract amd subtree =="
mkdir -p "$WORKDIR"
tar -xJf "$TARBALL" -C "$WORKDIR" "linux-$KVER/$AMD_SUB"

echo "== 2/8 apply patch =="
if grep -q "sienna_cichlid_v620_min_powercap_fix" "$SRC/$PPT_REL"; then
  echo "already patched, skipping"
else
  (cd "$SRC" && git apply "$PATCH_FILE" 2>/dev/null) || (cd "$SRC" && patch -p1 < "$PATCH_FILE")
fi

echo "== 3/8 kernel-devel trace header =="
if [ ! -f "$KDEVEL/$AMD_SUB/amdgpu/amdgpu_trace.h" ]; then
  mkdir -p "$KDEVEL/$AMD_SUB/amdgpu"
  cp "$SRC/$AMD_SUB/amdgpu/amdgpu_trace.h" "$KDEVEL/$AMD_SUB/amdgpu/amdgpu_trace.h"
  echo "copied amdgpu_trace.h into kernel-devel mirror"
else
  echo "already present"
fi

echo "== 4/8 build amdgpu.ko =="
make -C "/lib/modules/$KREL/build" M="$SRC/$AMD_SUB/amdgpu" -j"$(nproc)" amdgpu.ko
KO="$SRC/$AMD_SUB/amdgpu/amdgpu.ko"
nm "$KO" | grep -q sienna_cichlid_v620_min_powercap_fix || { echo "helper symbol missing in built module!" >&2; exit 1; }

echo "== 5/8 install to extra/ =="
mkdir -p "/lib/modules/$KREL/extra"
install -m 0644 "$KO" "/lib/modules/$KREL/extra/amdgpu.ko"

echo "== 6/8 depmod search order =="
echo "search extra updates built-in kernel" > "$DEPMOD_CONF"
depmod -a "$KREL"
modinfo -F filename amdgpu | grep -q "/extra/" || { echo "extra/ override did NOT take effect!" >&2; exit 1; }

echo "== 7/8 rebuild initramfs =="
[ -f "/boot/initramfs-$KREL.img" ] && cp -n "/boot/initramfs-$KREL.img" "/boot/initramfs-$KREL.img.pre-v620fix.bak" || true
dracut --force
lsinitrd "/boot/initramfs-$KREL.img" 2>/dev/null | grep -q "extra/amdgpu.ko" \
  && echo "initramfs embeds extra/amdgpu.ko (good)" \
  || echo "WARNING: initramfs may still embed the stock module — check lsinitrd output"

echo "== 8/8 activate =="
if [ "$DO_RELOAD" = 1 ]; then
  if fuser /dev/dri/renderD* >/dev/null 2>&1; then
    echo "GPUs are in use — NOT reloading. Reboot when convenient."
  else
    modprobe -r amdgpu && modprobe amdgpu
    sleep 10
    dmesg | grep -i "V620 powerfix" || echo "WARNING: no powerfix notices after reload"
  fi
else
  echo "installed. Reboot to activate (initramfs will load the fixed module),"
  echo "or re-run with --reload on an idle machine."
fi

echo "done. Verify with: $SCRIPT_DIR/v620-verify.sh"
