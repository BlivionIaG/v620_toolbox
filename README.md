# v620_toolbox

A guide per feature for the AMD Radeon PRO V620 (gfx1030) on Fedora + AMD CPU:

| Folder | Feature | Status |
|---|---|---|
| [`pcie_p2p/`](pcie_p2p/) | GPU↔GPU PCIe Peer-to-Peer (P2P) aperture | ✅ validated on Fedora 43, kernels 6.17.6 (pre-7) + 7.1.7 (post-7) |
| [`powertuning/`](powertuning/) | Lower V620 power cap to 120 W floor + 180 W boot cap | ✅ validated on Fedora 43, same kernel matrix |

Each feature has its own `README.md` with the full recipe, prerequisites, and verification steps. Follow them in either order.

# V620 Power Tuning — Standalone Guide

Make the AMD Radeon PRO V620 (gfx1030) power-cap adjustable:
lower the floor from the VBIOS-locked 250 W to 120 W, then set a
180 W cap at boot. Everything you need is in this file — no external
scripts.

The V620's VBIOS declares **250 W as its minimum power limit**. The
amdgpu kernel driver trusts that number, so any lower setting is
rejected:

```bash
echo 180000000 | sudo tee /sys/class/hwmon/hwmonX/power1_cap
# -> Invalid argument
```

The card's SMU firmware actually accepts values down to 120 W — the
**kernel** is the only thing in the way.

## The fix

A small kernel patch to one amdgpu function
(`sienna_cichlid_get_power_limit()` in
`drivers/gpu/drm/amd/pm/swsmu/smu11/sienna_cichlid_ppt.c`). When the GPU
matches the V620 reference board (PCI `1002:73a1`, subsystem
`1002:0e34`), the kernel's reported minimum is clamped to 120 W before
userspace sees it. It works on any kernel ≥ 5.15 and any number of
V620s in the host. It does **not** touch the VBIOS, `pp_table`, or
`pp_features`.

Save this as `v620-powercap.patch`:

```diff
--- a/drivers/gpu/drm/amd/pm/swsmu/smu11/sienna_cichlid_ppt.c
+++ b/drivers/gpu/drm/amd/pm/swsmu/smu11/sienna_cichlid_ppt.c
@@ -624,6 +624,18 @@
 	return od_table->cap[cap];
 }

+static noinline void sienna_cichlid_v620_min_powercap_fix(
+	struct smu_context *smu, uint32_t *min_power_limit)
+{
+	/* *min_power_limit is in WATTS here; hwmon scales to uW for sysfs. */
+	if (*min_power_limit > 120U) {
+		*min_power_limit = 120U;
+		dev_notice(smu->adev->dev,
+			   "V620 powerfix: allowing PPT limit down to 120 W on %s\n",
+			   dev_name(smu->adev->dev));
+	}
+}
+
 static int sienna_cichlid_get_power_limit(struct smu_context *smu,
 					  uint32_t *current_power_limit,
 					  uint32_t *default_power_limit,
@@ -670,6 +682,27 @@
 	if (min_power_limit) {
 		*min_power_limit = power_limit * (100 - od_percent_lower);
 		*min_power_limit /= 100;
+
+		/*
+		 * V620 powerfix: clamp the minimum PPT limit from the
+		 * VBIOS-declared 250 W to 120 W on Radeon PRO V620 so userspace
+		 * can power-cap below 250 W.
+		 *
+		 * Match is on PCI subsystem_device 0x0e34 — uniquely identifies
+		 * the AMD V620 reference board, machine-independent.
+		 */
+		if (smu->adev->pdev->vendor == 0x1002 &&
+		    smu->adev->pdev->device == 0x73a1 &&
+		    smu->adev->pdev->subsystem_vendor == 0x1002 &&
+		    smu->adev->pdev->subsystem_device == 0x0e34)
+			sienna_cichlid_v620_min_powercap_fix(smu, min_power_limit);
 	}
 	return 0;
 }
```

## Step 1 — Build and install the patched amdgpu module

This builds a patched `amdgpu.ko` against your **running** kernel and
installs it as an override. Re-run after every kernel update.

```bash
# Prerequisites
sudo dnf install kernel-devel-$(uname -r) gcc make git xz tar binutils

# Get the kernel source tarball matching your running kernel's BASE
# version (e.g. 7.1.7-200.fc43.x86_64 -> linux-7.1.7.tar.xz) from
# https://www.kernel.org/ — only the amdgpu subtree is needed:
KVER=$(uname -r | cut -d- -f1)
mkdir -p ~/v620-build
tar -xJf linux-$KVER.tar.xz -C ~/v620-build linux-$KVER/drivers/gpu/drm/amd
cd ~/v620-build/linux-$KVER

# Apply the patch (the file you saved above)
git apply /path/to/v620-powercap.patch || patch -p1 < /path/to/v620-powercap.patch

# Fedora's kernel-devel ships an incomplete drivers/ mirror; copy the
# trace header the build needs:
sudo mkdir -p /usr/src/kernels/$(uname -r)/drivers/gpu/drm/amd/amdgpu
sudo cp drivers/gpu/drm/amd/amdgpu/amdgpu_trace.h \
        /usr/src/kernels/$(uname -r)/drivers/gpu/drm/amd/amdgpu/

# Build just the amdgpu module (~5-10 min)
make -C /lib/modules/$(uname -r)/build M=$PWD/drivers/gpu/drm/amd/amdgpu \
     -j$(nproc) amdgpu.ko

# Sanity check: the fix must be inside the built module
nm drivers/gpu/drm/amd/amdgpu/amdgpu.ko | grep sienna_cichlid_v620_min_powercap_fix

# Install as an override and make depmod prefer it
sudo install -m 0644 drivers/gpu/drm/amd/amdgpu/amdgpu.ko \
     /lib/modules/$(uname -r)/extra/amdgpu.ko
echo 'search extra updates built-in kernel' | sudo tee /etc/depmod.d/00-v620.conf
sudo depmod -a
modinfo -F filename amdgpu    # must show .../extra/amdgpu.ko

# Rebuild the initramfs so the patched module loads at boot
sudo cp -n /boot/initramfs-$(uname -r).img /boot/initramfs-$(uname -r).img.pre-v620fix.bak
sudo dracut --force
sudo reboot
```

Note: if Secure Boot is enabled, the unsigned module will be refused —
either sign it (mokutil) or disable Secure Boot.

## Step 2 — Apply a 180 W cap at boot

The patch only lowers the *floor*; nothing sets a cap yet. Install this
small script as `/usr/local/sbin/v620-cap-apply.sh` (it must live outside
your home directory — SELinux blocks systemd from running `user_home_t`
scripts):

```bash
#!/usr/bin/env bash
# v620-cap-apply.sh [WATTS] — write a power cap to every V620 (default 180).
W="${1:-180}"; UW=$((W * 1000000))
for i in $(seq 1 30); do            # wait up to 60 s for amdgpu hwmon
  found=0
  for h in /sys/class/hwmon/hwmon*; do
    [ -f "$h/name" ] && grep -qi amdgpu "$h/name" || continue
    d="$(readlink -f "$h/device")"
    [ "$(cat "$d/device" 2>/dev/null)"           = "0x73a1" ] || continue
    [ "$(cat "$d/subsystem_device" 2>/dev/null)" = "0x0e34" ] || continue
    echo "$UW" > "$h/power1_cap" 2>/dev/null && found=1
  done
  [ "$found" = 1 ] && { echo "v620-cap-apply: ${W} W applied"; exit 0; }
  sleep 2
done
echo "v620-cap-apply: no V620 found" >&2; exit 1
```

And this systemd unit as `/etc/systemd/system/v620-powercap.service`:

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

Then:

```bash
sudo chmod 755 /usr/local/sbin/v620-cap-apply.sh
sudo systemctl daemon-reload
sudo systemctl enable --now v620-powercap.service
```

Want a different wattage? Any value 120–250 works — change `180` in the
unit's `ExecStart`, or run `sudo /usr/local/sbin/v620-cap-apply.sh 170`
for a one-off.

## Step 3 — Keep dnf from wiping the fix

A kernel update replaces the module you just installed. Pin the kernel
packages by adding to `/etc/dnf/dnf.conf`:

```ini
exclude=kernel kernel-core kernel-modules kernel-modules-core kernel-tools kernel-tools-libs
```

When you *do* move to a new kernel on purpose, re-run Step 1 against it.

## Test

```bash
# 1. The patch fired — one line per V620:
dmesg | grep "V620 powerfix"
# -> V620 powerfix: allowing PPT limit down to 120 W on 0000:XX:00.0

# 2. The floor is 120 W on every card:
for h in /sys/class/hwmon/hwmon*/power1_cap_min; do echo "$h: $(cat $h)"; done
# -> 120000000 on each V620 hwmon

# 3. The boot cap is 180 W:
for h in /sys/class/hwmon/hwmon*/power1_cap; do echo "$h: $(cat $h)"; done
# -> 180000000 on each V620 hwmon

# 4. A write inside the range works:
echo 150000000 | sudo tee /sys/class/hwmon/hwmonX/power1_cap    # accepted

# 5. A write below the floor is still refused (floor is enforced):
echo 110000000 | sudo tee /sys/class/hwmon/hwmonX/power1_cap    # -> EINVAL
```

If check 1 shows nothing, the patched module isn't loaded — re-check
`modinfo -F filename amdgpu` points at `/extra/` and that the initramfs
was rebuilt.

## Rollback

```bash
sudo rm /lib/modules/$(uname -r)/extra/amdgpu.ko
sudo depmod -a
sudo dracut --force
sudo systemctl disable --now v620-powercap.service   # optional
sudo reboot
```

## Safety note

Never write `pp_table` or `pp_features` on a V620 — that wedges the SMU
with no FLR recovery; only a cold power cycle (PSU off ≥ 10 s) brings
the card back. This guide never touches those knobs: the patch only
changes what the kernel *reports* as the minimum.

## License

GPL-3 (see [LICENSE](LICENSE)). Kernel patches in `powertuning/patches/` are derivative works of the Linux kernel source (GPL-2.0); see [NOTICE](NOTICE) for per-file licensing.

## Repo conventions

See [AGENTS.md](AGENTS.md) for what belongs where, what "validated" means, and how to extend a feature.
