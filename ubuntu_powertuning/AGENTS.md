# AGENTS — conventions for this feature guide

This document is for AI agents working in `ubuntu_powertuning/`. Humans can
skim it; the bulk is "what NOT to do, and why."

## What this guide is

Ubuntu 26.04 support for the same V620 powercap goal as
[`../powertuning/`](../powertuning/): lower the kernel-reported minimum from
250 W to **120 W**, then apply a **180 W** boot cap.

Ubuntu-specific pieces live here (`v620-rebuild-amdgpu`, README, kernel hook).
Shared pieces are **referenced**, not copied:

| Concern | Lives in |
|---|---|
| `v620-cap-apply.sh` (180 W boot-cap writer) | [`../powertuning/scripts/`](../powertuning/scripts/) |
| `v620-powercap.service` (systemd unit) | [`../powertuning/systemd/`](../powertuning/systemd/) |
| `v620-verify.sh` (post-patch verification) | [`../powertuning/scripts/`](../powertuning/scripts/) |
| Kernel patch intent (Fedora unified diff) | [`../powertuning/patches/`](../powertuning/patches/) |

The Ubuntu rebuild script applies the same logic via **anchored Python edits**
to `sienna_cichlid_ppt.c` (more reliable than the malformed unified diff in
`powertuning/patches/v620-powercap-min-120W.patch` on some tooling).

## Hard rules for agents

Same safety rules as [`../powertuning/AGENTS.md`](../powertuning/AGENTS.md):

1. **Do NOT write `pp_table` or `pp_features`.** Cold power cycle only recovery.
2. **Do NOT broaden the PCI-ID match** beyond V620 reference board
   (`1002:73a1` / subsystem `1002:0e34`) without re-validation on hardware.
3. **Do NOT duplicate** `v620-cap-apply.sh` or the systemd unit — reference
   `../powertuning/` paths.

## What "validated" means here

See the Status table in [`README.md`](README.md). Re-run
[`../powertuning/scripts/v620-verify.sh`](../powertuning/scripts/v620-verify.sh)
after any change to the rebuild script or source anchors.

## How to extend

- If Ubuntu kernel source moves anchors in `sienna_cichlid_ppt.c`, update the
  Python `old1`/`old2` strings in `v620-rebuild-amdgpu` and re-test on hardware.
- If the cap script or systemd unit needs changes, edit
  [`../powertuning/`](../powertuning/) first, then re-verify here.
- Add a row to the top-level [`../README.md`](../README.md) table when scope
  changes.
