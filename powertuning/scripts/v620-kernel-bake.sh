#!/usr/bin/env bash
# v620-kernel-bake.sh — bake the V620 powercap-min fix into a Fedora kernel
# rpm build (kernel.spec dist-git style tree) and produce installable rpms.
#
# This is the DURABLE installation route: the fix lives inside the in-tree
# amdgpu.ko.xz, so it survives initramfs regeneration and needs no extra/
# override. It only needs re-doing when you move to a new kernel version.
#
# Build dir requirements (Fedora kernel dist-git / ARK style layout):
#   kernel.spec, linux-<ver>.tar.xz, patch-<ver>-redhat.patch,
#   kernel-<arch>-*.config, kernel-local, linux-kernel-test.patch, ...
# Get one by extracting kernel-<ver>-<rel>.src.rpm (rpm -ivh + rpmbuild -bp
# is NOT needed; the spec does its own prep) or from a dist-git checkout.
#
# Usage:
#   ./v620-kernel-bake.sh --build-dir /path/to/kernel-7.1.7 [--buildid .p2p] [--patch <name>]
#
# --patch defaults to v620-powercap-min-120W.patch. The patch is
# portable across all kernel versions ≥5.15 — it uses `noinline`
# (not `__noipa`), so it compiles cleanly on pre-7.0 and 7.0+ kernels
# without needing per-kernel variants.
#
# What it does (idempotent):
#   1. copy <patch> into the build dir
#   2. declare + apply it in kernel.spec via a marked block
#      (reuses the block if present, inserts after Patch999999 otherwise)
#   3. empty linux-kernel-test.patch (prevents double-apply of the same hunks)
#   4. rpmbuild -ba with flat-layout defines (~10-20 min on 32+ cores)
#   5. prints install instructions
#
# Install afterwards (as root):
#   cd <build-dir>
#   rpm -Uvh --replacepkgs x86_64/kernel-{,core-,modules-,modules-core-}*.rpm
#   # optional but recommended for future out-of-tree work:
#   rpm -Uvh --replacepkgs x86_64/kernel-devel-*.rpm
#   reboot

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR=""
BUILDID=".p2p"
PATCH_NAME="v620-powercap-min-120W.patch"   # portable; works on all kernel versions ≥5.15
PATCH_TAG="Patch1000000"   # spec tag number (rpm parses high numbers fine;
                           # Fedora's own test hook uses Patch999999)

while [ $# -gt 0 ]; do
  case "$1" in
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --buildid)   BUILDID="$2"; shift 2 ;;
    --patch)     PATCH_NAME="$2"; shift 2 ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$BUILD_DIR" ] || { echo "--build-dir is required" >&2; exit 2; }
[ -f "$BUILD_DIR/kernel.spec" ] || { echo "no kernel.spec in $BUILD_DIR" >&2; exit 1; }
PATCH_FILE="$SCRIPT_DIR/$PATCH_NAME"
[ -f "$PATCH_FILE" ] || { echo "patch missing: $PATCH_FILE" >&2; exit 1; }

SPEC="$BUILD_DIR/kernel.spec"

echo "== 1/4 install patch file =="
cp "$PATCH_FILE" "$BUILD_DIR/$PATCH_NAME"

echo "== 1.5/4 apply kernel-config delta (HSA_AMD_P2P + deps) =="
# Idempotent: dedup any existing matching lines, ensure exactly the three flags are set.
# This delta is required for ROCm KFD to register the GPU doorbell/CWSR aperture
# on RDNA (gfx1030) without ENOMEM at AMDKFD_IOC_ALLOC_MEMORY_OF_GPU. Same on
# pre-7 (kernel 6.x) and post-7 (kernel 7.1+). Without it, rocminfo bails at
# line 1349 / hsakmt "Failed to map remapped mmio page on gpu_mem 0".
#
# Fedora's kernel-x86_64-fedora.config regularly strips these three from a base
# build (RHEL config has them); without this step the bake will succeed but the
# resulting kernel will fail HSA aperture registration just like a stock fedora
# kernel.
FC="$(ls "$BUILD_DIR"/kernel-*-fedora.config 2>/dev/null | head -1)"
if [ -n "$FC" ] && [ -f "$FC" ]; then
  for f in CONFIG_HSA_AMD_P2P CONFIG_PCI_P2PDMA CONFIG_DMABUF_MOVE_NOTIFY; do
    sed -i "/^${f}=/d" "$FC"
    echo "${f}=y" >> "$FC"
  done
  echo "  appended/deduped to $FC:"
  grep -E "^CONFIG_(HSA_AMD_P2P|PCI_P2PDMA|DMABUF_MOVE_NOTIFY)=" "$FC"
else
  echo "  (no kernel-*-fedora.config found in $BUILD_DIR — skipped)" >&2
fi

echo "== 2/4 declare + apply in kernel.spec ="
if grep -q "^# --- v620-powerfix start ---$" "$SPEC"; then
  # block exists: point it at our patch file (in-place filename swap)
  sed -i "/^# --- v620-powerfix start ---/,/^# --- v620-powerfix end ---/s|^Patch[0-9]*: .*\.patch|$PATCH_TAG: $PATCH_NAME|" "$SPEC"
  sed -i "/^# --- v620-powerfix apply start ---/,/^# --- v620-powerfix apply end ---/s|^ApplyOptionalPatch .*\.patch|ApplyOptionalPatch $PATCH_NAME|" "$SPEC"
  echo "updated existing v620-powerfix block"
else
  # insert declaration after the test-hook declaration
  sed -i "/^Patch999999: linux-kernel-test\.patch$/a\\
# --- v620-powerfix start ---\\
$PATCH_TAG: $PATCH_NAME\\
# --- v620-powerfix end ---" "$SPEC"
  # insert application after the test-hook application
  sed -i "/^ApplyOptionalPatch linux-kernel-test\.patch$/a\\
# --- v620-powerfix apply start ---\\
ApplyOptionalPatch $PATCH_NAME\\
# --- v620-powerfix apply end ---" "$SPEC"
  echo "inserted new v620-powerfix block"
fi
grep -n "v620-powerfix\|$PATCH_NAME" "$SPEC"

echo "== 3/4 empty linux-kernel-test.patch (avoid double-apply) =="
: > "$BUILD_DIR/linux-kernel-test.patch"

echo "== 4/4 rpmbuild =="
KVER="$(ls "$BUILD_DIR"/linux-*.tar.xz | head -1 | sed 's/.*linux-\(.*\)\.tar\.xz/\1/')"
[ -n "$KVER" ] || { echo "cannot determine kernel version from tarball in $BUILD_DIR" >&2; exit 1; }
LOG="$BUILD_DIR/build-logs/v620-bake-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$BUILD_DIR/build-logs"
cd "$BUILD_DIR"
rpmbuild -ba kernel.spec \
  --define "buildid $BUILDID" \
  --define "_specdir $BUILD_DIR" \
  --define "_sourcedir $BUILD_DIR" \
  --define "_builddir $BUILD_DIR/kernel-$KVER-build" \
  --define "_rpmdir $BUILD_DIR" \
  --define "_srcrpmdir $BUILD_DIR" \
  --without debug \
  --without debuginfo \
  --without selftests \
  --without ynl \
  2>&1 | tee "$LOG" | tail -5

echo
echo "build complete. rpms in: $BUILD_DIR/x86_64/"
echo "install with:"
echo "  sudo rpm -Uvh --replacepkgs $BUILD_DIR/x86_64/kernel-*.rpm"
echo "  sudo reboot"
echo "verify with: $SCRIPT_DIR/v620-verify.sh"
