# AGENTS — conventions for this feature guide

This document is for AI agents working in `pcie_p2p/`. Humans can skim it;
the bulk is "what NOT to do, and why."

## What this guide is

A self-contained, portable setup for enabling PCIe P2P on Fedora +
AMD CPU for Radeon PRO V620 GPUs. The kernel-config delta +
pre-gfx1030-ASIC removal (per-host) + verification live here. The patches and scripts referenced
by this guide live in [`../powertuning/`](../powertuning/) (the
powertuning feature owns them).

## The validated state

Anything **beyond** the validated scope documented in this README
Status table is research, not validated. If you change a component
(kernel, ROCm, patch, env var, dispatch selection), re-run the
verification sequence in §"Verify" before trusting production.

## Conventions

### Don't reinvent

The scripts in [`../powertuning/scripts/`](../powertuning/scripts/)
are the canonical implementations. If you need to change one:

1. Make the change in [`../powertuning/`](../powertuning/) first.
2. The change is picked up here via the relative-path reference.
3. Note the provenance in the commit message.

This guide's docs are operational — they tell you HOW to do it. The
top-level [`../AGENTS.md`](../AGENTS.md) tells you WHY it works.

### Don't change the patch casually

`v620-powercap-min-120W.patch` is portable across all kernel versions
(pre-7.0 through 7.0+) by using the `noinline` attribute. Do not
introduce per-kernel-version variants. If you must modify the patch,
see [`../powertuning/AGENTS.md`](../powertuning/AGENTS.md)
§"Don't reinvent" for the re-verification procedure.

### Don't change the kernel-config delta

`v620-kernel-bake.sh` step 1.5/4 appends:

```
CONFIG_HSA_AMD_P2P=y
CONFIG_PCI_P2PDMA=y
CONFIG_DMABUF_MOVE_NOTIFY=y
```

These three flags are required for HSA aperture registration on gfx1030.
Do not remove any. If a future kernel obsoletes one of these, the
script's behavior is idempotent and safe: the `make oldconfig` step will
silently discard the obsolete symbol without breaking the build.

### Don't recommend installing pre-gfx1030 AMD GPUs alongside the V620

Any pre-gfx1030 AMD GPU (gfx802 Tonga/Polaris, gfx803, gfx900 Vega, etc.)
physically installed alongside the V620 is a **per-host prerequisite
to remove**. ROCm 7.x dropped support for these older ASIC families;
the upstream `libhsakmt` rejects their doorbell/CWSR aperture layouts.
If a pre-gfx1030 card is in the host, the wall isn't broken: `rocminfo`
bails at line 1349 with
`Failed to map remapped mmio page on gpu_mem 0`.

**This rule only matters for hosts that have older AMD cards installed.**
A clean V620-only host doesn't need to do anything.

The check is documented in [`README.md`](README.md) §"Verify" pre-flight.

### Don't drop the dnf exclude

The `dnf exclude=kernel kernel-core kernel-modules kernel-modules-core
kernel-modules-extra kernel-modules-extra-matched kernel-modules-internal
kernel-uki-virt kernel-uki-virt-addons kernel-tools kernel-tools-libs
kernel-tools-libs-devel` line in `/etc/dnf/dnf.conf` is what keeps `dnf
update` from silently swapping the .p2p buildid out for the stock fedora
build — which would drop both the kernel-config delta AND the v620
powercap patch in one shot.

Without this exclude, every `dnf update` reverts the validated state.

### Don't use kernel-tools to set the cap

V620 kernel-tools binaries (`/usr/bin/cpupower`, `/usr/bin/turbostat`,
`/usr/bin/tmon`, ...) ship to the same paths regardless of kernel
version. Installing both kernel-tools-7.1.7 and kernel-tools-6.17.6
will file-conflict and refuse to install. Install only the kernel +
modules family on the new kernel (Option A in
[`README.md`](README.md) §"Install"). The kernel-tools from
the older kernel still work — they read /sys, not kernel ABI.

## How to extend

### Adding a new kernel version

1. Find the SRPM at kojipkgs:
   ```
   https://kojipkgs.fedoraproject.org/packages/kernel/<ver>/<rel>/src/
   ```
2. The patch is `../powertuning/patches/v620-powercap-min-120W.patch`
   for any kernel version — it's portable.
3. Bake, install, boot, verify (see [`README.md`](README.md) or [`README.md`](README.md)).
4. Update this README's Status table if the new kernel is within validated scope.
5. If the bake fails, check whether the kernel moved `sienna_cichlid_ppt.c` out of `drivers/gpu/drm/amd/pm/swsmu/smu11/`. The patch targets that specific file; if the path changes, the patch must be updated.

### Adding a new GPU model

The patch targets V620 reference boards by PCI ID
(`1002:73a1:1002:0e34`). To support RX 6900/6800 (which use device
`0x73bf`) or other gfx1030 boards, modify the patch's PCI-ID check.
Then re-bake and re-verify on the new board.

For RDNA3 (gfx1100/gfx1101/gfx1200), the patch will need to be
rewritten — the SMU path is different (`amdgpu_pm.c` instead of
`sienna_cichlid_ppt.c`).

### Adding a new check

Add the check to [`README.md`](README.md) with:
- What command to run
- What output to expect (PASS criteria)
- What the failure mode looks like
- Which doc section to consult for the fix

## How to verify changes

If you change a doc or a script:

1. Run the FULL verification sequence in [`README.md`](README.md) on the host.
2. If the change touches the kernel build, do a clean bake + reinstall + reboot first.
3. Update this README's Status table if the change moves something from "validated" to "validated but with different parameters."

## What "validated" means here

A configuration is "validated" if all of the following are true on a
host with the validated hardware (4× Radeon PRO V620 reference board,
subsystem `1002:0e34`, on AMD EPYC + Fedora 43):

1. The kernel boots cleanly without dmesg faults.
2. `rocminfo` enumerates 5 HSA agents (1 CPU + 4 V620) with exit code 0.
3. `amd-smi topology` shows 12/12 GPU↔GPU pairs as **ENABLED** with link type PCIE, weight 40, hops 2, atomics 64,32.
4. The KFD topology shows `p2p_links_count 3` per V620 (full mesh).
5. `v620-powercap.service` runs at boot and sets `power1_cap=180000000` on all 4 V620 hwmons.
6. Any multi-GPU collective over the P2P aperture completes without hang
   (the user's specific workload).

Anything not meeting all six is **not validated** — even if it boots.