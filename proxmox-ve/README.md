# v620-toolbox-proxmox

Proxmox VE 9.x port of [dealcracker/v620_toolbox](https://github.com/dealcracker/v620_toolbox)
(originally documented against Fedora at
[BlivionIaG/v620_toolbox](https://github.com/BlivionIaG/v620_toolbox)) —
tooling for the AMD Radeon PRO V620 on a host used for GPU compute.

Laid out the same way as the upstream repo: one subfolder per feature,
each independently installable, plus this top-level overview.

## Contents

| Folder | Ports | Status |
|---|---|---|
| [`proxmox-ve-powertuning/`](proxmox-ve-powertuning/README.md) | Lower the V620's power-cap floor from the VBIOS-locked 250 W to 120 W, then set a boot-time cap (default 180 W) | Fully self-maintaining via DKMS — survives kernel updates automatically |
| [`proxmox-pcie-p2p/`](proxmox-pcie-p2p/README.md) | Kernel-level PCIe Peer-to-Peer between V620 cards | Auto-detects whether your kernel already qualifies (expected on stock Proxmox VE 9.x); falls back to a guided custom-kernel build otherwise |

Install `proxmox-ve-powertuning/` first — `proxmox-pcie-p2p/` depends on
it (same patch, same boot service).

## Why this differs from the upstream repo, in one sentence per folder

- **powertuning**: upstream manually rebuilds `amdgpu.ko` and hand-pins
  it with a `dnf exclude=`; this port packages the same patch as a DKMS
  module, so `proxmox-kernel-*` updates rebuild it automatically instead
  of needing to be blocked.
- **pcie_p2p**: upstream rebuilds the *entire kernel* (Fedora SRPM) to
  bake in `CONFIG_HSA_AMD_P2P`/`CONFIG_PCI_P2PDMA`; on Proxmox VE 9.x
  those are very likely compiled in already (Ubuntu ≥24.04 default), so
  this port checks first and only asks for a custom kernel build if that
  check actually fails.

## Hardware / software this targets

- AMD Radeon PRO V620 (device `1002:73a1`, subsystem `1002:0e34`)
- Proxmox VE 9.x (kernel series 6.17.x / 7.0.x+, tracking Ubuntu 26.04)
- `proxmox-default-headers` (or the matching `proxmox-headers-<series>`
  for an opt-in kernel series)

See each subfolder's README for full prerequisites, install steps,
verification, and troubleshooting.

## Safety note

Never write `pp_table` or `pp_features` on a V620 — that can wedge the
SMU with no FLR recovery; only a cold power cycle (PSU off ≥ 10 s)
brings the card back. Neither module here touches those knobs.
