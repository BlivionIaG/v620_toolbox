# Ubuntu 26.04 Radeon Pro V620 Power Tuning

This directory contains Ubuntu 26.04 support for the Radeon Pro V620
power-tuning modification. It patches the Ubuntu `amdgpu` module so the
V620 can expose a minimum power cap of **120 W**, and includes a helper
script for applying a **180 W** power cap.

> **Important:** Keep at least one known-good older Ubuntu kernel
> installed as a GRUB fallback. Kernel updates can change AMDGPU source
> code and may require the patch/rebuild logic to be updated.

## Clone the repository

``` bash
git clone https://github.com/BlivionIaG/v620_toolbox.git
cd v620_toolbox/ubuntu_powertuning
```

## 1. Check the kernel and Secure Boot

Run:

``` bash
uname -r
mokutil --sb-state
```

You want a normal Ubuntu generic kernel such as:

``` text
7.0.0-30-generic
```

If Secure Boot is enabled, the unsigned replacement module will not
load. Either disable Secure Boot in BIOS/UEFI or sign the module before
installation.

## 2. Install build dependencies

``` bash
sudo apt update

sudo apt install \
    build-essential \
    linux-headers-$(uname -r) \
    linux-source \
    git \
    bc \
    flex \
    bison \
    libssl-dev \
    libelf-dev \
    dwarves \
    zstd
```

## 3. Make sure the installed source matches the running kernel series

Check:

``` bash
uname -r
apt-cache policy linux-source
ls -lh /usr/src/
```

For a kernel like:

``` text
7.0.0-30-generic
```

you should have a source archive similar to:

``` text
/usr/src/linux-source-7.0.0/linux-source-7.0.0.tar.bz2
```

The running kernel and installed Ubuntu source must be from the same
kernel source series.

## 4. Install the Ubuntu V620 scripts

From the repository's `ubuntu_powertuning` directory, install both
scripts into `/usr/local/sbin/`:

``` bash
sudo cp v620-rebuild-amdgpu /usr/local/sbin/
sudo cp v620-cap-apply.sh /usr/local/sbin/

sudo chmod 755 /usr/local/sbin/v620-rebuild-amdgpu
sudo chmod 755 /usr/local/sbin/v620-cap-apply.sh
```

Verify:

``` bash
ls -l /usr/local/sbin/v620-rebuild-amdgpu
ls -l /usr/local/sbin/v620-cap-apply.sh
```

## 5. Build and install the patched AMDGPU module

Run the rebuild script against the currently running kernel:

``` bash
sudo /usr/local/sbin/v620-rebuild-amdgpu "$(uname -r)"
```

The script should:

-   Extract the matching Ubuntu kernel source.
-   Modify `sienna_cichlid_ppt.c`.
-   Add the V620-specific 120 W minimum-power-limit fix.
-   Build `amdgpu.ko` against the installed Ubuntu kernel headers.
-   Verify the compiled module contains the V620 patch.
-   Verify the module vermagic matches the target kernel.
-   Install the module under `/lib/modules/<kernel>/updates/`.
-   Run `depmod`.
-   Rebuild the target kernel's initramfs.

A successful run should end with output similar to:

``` text
V620: SUCCESS
Kernel: 7.0.0-30-generic
Module: /lib/modules/7.0.0-30-generic/updates/amdgpu.ko.zst
```

The following build message is harmless:

``` text
Skipping BTF generation for amdgpu.ko due to unavailability of vmlinux
```

## 6. Verify Ubuntu will use the patched module

Run:

``` bash
modinfo amdgpu | grep -E 'filename|vermagic'
```

The filename should point to the override under:

``` text
/lib/modules/<kernel>/updates/amdgpu.ko.zst
```

For example:

``` text
filename: /lib/modules/7.0.0-30-generic/updates/amdgpu.ko.zst
```

Verify that the module is also present in the initramfs:

``` bash
sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep 'updates/amdgpu.ko'
```

Expected output resembles:

``` text
usr/lib/modules/7.0.0-30-generic/updates/amdgpu.ko.zst
```

## 7. Reboot

``` bash
sudo reboot
```

## 8. Verify the V620 patch after reboot

Check for the driver's V620 power-fix message:

``` bash
sudo dmesg | grep -i 'V620 powerfix'
```

You should see a message similar to:

``` text
V620 powerfix: allowing PPT limit down to 120 W
```

Then verify the minimum allowed power cap:

``` bash
for d in /sys/class/drm/card*/device/hwmon/hwmon*; do
    [ -f "$d/power1_cap_min" ] || continue
    echo "$d"
    cat "$d/power1_cap_min"
done
```

For each V620, the expected value is:

``` text
120000000
```

Linux hwmon reports this value in microwatts, so `120000000` equals
**120 W**.

## 9. Test the V620 180 W power-cap script

The repository's `v620-cap-apply.sh` script was installed to
`/usr/local/sbin/` in Step 4.

Test it:

``` bash
sudo /usr/local/sbin/v620-cap-apply.sh 180
```

## 10. Verify the actual cap is 180 W

Run:

``` bash
for d in /sys/class/drm/card*/device/hwmon/hwmon*; do
    [ -f "$d/power1_cap" ] || continue
    echo "$d"
    cat "$d/power1_cap"
done
```

The expected value for each V620 is:

``` text
180000000
```

That equals **180 W**.

## 11. Make the 180 W cap automatic at boot

Install the repository's systemd unit:

``` bash
sudo cp \
    ~/v620_toolbox/powertuning/systemd/v620-powercap.service \
    /etc/systemd/system/
```

Reload systemd and enable the service:

``` bash
sudo systemctl daemon-reload
sudo systemctl enable --now v620-powercap.service
```

Verify:

``` bash
systemctl status v620-powercap.service --no-pager
```

## 12. Install the automatic kernel-update hook

Create the Ubuntu kernel post-install hook:

``` bash
sudo nano /etc/kernel/postinst.d/v620-amdgpu
```

Put the following in the file:

``` bash
#!/bin/sh
set -e

KREL="$1"

case "$KREL" in
    *-generic)
        /usr/local/sbin/v620-rebuild-amdgpu "$KREL"
        ;;
esac

exit 0
```

Save it and make it executable:

``` bash
sudo chmod 755 /etc/kernel/postinst.d/v620-amdgpu
```

Future Ubuntu generic-kernel installations should now invoke
`v620-rebuild-amdgpu` automatically.

If a future kernel changes the relevant AMDGPU source code and the
script can no longer find its expected source anchors, the rebuild
should stop rather than silently installing an incorrectly patched
module.

## Quick Setup Summary

Install the required packages:

``` bash
sudo apt install build-essential linux-headers-$(uname -r) linux-source \
    git bc flex bison libssl-dev libelf-dev dwarves zstd
```

Install the previously created rebuild script:

``` bash
sudo cp v620-rebuild-amdgpu /usr/local/sbin/
sudo chmod 755 /usr/local/sbin/v620-rebuild-amdgpu
```

Build and install the patched module:

``` bash
sudo /usr/local/sbin/v620-rebuild-amdgpu "$(uname -r)"
```

Reboot:

``` bash
sudo reboot
```

Verify the patch:

``` bash
sudo dmesg | grep -i 'V620 powerfix'
```

Verify the minimum power cap:

``` bash
for d in /sys/class/drm/card*/device/hwmon/hwmon*; do
    [ -f "$d/power1_cap_min" ] || continue
    echo "$d"
    cat "$d/power1_cap_min"
done
```

Expected minimum:

``` text
120000000
```

Then install `v620-cap-apply.sh`, configure the systemd service, and
verify that `power1_cap` is:

``` text
180000000
```

## Rollback Notes

The custom module is installed under:

``` text
/lib/modules/<kernel>/updates/amdgpu.ko.zst
```

The stock Canonical AMDGPU module remains under the normal kernel module
tree and is not overwritten.

If necessary, boot a known-good older kernel from GRUB and remove the
custom override for the affected kernel, then run `depmod` and rebuild
its initramfs.
