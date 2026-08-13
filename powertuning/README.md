# Powercap subsystem for Radeon PRO V620

Lower the V620 power cap from the VBIOS-default 250 W to a 120 W floor
plus a 180 W boot cap.

## How it works

The V620's VBIOS declares 250 W as its minimum power limit. The kernel
enforces this and rejects any lower setting. We patch the kernel to
report 120 W instead, so a lower cap can be set. A systemd service then
writes 180 W at boot.

## Status

| | Pre-7 (≤6.19.x) | Post-7 (≥7.1) |
|---|---|---|
| Patch | `v620-powercap-min-120W.patch` (same on both — portable via `noinline`) | `v620-powercap-min-120W.patch` |
| Floor | 120 W | 120 W |
| Boot cap | 180 W | 180 W |
| Validated on | Fedora 43, kernel 6.17.6 | Fedora 43, kernel 7.1.7 |

See the Status table above for what's validated.

## Quick start

This feature's patches are referenced by the P2P guide
([`../pcie_p2p/README.md`](../pcie_p2p/README.md)). The full reproduction is:

1. Read [`../pcie_p2p/README.md`](../pcie_p2p/README.md).
2. Bake the kernel with `patches/v620-powercap-min-120W.patch` (same
   patch on both pre-7 and post-7).
3. Install `scripts/v620-cap-apply.sh` and `systemd/v620-powercap.service` for the boot cap.
4. Verify with `scripts/v620-verify.sh` and the P2P guide's full checklist.

## Sections

| Path | Purpose |
|---|---|
| [`AGENTS.md`](AGENTS.md) | Conventions for AI agents modifying this feature |
| [`docs/POWERCAP.md`](docs/POWERCAP.md) | The 120 W floor / 180 W boot cap subsystem — deep dive |
| [`docs/AMD_P2P.md`](docs/AMD_P2P.md) | AMD PCIe P2P knowledge base (kernel config, hardware, BIOS, runtime) |
| [`docs/STAGED_PLAN.md`](docs/STAGED_PLAN.md) | Staged validation plan (V0–V6) for the full powercap journey |
| [`patches/README.md`](patches/README.md) | Patch system — naming convention, identity match, what's NOT touched |

## Scripts and patches

| Path | What it does |
|---|---|
| `patches/v620-powercap-min-120W.patch` | The canonical patch. Portable across all kernel versions (pre-7 and 7.0+) via `noinline`. Matches the V620 subsystem ID (works for any number of V620s in the host). |
| `scripts/v620-kernel-bake.sh` | Bake a fedora dist-git kernel rpm with the patch + the kernel-config delta baked in |
| `scripts/v620-module-install.sh` | Alternative — build amdgpu.ko as out-of-tree module override against running kernel |
| `scripts/v620-cap-apply.sh` | Boot-time 180 W cap writer. PCI-ID match. |
| `scripts/v620-verify.sh` | Post-install verification (`V620 powerfix` dmesg + `power1_cap_min=120000000`) |
| `scripts/v620-validate-kernel-rpm.sh` | Validates P2P config + powerfix marker in a built kernel RPM |
| `scripts/v620-check-kernel-update.sh` | Polls Fedora kernel dist-git for new commits |
| `scripts/v620-p2p-readiness.sh` | Four-gate P2P readiness diagnostic (kernel + hardware + ACS/IOMMU + runtime) |
| `scripts/lib/common.sh` | Shared helpers (paths, identity check, active job detection) |
| `systemd/v620-powercap.service` | Systemd oneshot that runs `v620-cap-apply.sh 180` at boot |

## Rebuild workflow (manual)

When a new Fedora kernel release appears, the human runs these in order:

```bash
# 1. Poll for a new release; bails if unchanged
scripts/v620-check-kernel-update.sh

# 2. Bake the new kernel RPM with the patch + kernel-config delta applied
scripts/v620-kernel-bake.sh --build-dir <DEST> --buildid .p2p \
    --patch patches/v620-powercap-min-120W.patch

# 3. Validate the resulting RPM (patch applied, Kconfig delta present)
scripts/v620-validate-kernel-rpm.sh <PATH-TO-RPM>

# 4. Install + reboot (separate decision after human review)
sudo rpm -Uvh --replacepkgs <DEST>/x86_64/kernel-*.rpm
sudo grubby --set-default /boot/vmlinuz-<NEW-EVR>
sudo reboot
```

No auto-rebuild, no scheduled timer, no auto-install. The operator
reviews the bake log + validation output before deciding to install.

## License

GPL-3 (see [`../LICENSE`](../LICENSE)). The kernel patches here are
derivative works of the Linux kernel source (`drivers/gpu/drm/amd/pm/swsmu/smu11/sienna_cichlid_ppt.c`)
and inherit GPL-2.0 from upstream — see [`../NOTICE`](../NOTICE) for per-file licensing.