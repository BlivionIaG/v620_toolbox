# AGENTS — conventions for this repo

This document is for AI agents and humans editing `v620_toolbox/`.
For per-feature rules (Don't-do-X, validation criteria, extension
patterns), see the AGENTS.md inside each feature folder.

## What this repo is

A **per-feature guide** for the AMD Radeon PRO V620 (gfx1030) on Fedora
+ AMD CPU. Three feature guides ship as independent folders:

- `pcie_p2p/` — enabling GPU↔GPU PCIe Peer-to-Peer (kernel-config delta
  + pre-gfx1030 ASIC removal (per-host) + verification). The full check
  sequence is `pcie_p2p/README.md` §"Verify".
- `powertuning/` — lowering the V620 power cap to 120 W floor + 180 W
  boot cap. Patches, scripts, systemd unit live here.
- `ubuntu_powertuning/` — same powercap goal on **Ubuntu 26.04**
  (out-of-tree `amdgpu` rebuild; see [`ubuntu_powertuning/README.md`](ubuntu_powertuning/README.md)).

The validated end-to-end stack on Fedora requires **both** `pcie_p2p/` and
`powertuning/`. Ubuntu powercap is independent of the Fedora P2P stack.

## What goes where

| Concern | Lives in |
|---|---|
| Kernel-config delta (the 3 `CONFIG_*=y` flags) | `pcie_p2p/README.md` (referenced by `powertuning/scripts/v620-kernel-bake.sh`) |
| V620 powercap patches | `powertuning/patches/` |
| `v620-cap-apply.sh` (180 W boot-cap writer) | `powertuning/scripts/` |
| `v620-powercap.service` (systemd unit) | `powertuning/systemd/` |
| `v620-kernel-bake.sh` (RPM build wrapper) | `powertuning/scripts/` (referenced by `pcie_p2p/`) |
| `verify-p2p.sh` (P2P-specific check runner) | `pcie_p2p/scripts/` |
| Ubuntu `v620-rebuild-amdgpu` | `ubuntu_powertuning/` |
| Shared `v620-cap-apply.sh` (used by Ubuntu + Fedora) | `powertuning/scripts/` |

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

## Cursor Cloud specific instructions

This repo is a Bash-script + kernel-patch + docs toolbox. There is **no
application server, build system, or language package manager** — the
"product" is the scripts in `*/scripts/`, `ubuntu_powertuning/`, and the
patch in `powertuning/patches/`. The validated target is **Fedora + a physical
AMD Radeon PRO V620 (gfx1030)**; the Cloud VM is **Ubuntu with no GPU**,
so scripts are linted and read-only diagnostics run but correctly report
"no V620".

Dev toolchain (installed by the environment update script): `shellcheck`
(the intended linter — scripts carry `# shellcheck source=lib/common.sh`
directives) and `pciutils` (`lspci`, used by the diagnostics). Plain
`bash`, `git`, and `patch` are already present.

- **Lint:** `bash -n <script>` for syntax; `shellcheck -x <script>` for
  static analysis. Always pass `-x` so ShellCheck follows the
  `source .../lib/common.sh` line (otherwise you get spurious SC1091 +
  SC2034 on the shared-helper vars). Remaining findings are pre-existing
  advisories (info/style), not errors.
- **Run (safe anywhere):** `powertuning/scripts/v620-verify.sh` (no-ops
  and exits 0 when no V620 is present), `pcie_p2p/scripts/verify-p2p.sh`
  (8-check PASS/FAIL summary), and `powertuning/scripts/v620-p2p-readiness.sh`
  (four-gate diagnostic). On a non-V620 host they report FAIL/WARN by
  design; a non-zero exit just reflects the FAIL count.
- **Gotcha:** `v620-p2p-readiness.sh` runs under `set -euo pipefail`; on
  hosts without `/sys/class/kfd` (i.e. this Cloud VM) it exits before
  printing its `=== Summary ===` because the kfd `p2p_links` scan trips
  `pipefail`. The per-gate `[PASS]/[FAIL]/[WARN]` lines above are still
  the real output. Use `verify-p2p.sh` (which runs under `set +e`) when
  you want a full summary here.
- **Cannot run in Cloud:** `v620-kernel-bake.sh` and
  `v620-module-install.sh` need Fedora kernel dist-git + `kernel-devel` +
  the physical V620. `ubuntu_powertuning/v620-rebuild-amdgpu` needs Ubuntu
  `linux-source` + a `*-generic` kernel + V620 hardware. End-to-end kernel
  builds are out of scope on this GPU-less VM.