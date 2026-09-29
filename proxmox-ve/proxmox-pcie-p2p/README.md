# v620 PCIe P2P (Proxmox VE 9.x port)

Ports the `pcie_p2p` feature from `v620_toolbox` — kernel-level PCIe
Peer-to-Peer between Radeon PRO V620 cards — to Proxmox VE 9.x.

**Read this before the upstream repo's guide**, because the port is
structurally different from a straight copy:

## Why this isn't a copy of the Fedora recipe

The upstream guide's core move is rebuilding the *entire kernel* (via a
Fedora SRPM) to bake in two kernel-level config options:

- `CONFIG_PCI_P2PDMA=y` — core PCI P2P DMA infrastructure (`drivers/pci/`)
- `CONFIG_HSA_AMD_P2P=y` — amdkfd's P2P support (`drivers/gpu/drm/amd/amdkfd/Kconfig`, depends on the above)

Both are **bool**, not tristate, Kconfig symbols — meaning they're
compiled directly into `vmlinuz` itself, not into a loadable module.
That's exactly why the upstream guide rebuilds the whole kernel instead
of just `amdgpu.ko`: DKMS (which is how the power-cap fix is delivered)
can only build *additional* modules against a kernel's *existing*
exported symbols — it can't retroactively add core infrastructure that
wasn't compiled into the kernel image in the first place.

**The good news:** Proxmox VE 9.x kernels track Ubuntu (26.04 base per
Proxmox's own announcements), and Ubuntu ≥24.04 ships
`CONFIG_HSA_AMD_P2P=y` by default on its host-facing kernels. So on a
stock Proxmox VE 9.x install, the expensive part of the upstream guide
is very likely **already done for you**. This port checks that
directly instead of assuming it, and only asks you to do a custom
kernel build if the check comes back negative.

## What's ported, and how

| Upstream guide | This port |
|---|---|
| Fedora SRPM rebuild for `CONFIG_HSA_AMD_P2P`/`CONFIG_PCI_P2PDMA`/`CONFIG_DMABUF_MOVE_NOTIFY` | `scripts/v620-p2p-preflight.sh` checks `/boot/config-$(uname -r)` first. If already `=y` (**light path**, expected on stock Proxmox VE 9.x): nothing to rebuild. If not (**heavy path**): `heavy-kernel-build.sh` walks you through Proxmox's own kernel packaging (`git.proxmox.com/pve-kernel`) to add the same config delta — see below for why this step is guided rather than fully automated |
| `v620-powercap-min-120W.patch` applied during the kernel bake | Already handled — this is the identical patch the `v620-powertuning` DKMS module (in `..`) installs. No new patch needed; `install-p2p.sh` just checks that module is present |
| No pre-gfx1030 AMD GPU in host | Same check, in `v620-p2p-preflight.sh` |
| `amdgpu` module param `pcie_p2p=1` | `etc-modprobe.d/v620-p2p.conf` |
| dnf exclude= lock against updates reverting the kernel | Not applicable the same way — DKMS (light path) survives kernel updates on its own; heavy-path custom kernels need `apt-mark hold proxmox-kernel-* proxmox-headers-*` (noted below) since there's no DKMS-style auto-rebuild for a whole custom kernel |
| Verify (kernel config, hardware, powercap, KFD topology, `amd-smi topology`, `rocminfo`, module params) | `scripts/verify-p2p.sh`, aligned section-for-section with upstream's own `verify-p2p.sh` (installed as `/usr/local/sbin/v620-verify-p2p.sh`). The `.p2p` buildid / dnf-exclude checks are swapped for a kernel-version + DKMS-status check, since Proxmox has neither convention. ROCm-dependent checks (`amd-smi`, `rocminfo`) are skipped with a note, not counted as failures, if ROCm isn't installed at `$ROCM_HOME` (default `/opt/rocm`) |

## Why the heavy-path config-delta step is manual

Proxmox applies kernel config deltas via flags (`-e CONFIG_X`,
`-d CONFIG_Y`) somewhere in `debian/rules`, per their own README and
forum build tutorials — but the exact target name has moved between
Proxmox major versions as their packaging has evolved. Auto-editing
`debian/rules` with a guessed `sed` pattern risks silently producing
either a build failure or, worse, a kernel that builds fine but
*doesn't* actually carry the config change (which you'd only discover
after a full multi-hour rebuild and reboot). `heavy-kernel-build.sh`
does everything mechanical (clone, submodule fetch, build-deps, the
actual `dpkg-buildpackage` build) and pauses with clear instructions at
the one step that needs you to confirm the current syntax against the
README in your specific checkout.

## Install (light path — expected case on Proxmox VE 9.x)

```bash
cd proxmox-ve-powertuning
sudo ./install.sh              # if you haven't already — P2P reuses this module
cd ../proxmox-pcie-p2p
sudo ./scripts/v620-p2p-preflight.sh
# -> if it prints "RESULT: LIGHT PATH", continue:
sudo ./install-p2p.sh
sudo reboot
sudo v620-verify-p2p.sh
```

## If preflight reports the heavy path

```bash
cd proxmox-pcie-p2p
sudo ./heavy-kernel-build.sh          # builds against the default branch;
                                       # pass a specific branch/tag to match
                                       # your Proxmox VE series if needed
# follow its prompt, then:
sudo dpkg -i /root/build/pve-kernel-v620-p2p/proxmox-kernel-*.deb \
             /root/build/pve-kernel-v620-p2p/proxmox-headers-*.deb
sudo apt-mark hold 'proxmox-kernel-*' 'proxmox-headers-*'   # nothing auto-rebuilds a custom kernel
sudo reboot
sudo ./scripts/v620-p2p-preflight.sh   # should now report LIGHT PATH
sudo ./install-p2p.sh
sudo reboot
sudo v620-verify-p2p.sh
```

Re-run `heavy-kernel-build.sh` against each new upstream tag if you
want to keep taking Proxmox kernel updates — there's no DKMS-style
auto-rebuild for a whole custom kernel; that's the real cost of the
heavy path, same as it is in the upstream Fedora guide (their `exclude=`
dnf pin exists for the identical reason).

## Hardware notes carried over from upstream

- No pre-gfx1030 AMD GPU (device `0x6XXX`) may be present in the host —
  ROCm 7.x's `libhsakmt` will fail KFD registration for the V620s too
  if one is. Power off and physically remove it first.
- P2P topology needs ≥2 V620 cards (subsystem `1002:0e34`) to test
  anything; the upstream guide's numbers (12/12 links, etc.) assume 4.
- This targets **host-level** P2P (bare-metal Proxmox, or an LXC using
  the host's GPUs directly). PCIe P2P routed through a QEMU VM's
  emulated PCIe topology is a materially different — and harder —
  problem (ACS/root-port routing through an emulated host bridge isn't
  the same as bare metal), and isn't covered by this port.

## Not covered

ROCm userspace install, `amd-smi`/`rocminfo` themselves (only their use
as verification tools is referenced) — same scope boundary as the
upstream guide, which also only covers the kernel-side wall.
