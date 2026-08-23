#!/usr/bin/env bash
# v620-cap-apply.sh [WATTS] — write a power cap to every Radeon PRO V620.
#
# Portable: matches cards by PCI IDs (0x1002:0x73a1 + subsystem
# 0x1002:0x0e34) via sysfs hwmon device links — no hardcoded bus addresses.
# Requires the v620-powercap-min kernel fix for caps below 250 W to stick.
#
# Designed to run at boot from v620-powercap.service: waits (up to 60 s)
# until the V620 hwmon nodes appear and the count is stable across two
# scans, writes the cap to each card, then exits. Idempotent — re-running
# re-asserts the same value.
#
# Usage: sudo ./v620-cap-apply.sh [WATTS]   (default: 180)
# Exit:  0 = cap applied to >=1 card, 1 = no V620 found within 60 s.

set -uo pipefail

W="${1:-180}"
[[ "$W" =~ ^[0-9]+$ ]] || { echo "v620-cap-apply: wattage must be an integer, got '$W'" >&2; exit 2; }
UW=$((W * 1000000))
DEADLINE=$((SECONDS + 60))

V620_VENDOR=0x1002
V620_DEVICE=0x73a1
V620_SVENDOR=0x1002
V620_SDEVICE=0x0e34

log() { echo "v620-cap-apply: $*"; }

last=-1
while [ $SECONDS -lt $DEADLINE ]; do
  n=0
  for h in /sys/class/hwmon/hwmon*; do
    [ -f "$h/name" ] || continue
    grep -qi amdgpu "$h/name" || continue
    d="$(readlink -f "$h/device")"
    [ "$(cat "$d/vendor" 2>/dev/null)"          = "$V620_VENDOR"  ] || continue
    [ "$(cat "$d/device" 2>/dev/null)"          = "$V620_DEVICE"  ] || continue
    [ "$(cat "$d/subsystem_vendor" 2>/dev/null)" = "$V620_SVENDOR" ] || continue
    [ "$(cat "$d/subsystem_device" 2>/dev/null)" = "$V620_SDEVICE" ] || continue
    [ -w "$h/power1_cap" ] || { log "FAIL: $h/power1_cap not writable (need root)"; continue; }
    cur="$(cat "$h/power1_cap" 2>/dev/null)"
    if [ "$cur" != "$UW" ]; then
      if echo "$UW" > "$h/power1_cap"; then
        log "$(basename "$d"): cap -> ${W} W (was $((cur / 1000000)) W)"
      else
        log "FAIL: write rejected on $(basename "$d") — is the v620 powercap-min kernel fix active?"
      fi
    fi
    n=$((n + 1))
  done
  # stable across two consecutive scans -> all cards seen, we are done
  if [ "$n" -gt 0 ] && [ "$n" = "$last" ]; then
    log "done: ${W} W cap on $n V620 card(s)"
    exit 0
  fi
  last=$n
  sleep 2
done

if [ "$last" -gt 0 ]; then
  log "done (timeout): ${W} W cap on $last V620 card(s)"
  exit 0
fi
log "FAIL: no V620 cards found within 60 s"
exit 1
