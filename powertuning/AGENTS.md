# AGENTS — conventions for this feature guide

This document is for AI agents working in `powertuning/`. Humans can skim it;
the bulk is "what NOT to do, and why."

## What this guide is

A self-contained, portable guide to lowering the Radeon PRO V620 power
cap from the VBIOS-default 250 W to a 120 W floor + 180 W boot cap.

The kernel patches live here in `patches/`. The build scripts live
in `scripts/`. The systemd unit lives in `systemd/`. The deep knowledge
lives in `docs/`.

This feature is **referenced by** [`../pcie_p2p/`](../pcie_p2p/) (the
P2P guide) but **owned** by this folder. The P2P guide points at the
patches and scripts here; changes here require re-verifying the P2P
guide's full check sequence.

## The validated state

Anything **beyond** the validated scope documented in this README
Status table is research, not validated. If you change a component
(kernel version, patch, env var, dispatch selection), re-run the
verification sequence in [`../pcie_p2p/README.md`](../pcie_p2p/README.md)
(the P2P guide's full PASS/FAIL checklist covers the powercap too).

The V620 powercap wall:

| Gate | What enforces it | What flips it |
|---|---|---|
| **VBIOS `power_limit` range** | V620's static VBIOS table, PSP-signed | VBIOS flash (rejected by PSP unless W6800-signed) |
| **PowerPlay OverDrive `cap[3]`** | All 4 caps zeroed in V620 VBIOS | Tamalero patch (4 bytes + checksum) |
| **Kernel cached `min_power_limit`** | `sienna_cichlid_get_power_limit()` in amdgpu driver | The kernel patches in `patches/` |

The kernel patches here **bypass gates 1 and 2 entirely** by clamping
`min_power_limit` before it reaches the user. Once the kernel reports
`min_power_cap < 200W`, the `power1_cap` sysfs write succeeds and the SMU
accepts the value.

## Hard rules for agents

These are non-negotiable. Violating them puts production GPUs at risk.

1. **Do NOT write `pp_table` or `pp_features`.** This wedges the V620's
   SMU with **no FLR recovery**. A wedged SMU requires cold power
   (PSU off for ≥10 s) to recover. The kernel patch here never does
   this by design — it only relaxes `min_power_limit`, never writes
   to `pp_table` or `pp_features`.

2. **Do NOT modify the canonical patch's PCI-ID match string casually.**
   The patch matches on vendor/device/subsystem_vendor/subsystem_device/
   revision = `0x1002/0x73a1/0x1002/0x0e34/0x00`. Changing the match
   string risks patching non-V620 GPUs (e.g., W7800s, which use a
   different device ID).

3. **Do NOT remove the dnf exclude.** The
   `exclude=kernel kernel-core kernel-modules ... kernel-tools-libs-devel`
   line in `/etc/dnf/dnf.conf` keeps `dnf update` from silently swapping
   the .p2p buildid out for the stock fedora build — which would drop
   the patch in one shot.

4. **Do NOT use kernel-tools to set the cap.** V620 kernel-tools binaries
   (`/usr/bin/cpupower`, `/usr/bin/turbostat`, `/usr/bin/tmon`, ...) ship to the same paths
   regardless of kernel version. Installing both kernel-tools-7.1.7 and
   kernel-tools-6.17.6 will file-conflict. Install only the kernel +
   modules family on the new kernel.

## What "validated" means here

A configuration is **validated** if all of the following are true on a
host with the validated hardware (Radeon PRO V620 reference board,
subsystem `1002:0e34`, on Fedora 43):

1. The kernel boots cleanly without dmesg faults.
2. The patch's `dev_notice` fires once per V620 at boot
   (`dmesg | grep "V620 powerfix"` shows ≥1 line per card).
3. `power1_cap_min == 120000000` µW (120 W) on every V620 hwmon.
4. The boot-cap service runs at boot and writes `power1_cap=180000000` µW.
5. vLLM TP=2 inference serving Qwen3.6-27B-GPTQ-W4A16-G32 runs to completion (see [`../pcie_p2p/README.md`](../pcie_p2p/README.md) for the full bench).

Anything not meeting all five is **not validated** — even if it boots.

## Conventions

### Don't reinvent

The patches in `patches/` are the canonical implementations. The patch
itself is portable across all kernel versions ≥5.15 — do not split it
into per-kernel-version variants. If you must modify it (e.g., to
support a new PCI-ID):

1. Edit `patches/v620-powercap-min-120W.patch` in place.
2. Re-verify against the full P2P + powercap checklist.
3. Note the change in the commit message with rationale.

### Patch naming convention

`v620-powercap-min-<min>W.patch`

- `<min>`: the floor wattage the patch sets.

The canonical patch is **`patches/v620-powercap-min-120W.patch`** — it
uses the portable `noinline` attribute and works on every kernel
version ≥5.15. There is no per-kernel-version variant.

### Scripts

- All scripts are `set -euo pipefail` (where possible).
- All scripts accept `--help` and print usage.
- All scripts validate inputs before destructive actions.
- New variants of the patch go in `patches/` with the naming convention above.

## How to extend

### Adding a new patch (when the canonical one doesn't fit)

The canonical patch (`v620-powercap-min-120W.patch`) covers every
validated kernel. You should only add a new patch if:

- A future kernel moves `sienna_cichlid_ppt.c` such that the patch no
  longer applies cleanly (different file path or signature), OR
- You need a per-card floor (use the BDF-table approach instead).

If you must add a new patch:

1. Make the change in a NEW patch file with a descriptive name
   (e.g. `v620-powercap-min-7.0+-120W.patch` for a 7.0+ specific
   variant if the canonical noinline patch ever breaks on a future
   kernel).
2. Reference the new file from the build script.
3. Document the new variant in this README's Scripts and patches table with the kernel version that needs it.
4. Update [`README.md`](README.md) and [`docs/POWERCAP.md`](docs/POWERCAP.md).

### Adding a new GPU model

The patches target V620 reference boards by PCI ID
(`1002:73a1:1002:0e34`). To support RX 6900/6800 (which use device
`0x73bf`) or other gfx1030 boards, modify the patch's PCI-ID check.
Then re-bake and re-verify on the new board.

For RDNA3 (gfx1100/gfx1101/gfx1200), the patch will need to be
rewritten — the SMU path is different (`amdgpu_pm.c` instead of
`sienna_cichlid_ppt.c`).

## How to verify changes

If you change a script, a patch, or a doc:

1. Run the FULL verification sequence in
   [`../pcie_p2p/README.md`](../pcie_p2p/README.md) on the host
   (the P2P guide's checklist covers the powercap too).
2. If the change touches the kernel build, do a clean bake + reinstall + reboot first.
3. If the change touches the patch, diff it against the previous version
   to confirm it's still the same intent.
4. Update this README's Status table if the change moves something from "validated" to "validated but with different parameters."