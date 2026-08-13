# V620 powercap — 120 W floor + 180 W boot cap (deep dive)

This is the **powercap subsystem** in detail. Two pieces:

1. **120 W floor** (kernel patch): the V620 VBIOS declares 250 W min PPT;
   hwmon rejects any `power1_cap` write below that. The patch lowers
   the floor to 120 W by PCI-ID match. **Required** for the 180 W cap
   to stick.
2. **180 W boot cap** (systemd service): writes 180000000 µW to every
   V620's `power1_cap` at boot. Runs once per boot, idempotent.

Both pre-7 and post-7 use the same scripts, the same systemd unit, and the
**same patch**. The patch uses `noinline` (not `__noipa`) precisely so it
works on all kernel versions — see the patch header for details.

For the P2P-context overview (why the powercap matters for the
HSA aperture registration wall), see
[`../../pcie_p2p/README.md`](../../pcie_p2p/README.md) §"Status" and
§"Verify" check 4.

## Why 250 W floor / 120 W floor / 180 W boot cap?

| Wattage | What |
|---|---|
| **250 W** (VBIOS default) | V620 VBIOS-declared min PPT. hwmon rejects any write below this. The card refuses to throttle, will pull whatever it wants. |
| **120 W** (our floor) | Lowest wattage the SMU firmware accepts. Below this, the SMU itself rejects. We clamp to this. |
| **180 W** (our boot cap) | Below 250 W (VBIOS), safely above 120 W (firmware floor). Verified on 24/7 production workload — thermal throttle only at >85% sustained util. |

Anything between 120 W and 250 W would technically work; we picked 180 W
because it matches `power1_cap_max` and is empirically the safe-for-24/7
value.

## What the patch does

[`patches/v620-powercap-min-120W.patch`](../patches/v620-powercap-min-120W.patch)
modifies **one** function:

```c
// drivers/gpu/drm/amd/pm/swsmu/smu11/sienna_cichlid_ppt.c
// in sienna_cichlid_get_power_limit(), after SMU returns the limit:

if (smu->adev->pdev->vendor == 0x1002
 && smu->adev->pdev->device   == 0x73a1
 && smu->adev->pdev->subsystem_vendor == 0x1002
 && smu->adev->pdev->subsystem_device == 0x0e34)
    sienna_cichlid_v620_min_powercap_fix(smu, min_power_limit);

// helper:
if (*min_power_limit > 120U)
    *min_power_limit = 120U;
dev_notice(adev->dev,
           "V620 powerfix: allowing PPT limit down to 120 W on %s\n",
           dev_name(adev->dev));
```

The 4-tuple PCI-ID match (`1002:73a1:1002:0e34`) uniquely identifies the
V620 reference board. RX 6800/6900 are device `0x73bf` and aren't
matched.

### Why `noinline` (and not `__noipa`)?

`__noipa` is a kernel attribute added upstream ~6.9. On 7.0+ it's
defined; on 6.x it's not. The portable substitute is `noinline`,
which has been in `include/linux/compiler_types.h` forever. Both are
functionally equivalent for this use case (one-shot init function
that's never inlined; IPA optimization within the body is irrelevant).

**This patch uses `noinline` so it works on every kernel version ≥5.15.**
There is no per-kernel-version patch variant — see the patch header for
the full rationale.

### Why does the bake reject the patch?

If you see `error: expected ';' before 'void'` during the bake, the
patch likely didn't apply cleanly (kernel source moved the function
or its signature changed). Verify the kernel version is ≥5.15 and that
`drivers/gpu/drm/amd/pm/swsmu/smu11/sienna_cichlid_ppt.c` exists with
`__noipa` removed but a place to insert the patch block present.

If the function has moved to a different file in your kernel tree, the
patch needs updating for that kernel — see [`README.md`](../README.md) Status table for what's been validated.

## What the boot-cap service does

`systemd/v620-powercap.service` (systemd oneshot):

```ini
[Unit]
Description=Apply 180 W power cap to Radeon PRO V620 cards

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/v620-cap-apply.sh 180
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

`scripts/v620-cap-apply.sh 180`:

```bash
W="${1:-180}"
UW=$((W * 1000000))
DEADLINE=$((SECONDS + 60))

V620_VENDOR=0x1002
V620_DEVICE=0x73a1
V620_SVENDOR=0x1002
V620_SDEVICE=0x0e34

# Wait for amdgpu hwmon nodes to appear (up to 60s)
# Then for each V620 hwmon:
#   if power1_cap != $UW: write $UW (180000000 µW = 180 W)
# Stable across two scans = all 4 cards seen, exit 0
```

The script is **idempotent** — re-running it re-asserts the same value,
or does nothing if already 180 W.

The PCI-ID match is the same 4-tuple used in the kernel patch. Both
the patch and the service script match the **same V620 reference board**;
no other gfx1030 board is affected.

### Why `/usr/local/sbin/` and not $HOME?

SELinux on Fedora in enforcing mode refuses to execute scripts with
`user_home_t` context. systemd errors instantly with `203/EXEC` if you
try. The script must be in a context-appropriate path
(`/usr/local/sbin/` is correct).

### What if I want a different wattage?

Change the wattage in two places:
1. The systemd unit's `ExecStart=/usr/local/sbin/v620-cap-apply.sh 180` → e.g. `170`.
2. The script's `W="${1:-180}"` → `W="${1:-170}"`.

Both are independent. The kernel patch still clamps to 120 W floor; you
can write anywhere between 120 W and 250 W.

## How to verify the subsystem is working

After install + reboot:

```bash
# 1. Did the patch fire at boot?
dmesg | grep -E 'V620 powerfix|amdgpu.*powerfix'
# expect: 4 lines (one per V620), each "V620 powerfix: allowing PPT limit down to 120 W on 0000:XX:00.0"

# 2. Did the service run?
systemctl status v620-powercap.service
# expect: Active: active (exited) since <boot>, ExecStart status 0/SUCCESS

# 3. Is the cap at 180 W on every V620?
for h in /sys/class/hwmon/hwmon*/power1_cap; do
  echo "$(basename $(dirname $h)) = $(cat $h)"
done
# expect: every V620 hwmon shows 180000000

# 4. Did the floor get set to 120 W? (informational)
for h in /sys/class/hwmon/hwmon*/power1_cap_min; do
  echo "$(basename $(dirname $h)).cap_min = $(cat $h)"
done
# expect: every V620 hwmon shows 120000000

# 5. Can you write 120 W (the floor)?
echo 120000000 | sudo tee /sys/class/hwmon/hwmonN/power1_cap
# expect: write accepted; cap is now 120 W

# 6. Can you write 110 W (below the floor)?
echo 110000000 | sudo tee /sys/class/hwmon/hwmonN/power1_cap
# expect: write REJECTED (EINVAL); the floor is enforced
```

## Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `power1_cap` write rejected even at 180 W | kernel patch not applied | check dmesg for `V620 powerfix` notices; if missing, re-bake with the right patch |
| `power1_cap` write accepted, but dmesg has no `V620 powerfix` notices | patch didn't apply | check `/boot/config-$(uname -r)` has `CONFIG_AMDGPU=m`, and `sienna_cichlid_ppt.c` exists in the source tree |
| `203/EXEC` from `v620-powercap.service` | script in $HOME | move to `/usr/local/sbin/` |
| `Cannot find /sys/class/hwmon/...` | amdgpu module not yet loaded when service runs | service retries internally up to 60 s; if still failing, amdgpu is not loading (separate problem) |
| Powercap not sticking across reboots | service not enabled | `sudo systemctl enable v620-powercap.service` |

## Out of scope (see upstream `powertuning/` for these)

The following are **session-specific working notes** (per-host
research, per-card characterization, build pipelines that wrap the
user's local infrastructure) that are NOT part of this canonical
guide. They lived in the source `powertuning/` we migrated from:

- **Tamalero V620 soft unlock** — VBIOS patch path that gets a 232 W
  floor. Rejected because we want 180 W.
- **Per-GPU silicon variation** — the source guide measured per-card
  failure boundaries from -100 mV to -150 mV. This is about voltage
  offset (undervolting), not the powercap.
- **The staged plan V0–V6** — a per-session validation plan (not
  canonical knowledge). See [`STAGED_PLAN.md`](STAGED_PLAN.md) for the
  generic version.