# AGENTS — conventions for this repo

This document is for AI agents and humans editing `v620_toolbox/`.
For per-feature rules (Don't-do-X, validation criteria, extension
patterns), see the AGENTS.md inside each feature folder.

## What this repo is

A **per-feature guide** for the AMD Radeon PRO V620 (gfx1030) on Fedora
+ AMD CPU. Two features are documented as independent guides:

- `pcie_p2p/` — enabling GPU↔GPU PCIe Peer-to-Peer (kernel-config delta
  + pre-gfx1030 ASIC removal (per-host) + verification). The full check
  sequence is `pcie_p2p/README.md` §"Verify".
- `powertuning/` — lowering the V620 power cap to 120 W floor + 180 W
  boot cap. Patches, scripts, systemd unit live here.

The validated end-to-end stack requires **both** features.

## What goes where

| Concern | Lives in |
|---|---|
| Kernel-config delta (the 3 `CONFIG_*=y` flags) | `pcie_p2p/README.md` (referenced by `powertuning/scripts/v620-kernel-bake.sh`) |
| V620 powercap patches | `powertuning/patches/` |
| `v620-cap-apply.sh` (180 W boot-cap writer) | `powertuning/scripts/` |
| `v620-powercap.service` (systemd unit) | `powertuning/systemd/` |
| `v620-kernel-bake.sh` (RPM build wrapper) | `powertuning/scripts/` (referenced by `pcie_p2p/`) |
| `verify-p2p.sh` (P2P-specific check runner) | `pcie_p2p/scripts/` |

If a feature needs a script from the other feature, reference it via
`../<other-feature>/scripts/<script>`. **Do not duplicate** — the
duplication creates drift over time.

## Adding a new feature

1. Create a new top-level folder: `<feature>/` with its own `README.md`
   and `AGENTS.md`. Add `docs/`, `scripts/`, etc. as needed.
2. Reference shared scripts from other features via relative paths.
3. Document the feature's validated scope in its own `README.md`
   Status table.
4. Add a row to the top-level [`README.md`](README.md) table.