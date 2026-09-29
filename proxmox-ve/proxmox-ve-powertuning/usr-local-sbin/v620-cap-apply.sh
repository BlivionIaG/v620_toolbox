#!/usr/bin/env bash
# v620-cap-apply.sh [WATTS] — write a power cap to every V620 (default from
# /etc/default/v620-powertuning, else 180 W).
set -u

WATTS_DEFAULT=180
CONF_FILE="/etc/default/v620-powertuning"
# shellcheck disable=SC1090
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

W="${1:-${WATTS:-$WATTS_DEFAULT}}"
UW=$((W * 1000000))

for i in $(seq 1 30); do            # wait up to 60 s for amdgpu hwmon
	found=0
	for h in /sys/class/hwmon/hwmon*; do
		[ -f "$h/name" ] && grep -qi amdgpu "$h/name" || continue
		d="$(readlink -f "$h/device")"
		[ "$(cat "$d/device" 2>/dev/null)"           = "0x73a1" ] || continue
		[ "$(cat "$d/subsystem_device" 2>/dev/null)" = "0x0e34" ] || continue
		echo "$UW" > "$h/power1_cap" 2>/dev/null && found=1
	done
	[ "$found" = 1 ] && { echo "v620-cap-apply: ${W} W applied"; exit 0; }
	sleep 2
done
echo "v620-cap-apply: no V620 found" >&2
exit 1
