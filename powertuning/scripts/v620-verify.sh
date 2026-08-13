#!/usr/bin/env bash
# v620-verify.sh — verify the V620 powercap-min fix is active on this machine.
#
# Portable: detects V620 cards by PCI IDs (0x1002:0x73a1 + subsystem
# 0x1002:0x0e34) from sysfs — no hardcoded bus addresses.
#
# Checks:
#   1. one "V620 powerfix" dmesg notice per detected V620 (per module load)
#   2. power1_cap_min == 120000000 (120 W) on every V620 hwmon
#   3. optional: --write-test WATTS  writes W watts to power1_cap on the first
#      V620, verifies readback, then restores cap_max. Needs root.
#
# Usage: ./v620-verify.sh [--write-test 200]
# Exit: 0 = all checks pass, 1 = failure.

set -uo pipefail

WRITE_TEST=""
[ "${1:-}" = "--write-test" ] && WRITE_TEST="${2:-200}"

V620_VENDOR=0x1002
V620_DEVICE=0x73a1
V620_SVENDOR=0x1002
V620_SDEVICE=0x0e34
EXPECT_MIN=120000000

fail=0
nv620=0

echo "== detecting V620 cards =="
declare -a HWMONS=()
for h in /sys/class/hwmon/hwmon*; do
  [ -f "$h/name" ] || continue
  grep -qi amdgpu "$h/name" || continue
  d="$(readlink -f "$h/device")"
  v="$(cat "$d/vendor" 2>/dev/null)";  dv="$(cat "$d/device" 2>/dev/null)"
  sv="$(cat "$d/subsystem_vendor" 2>/dev/null)"; sd="$(cat "$d/subsystem_device" 2>/dev/null)"
  if [ "$v" = "$V620_VENDOR" ] && [ "$dv" = "$V620_DEVICE" ] && \
     [ "$sv" = "$V620_SVENDOR" ] && [ "$sd" = "$V620_SDEVICE" ]; then
    bdf="$(basename "$d")"
    echo "  V620 found: $bdf ($h)"
    HWMONS+=("$h")
    nv620=$((nv620+1))
  fi
done

if [ "$nv620" = 0 ]; then
  echo "no V620 cards detected — nothing to verify (fix is a no-op here)"
  exit 0
fi

echo
echo "== check 1: dmesg notices =="
# count notices from the MOST RECENT module load: all notice timestamps
# should be close together; simplest robust check: at least nv620 total.
n="$(dmesg 2>/dev/null | grep -c "V620 powerfix" || sudo -n dmesg 2>/dev/null | grep -c "V620 powerfix" || echo 0)"
echo "  notices in dmesg: $n (V620 cards: $nv620)"
[ "$n" -ge "$nv620" ] || { echo "  FAIL: missing powerfix notices"; fail=1; }

echo
echo "== check 2: cap_min per card =="
for h in "${HWMONS[@]}"; do
  bdf="$(basename "$(readlink -f "$h/device")")"
  cm="$(cat "$h/power1_cap_min" 2>/dev/null)"
  c="$(cat "$h/power1_cap" 2>/dev/null)"
  cx="$(cat "$h/power1_cap_max" 2>/dev/null)"
  echo "  $bdf: cap_min=$cm cap=$c cap_max=$cx"
  [ "$cm" = "$EXPECT_MIN" ] || { echo "  FAIL: cap_min != $EXPECT_MIN on $bdf"; fail=1; }
done

if [ -n "$WRITE_TEST" ]; then
  echo
  echo "== check 3: write test (${WRITE_TEST}W on first V620) =="
  h="${HWMONS[0]}"
  bdf="$(basename "$(readlink -f "$h/device")")"
  uw=$((WRITE_TEST * 1000000))
  max="$(cat "$h/power1_cap_max")"
  orig="$(cat "$h/power1_cap")"
  if [ "$(id -u)" != 0 ]; then
    echo "  SKIP: needs root"
  else
    echo "$uw" > "$h/power1_cap" && echo "  wrote $uw to $bdf"
    sleep 1
    rb="$(cat "$h/power1_cap")"
    echo "  readback: $rb"
    [ "$rb" = "$uw" ] || { echo "  FAIL: readback mismatch"; fail=1; }
    echo "$orig" > "$h/power1_cap" && echo "  restored $orig"
  fi
fi

echo
if [ "$fail" = 0 ]; then
  echo "PASS: V620 powerfix active on $nv620 card(s)"
else
  echo "FAIL: see above"
fi
exit $fail
