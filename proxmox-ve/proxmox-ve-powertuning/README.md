# v620-powertuning (Proxmox VE 9.x port)

Ports the [v620_toolbox](https://github.com/dealcracker/v620_toolbox) power-cap
fix (lower the AMD Radeon PRO V620's power-cap floor from the VBIOS-locked
250 W to 120 W, then set a boot-time cap) from the Fedora/manual-rebuild
workflow to a self-maintaining **DKMS** package for Proxmox VE 9.x.

Unlike the upstream guide, you do **not** need to re-run anything by hand
after a kernel update: `dkms autoinstall` (wired into
`proxmox-kernel-*`'s postinst, same as any other DKMS module) rebuilds and
reinstalls the patched `amdgpu.ko` automatically, then `REMAKE_INITRD=yes`
regenerates the initramfs.

## What's different from the upstream Fedora guide

| Upstream (Fedora, manual) | This port (Proxmox, DKMS) |
|---|---|
| `kernel-devel-$(uname -r)` | `proxmox-default-headers` (or `proxmox-headers-<series>` / `pve-headers-<series>` for opt-in kernels) |
| Manual `tar -xJf` + `git apply`/`patch`, manual `make -C ... M=...` | DKMS `PRE_BUILD` script (`pre-build.sh`) fetches the matching upstream `drivers/gpu/drm/amd` tree and patches it automatically, every build |
| Manual `install` into `/lib/modules/.../extra/` + a `/etc/depmod.d/00-v620.conf` override, because Fedora's default `depmod` search order doesn't prefer overrides | Not needed: Debian/Ubuntu/Proxmox's default `depmod` search order already puts `updates/dkms/` ahead of the in-kernel module, so plain `dkms install` overrides `amdgpu` correctly |
| Manual `dracut --force` after every kernel bump | `REMAKE_INITRD="yes"` in `dkms.conf` triggers `update-initramfs` automatically |
| `exclude=kernel...` pin in `dnf.conf` to stop updates from wiping the fix | Not needed — the fix now *survives* kernel updates instead of blocking them |
| No initramfs hook | `hooks/v620_powertuning` + `scripts/init-premount/v620_powertuning` added per your request (see below — normally a no-op on Proxmox) |

## Layout

```
dkms.conf                                          # DKMS module definition
pre-build.sh                                        # fetches + patches upstream amd/ tree per kernel
patches/v620-powercap.patch                          # unchanged upstream patch
usr-local-sbin/v620-cap-apply.sh                      # applies the boot-time cap
etc-systemd-system/v620-powercap.service              # runs the above at boot
etc-default/v620-powertuning                          # WATTS=, optional offline source overrides
initramfs-tools/hooks/v620_powertuning                # ensures patched module is used if amdgpu is early-KMS
initramfs-tools/scripts/init-premount/v620_powertuning# optional early cap application (disabled by default)
install.sh / uninstall.sh
```

## Why an initramfs hook at all?

On a typical Proxmox host, `amdgpu` is **not** required in the initramfs —
root isn't on the V620, and there's no early-KMS dependency. `dkms.conf`'s
`REMAKE_INITRD="yes"` already keeps the initramfs's *module list*
consistent after every build, which is normally all you need.

The two files under `initramfs-tools/` exist because you asked for them,
and are useful in one specific case: if you've explicitly configured
early-KMS for `amdgpu` (added it to `/etc/initramfs-tools/modules`, or
`MODULES=most`), the hook makes sure it's *this patched* module that gets
copied in, plus firmware. The `init-premount` script goes further and can
apply the power cap before the root filesystem is even mounted; it's
off by default (`EARLY_CAP=no`) since `v620-powercap.service` covers the
normal case, and turning it on requires copying
`/etc/default/v620-powertuning` into the initramfs yourself as
`/conf/v620-powertuning.conf` (not done automatically, to avoid baking
stale config into every initramfs rebuild) — happy to wire that up too if
you actually need it.

## Install

```bash
cd proxmox-ve-powertuning
sudo ./install.sh
```

This will:
1. Install `proxmox-default-headers`, `dkms`, `build-essential`, `patch`,
   `curl` if missing.
2. Register and build the DKMS module for the **running** kernel — which
   downloads the matching upstream `linux-<base-version>.tar.xz` from
   `cdn.kernel.org`, extracts just `drivers/gpu/drm/amd`, and applies the
   patch. (Air-gapped host? Pre-stage a tarball or extracted tree and set
   `AMD_SRC_TARBALL=`/`AMD_SRC_DIR=` in `/etc/default/v620-powertuning`
   first — see that file's comments.)
3. Install the module via `dkms install`, which overrides the in-tree
   `amdgpu` automatically.
4. Enable `v620-powercap.service` (180 W default; edit `WATTS=` in
   `/etc/default/v620-powertuning` for a different cap, 120–250).

Reboot afterward so the new initramfs / module is definitely what's active.

## If you're on an opt-in kernel series (e.g. 7.0 while 6.17 is default)

Install the matching headers explicitly before running `install.sh`:

```bash
apt install proxmox-headers-7.0
```

`proxmox-default-headers` only tracks whichever series is currently the
*default*.

## Test

Same checks as upstream:

```bash
dmesg | grep "V620 powerfix"
# -> V620 powerfix: allowing PPT limit down to 120 W on 0000:XX:00.0

for h in /sys/class/hwmon/hwmon*/power1_cap_min; do echo "$h: $(cat "$h")"; done
# -> 120000000 on each V620 hwmon

for h in /sys/class/hwmon/hwmon*/power1_cap; do echo "$h: $(cat "$h")"; done
# -> 180000000 (or your configured WATTS) on each V620 hwmon

dkms status
# -> v620-powertuning/1.0, <kernelver>, x86_64: installed
```

## After a kernel update

Nothing to do. `apt install proxmox-kernel-<new-version>` (or the normal
Proxmox kernel update path) invokes `dkms autoinstall` via the kernel
package's postinst, which runs `pre-build.sh` again for the new kernel,
rebuilds, reinstalls, and regenerates that kernel's initramfs. Check
`dkms status` after the update if you want to confirm.

## Troubleshooting

- **Patch fails to apply / build fails for a specific kernel base
  version.** The patch targets a specific line range in
  `sienna_cichlid_ppt.c`; if upstream (or Ubuntu's patch set, which
  Proxmox kernels track around the 26.04/Resolute base) has moved things
  around, `pre-build.sh`'s `patch -p1` step will fail with a clear error
  and `dkms build` will report it. Check
  `/var/lib/dkms/v620-powertuning/1.0/build/make.log` and the patch
  rejects; usually just a context-line offset, fixable by re-fetching the
  `.orig`/`.rej` diff for that specific base version and adjusting
  `patches/v620-powercap.patch`.
- **`amdgpu_trace.h` missing errors.** Same root cause as the Fedora
  guide — the headers package ships an incomplete `drivers/` mirror.
  `pre-build.sh` copies it in automatically; if it still fails, check
  `/usr/src/linux-headers-$(uname -r)/drivers/gpu/drm/amd/amdgpu/` exists
  and is writable.
- **Secure Boot.** As upstream: an unsigned DKMS module will be refused.
  Either enroll a MOK key for DKMS-signed modules (`dkms` on Debian can
  do this via `mokutil`) or disable Secure Boot.
- **No internet on the host.** Pre-stage
  `linux-<base>.tar.xz` (or an already-extracted tree) and point
  `AMD_SRC_TARBALL=` / `AMD_SRC_DIR=` at it in
  `/etc/default/v620-powertuning` before building.

## Rollback

```bash
sudo ./uninstall.sh
sudo reboot
```

Removes the DKMS module (falling back to the in-tree `amdgpu`), the
service, and the initramfs hook/script, then rebuilds the initramfs.

## Safety note (unchanged from upstream)

Never write `pp_table` or `pp_features` on a V620 — that can wedge the SMU
with no FLR recovery; only a cold power cycle (PSU off ≥ 10 s) brings the
card back. Nothing here touches those knobs — only what the kernel
*reports* as the minimum power limit.

## PCIe P2P (GPU↔GPU)

That's a separate module — see [`../proxmox-pcie-p2p/`](../proxmox-pcie-p2p/README.md)
one level up. It reuses this module's patch and service (installed above)
as a dependency, so install this one first.
