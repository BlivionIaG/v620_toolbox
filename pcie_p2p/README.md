# Enable PCIe P2P between Radeon PRO V620 GPUs on Fedora + AMD CPU

A self-contained guide for booting Fedora with kernel-level PCIe Peer-to-Peer
(P2P) enabled between Radeon PRO V620 GPUs. Two validated kernel paths:

- **Pre-7**: kernel ≤6.19.x (validated on 6.17.6)
- **Post-7**: kernel ≥7.1 (validated on 7.1.7)

Both paths are validated end-to-end: kernel boots clean, `rocminfo` enumerates
5 HSA agents, `amd-smi topology` shows 12/12 GPU↔GPU P2P ENABLED.

## Status

| Path | Status | Init time | Boot cap | Bench |
|---|---|---:|---|---|
| Pre-7 (6.17.6) | ✅ validated | 825 s (cold) | 180 W | kernel/KFD/amd-smi checks PASS |
| Post-7 (7.1.7) | ✅ validated | 278 s (cache warm) | 180 W | kernel/KFD/amd-smi checks PASS |

Both kernels can be simultaneously installed on the same host. Toggle with
`grubby --set-default /boot/vmlinuz-<evr>`.

## Contents

1. [Prerequisites](#prerequisites)
2. [Quick start](#quick-start)
3. [Full recipe](#full-recipe)
4. [Verify](#verify)
5. [What can go wrong](#what-can-go-wrong)
6. [See also](#see-also)

## Prerequisites

### Hardware

| Component | Required | Verified with |
|---|---|---|
| **AMD CPU** | Any modern AMD CPU (KFD tested with EPYC 7452) | EPYC 7452 (Zen 2, 32-core) |
| **Radeon PRO V620 (gfx1030)** | ≥1 card. P2P topology assumes ≥2; bench validated on 4. | 4× V620 reference board |
| **No pre-gfx1030 AMD GPU installed alongside the V620** *(per-host)* | ROCm 7.x dropped support for older ASIC families (gfx802 Tonga/Polaris, gfx803, gfx900 Vega, etc.). Any pre-gfx1030 AMD GPU present at boot makes KFD registration fail (`rocminfo` line 1349). **This only matters if your host has older AMD cards installed.** | (this guide's host had a gfx802; was removed before validation) |

Identify your V620 reference board:

```bash
lspci -nn | grep '1002:73a1'
```

Should show one line per V620 with subsystem `1002:0e34`. The full
4-tuple PCI-ID match is `1002:73a1:1002:0e34` — used by all the scripts
in `../powertuning/scripts/` to identify the reference board. **Other
gfx1030 boards** (RX 6900 XT, RX 6800) use device `0x73bf` and different
subsystem IDs; they require modifying the patch's PCI-ID match.

Verify no pre-gfx1030 AMD GPU is present *(skip if your host has only V620s)*:

```bash
# Pre-gfx1030: device IDs 0x6XXX (gfx1030+ starts at 0x7300)
lspci -nn | grep -E '1002:6[0-9a-f]{3}'
# PASS (relative to this guide): no output
# FAIL: pre-gfx1030 ASIC listed → power off, physically remove it
```

If this returns any lines, you must power off the host and physically
remove those GPUs before continuing. ROCm 7.x's `libhsakmt` rejects
their doorbell/CWSR aperture layouts, and `rocminfo` will bail at
line 1349 with `Failed to map remapped mmio page on gpu_mem 0`.

### Software

| Component | Required | Notes |
|---|---|---|
| **Fedora Linux 43** | yes | other fedora versions may work but are unvalidated |
| **dnf + rpm + dracut** | yes | standard fedora tooling |
| **kernel-devel** | for `--without ynl` flag's python deps; otherwise not required |
| **cmake** ≥ 3.20 | yes | required by fedora's kernel rpm build (`rpmbuild -ba kernel.spec`) |
| **gcc** ≥ 12 | yes | fedora 43 ships gcc 15.x |
| **make / ninja-build** | yes | build dependencies |
| **rsync** | for SRPM transfer | |
| **curl** | to fetch the SRPM from kojipkgs | |
| **git** | for the repo itself | |

### Disk space

| Path | Required | Notes |
|---|---|---|
| `${BUILD_DIR:-$HOME/build}/kernel-<ver>/` | ~3 GB | extracted SRPM + tarball + build dir |
| `${BUILD_DIR:-$HOME/build}/kernel-<ver>/x86_64/` | ~500 MB | produced rpms |
| `/boot/` | ~150 MB free | for `/boot/vmlinuz-<evr>` and initramfs |
| `${XDG_CACHE_HOME:-$HOME/.cache}/triton/cache/` | ~3 GB | grows over time; can be cleared if disk-pressured |

### CPU / RAM

| Component | Recommended |
|---|---|
| Cores | 32+ (validated host: 64 visible via `nproc`; `MAX_JOBS=32` is the bake's default) |
| RAM | 64 GB minimum (the kernel build uses ~16 GB) |

### Path overrides (defaults shown — set these if your layout differs)

```bash
export BUILD_DIR=${BUILD_DIR:-$HOME/build}                    # SRPM extract + kernel build dir
export ROCM_HOME=${ROCM_HOME:-/opt/rocm/core-7.14}            # ROCm 7.14 install root (amd-smi, rocminfo)
export XDG_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}          # kernel/torch compile cache root
```

### Self-check before starting

```bash
# 1. CPU is AMD
grep -q 'vendor_id.*AuthenticAMD' /proc/cpuinfo && echo OK || echo "FAIL: not AMD"

# 2. Distro is Fedora (>= 42)
grep -E '^NAME="Fedora' /etc/os-release && echo OK || echo "FAIL: not Fedora"

# 3. No pre-gfx1030 AMD GPU in the host (only relevant if you have older cards)
PRE_GFX10X=$(lspci -nn | grep -cE '1002:6[0-9a-f]{3}')
[ "$PRE_GFX10X" -eq 0 ] && echo "OK (no pre-gfx1030 ASIC)" || echo "FAIL: $PRE_GFX10X pre-gfx1030 ASIC(s) found; remove them"

# 4. ≥4 V620 in the host (or ≥2 if you don't need 4-way mesh)
COUNT=$(lspci -nn | grep -c '1002:73a1:1002:0e34')
[ "$COUNT" -ge 2 ] && echo "OK ($COUNT V620)" || echo "FAIL: only $COUNT V620"

# 5. Disk space
[ "$(df --output=avail / | tail -1 | tr -d ' ')" -gt 5000000 ] && echo OK || echo "FAIL: < 5GB free on /"

# 6. CPU cores
[ "$(nproc)" -ge 32 ] && echo "OK ($(nproc) cores)" || echo "WARN: $(nproc) cores, build will be slow"

# 7. Toolchain
for t in gcc make rpmbuild dracut curl; do
  command -v $t >/dev/null 2>&1 && echo "OK $t" || echo "FAIL: $t missing"
done

# 8. Build dir is writable (respects $BUILD_DIR from the env-var block above)
test -w "${BUILD_DIR:-$HOME/build}/" && echo "OK $BUILD_DIR" || echo "FAIL: ${BUILD_DIR:-$HOME/build}/ not writable (use sudo or chown)"

# 9. /boot has ~150MB free
[ "$(df --output=avail /boot | tail -1 | tr -d ' ')" -gt 150000 ] && echo OK || echo "FAIL: < 150MB on /boot"
```

If all are OK, proceed to the recipe below.

## Quick start

The recipe is the **same shape** for both pre-7 and post-7. The differences
are called out where they matter.

| | Pre-7 (≤6.19.x) | Post-7 (≥7.1) |
|---|---|---|
| Validated on | kernel 6.17.6 | kernel 7.1.7 |
| Buildid | `.p2p` | `.p2p_post7` *(underscore not hyphen)* |
| Install pattern | all kernel rpms | skip kernel-tools-* (file conflict with pre-7) |
| `CONFIG_DMABUF_MOVE_NOTIFY=y` | set | silently dropped by `make oldconfig` (symbol removed upstream; benign) |

### Pre-7 — six commands

```bash
# 1. Get the SRPM
curl -fsSL -o kernel-6.17.6-300.fc43.src.rpm \
  https://kojipkgs.fedoraproject.org/packages/kernel/6.17.6/300.fc43/src/kernel-6.17.6-300.fc43.src.rpm
rpm -i kernel-6.17.6-300.fc43.src.rpm
mkdir -p ${BUILD_DIR:-$HOME/build}/kernel-6.17.6 && cd $_
cp -p ~/rpmbuild/SPECS/kernel.spec ./
cp -p ~/rpmbuild/SOURCES/* ./

# 2. Bake (auto-applies kernel-config delta + powercap patch)
../powertuning/scripts/v620-kernel-bake.sh \
   --build-dir . \
   --buildid .p2p \
   --patch ../powertuning/patches/v620-powercap-min-120W.patch

# 3. Install + reboot
sudo rpm -Uvh --replacepkgs x86_64/kernel-*.rpm
sudo grubby --set-default /boot/vmlinuz-6.17.6-300.p2p.fc43.x86_64
sudo reboot

# 4. Lock dnf
sudo cp /etc/dnf/dnf.conf /etc/dnf/dnf.conf.bak.$(date +%Y%m%d-%H%M%S)
if grep -q '^exclude=' /etc/dnf/dnf.conf; then
  sudo perl -i -pe 's|^exclude=kernel( .*)$|exclude=kernel$1 kernel-tools kernel-tools-libs kernel-tools-libs-devel|' /etc/dnf/dnf.conf
else
  echo 'exclude=kernel kernel-core kernel-devel kernel-devel-matched kernel-modules kernel-modules-core kernel-modules-extra kernel-modules-extra-matched kernel-modules-internal kernel-uki-virt kernel-uki-virt-addons kernel-tools kernel-tools-libs kernel-tools-libs-devel' | sudo tee -a /etc/dnf/dnf.conf
fi
grep ^exclude /etc/dnf/dnf.conf    # verify the line is there

# 5. Install boot-cap service
sudo install -m 0755 ../powertuning/scripts/v620-cap-apply.sh /usr/local/sbin/
sudo cp ../powertuning/systemd/v620-powercap.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now v620-powercap.service

# 6. Verify
bash ../powertuning/scripts/v620-verify.sh
```

### Post-7 — seven commands

```bash
# 1. Get the SRPM
curl -fsSL -o kernel-7.1.7-100.fc43.src.rpm \
  https://kojipkgs.fedoraproject.org/packages/kernel/7.1.7/100.fc43/src/kernel-7.1.7-100.fc43.src.rpm
rpm -i kernel-7.1.7-100.fc43.src.rpm
mkdir -p ${BUILD_DIR:-$HOME/build}/kernel-7.1.7 && cd $_
cp -p ~/rpmbuild/SPECS/kernel.spec ./
cp -p ~/rpmbuild/SOURCES/* ./

# 2. Bake (auto-applies kernel-config delta + powercap patch)
../powertuning/scripts/v620-kernel-bake.sh \
   --build-dir . \
   --buildid .p2p_post7 \
   --patch ../powertuning/patches/v620-powercap-min-120W.patch

# 3. Install ONLY kernel + modules family (skip kernel-tools — file conflicts)
sudo rpm -ivh --replacepkgs $(ls x86_64/kernel-*.rpm | \
  grep -vE '(kernel-tools|kernel-tools-libs|kernel-tools-libs-devel|perf|libperf-devel|python3-perf|rtla|kernel-debug|kernel-debuginfo|kernel-selftests-internal|kernel-devel|kernel-devel-matched)')

# 4. Set boot default + rebuild initramfs + reboot
sudo grubby --set-default /boot/vmlinuz-7.1.7-100.p2p_post7.fc43.x86_64
sudo dracut --force "/boot/initramfs-7.1.7-100.p2p_post7.fc43.x86_64.img" 7.1.7-100.p2p_post7.fc43.x86_64
sudo reboot

# 5. Lock dnf (same logic as pre-7)
sudo cp /etc/dnf/dnf.conf /etc/dnf/dnf.conf.bak.$(date +%Y%m%d-%H%M%S)
if grep -q '^exclude=' /etc/dnf/dnf.conf; then
  sudo perl -i -pe 's|^exclude=kernel( .*)$|exclude=kernel$1 kernel-tools kernel-tools-libs kernel-tools-libs-devel|' /etc/dnf/dnf.conf
else
  echo 'exclude=kernel kernel-core kernel-devel kernel-devel-matched kernel-modules kernel-modules-core kernel-modules-extra kernel-modules-extra-matched kernel-modules-internal kernel-uki-virt kernel-uki-virt-addons kernel-tools kernel-tools-libs kernel-tools-libs-devel' | sudo tee -a /etc/dnf/dnf.conf
fi
grep ^exclude /etc/dnf/dnf.conf    # verify the line is there

# 6. Install boot-cap service
sudo install -m 0755 ../powertuning/scripts/v620-cap-apply.sh /usr/local/sbin/
sudo cp ../powertuning/systemd/v620-powercap.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now v620-powercap.service

# 7. Verify
bash ../powertuning/scripts/v620-verify.sh
```

Then run the full [Verify](#verify) sequence.

## Full recipe

### Step 1 — Confirm prerequisites

You passed the [self-check](#self-check-before-starting). If your host
has older AMD GPUs, the pre-gfx1030 check is the one that matters —
remove those cards before continuing. If you have only V620s and
newer, skip that step.

### Step 2 — Get the SRPM from kojipkgs

Fedora's active and archive mirrors scrub old kernel SRPMs once the
release baselines move on. Use **kojipkgs** (canonical, never scrubbed).

For pre-7 (kernel 6.17.6):

```bash
KVER=6.17.6
KREL=300.fc43
```

For post-7 (kernel 7.1.7):

```bash
KVER=7.1.7
KREL=100.fc43
```

Then for either:

```bash
URLS=(
  "https://kojipkgs.fedoraproject.org/packages/kernel/${KVER}/${KREL}/src/kernel-${KVER}-${KREL}.src.rpm"
  "https://kojipkgs.fedoraproject.org/packages/kernel/${KVER}/${KREL}/any/kernel-${KVER}-${KREL}.src.rpm"
  "https://kojipkgs.fedoraproject.org/packages/kernel/${KVER}/${KREL}/noarch/kernel-${KVER}-${KREL}.src.rpm"
)
for U in "${URLS[@]}"; do
  if curl -fsSL -o kernel-${KVER}-${KREL}.src.rpm "$U" && \
     [ "$(stat -c %s kernel-${KVER}-${KREL}.src.rpm)" -gt 100000 ]; then
    echo "OK from $U"
    break
  fi
done
[ -f kernel-${KVER}-${KREL}.src.rpm ] || { echo "no SRPM pulled"; exit 1; }
```

### Step 3 — Extract SRPM to a flat dist-git tree

```bash
rpm -i kernel-${KVER}-${KREL}.src.rpm     # extracts to ~/rpmbuild/{SPECS,SOURCES}/
DEST=${BUILD_DIR:-$HOME/build}/kernel-${KVER}
mkdir -p "$DEST" && cd "$DEST"
cp -p ~/rpmbuild/SPECS/kernel.spec ./
cp -p ~/rpmbuild/SOURCES/* ./
ls *.tar.xz *.spec                 # sanity: kernel spec + upstream tarball present
```

### Step 4 — Bake with `v620-kernel-bake.sh`

For pre-7:

```bash
"$SCRIPT_DIR"/v620-kernel-bake.sh \
    --build-dir "$DEST" \
    --buildid .p2p \
    --patch ../powertuning/patches/v620-powercap-min-120W.patch
```

For post-7:

```bash
"$SCRIPT_DIR"/v620-kernel-bake.sh \
    --build-dir "$DEST" \
    --buildid .p2p_post7 \
    --patch ../powertuning/patches/v620-powercap-min-120W.patch
```

**Why `_` not `-`** in `.p2p_post7`: RPM's `Release:` field rejects `-`.
If you use `.p2p-post7`, rpmbuild errors out at line 777 of the spec
parser with `Illegal char '-' (0x2d)`. The error is recoverable (just
re-run with the corrected buildid) but it's annoying.

What the script does (in order):
1. Copies the patch file into the build dir.
2. **Applies the kernel-config delta** (idempotent): appends `CONFIG_HSA_AMD_P2P=y`, `CONFIG_PCI_P2PDMA=y`, `CONFIG_DMABUF_MOVE_NOTIFY=y` to `kernel-x86_64-fedora.config`. These are required for ROCm KFD's HSA aperture registration on gfx1030.
3. Declares + applies the v620 powercap patch in `kernel.spec` (creates a marked block; idempotent on re-runs).
4. Empties `linux-kernel-test.patch` (avoids double-apply of the same hunks).
5. Runs `rpmbuild -ba kernel.spec --buildid <.p2p|.p2p_post7> --without debug --without debuginfo --without selftests --without ynl`.

Bake time: ~10-20 min on 32 cores (validated host: ~27 min wall clock for 6.17.6).

### Step 5 — Install rpms + reboot

For pre-7 (install all kernel rpms):

```bash
sudo rpm -Uvh --replacepkgs "$DEST"/x86_64/kernel-*.rpm
sudo grubby --set-default /boot/vmlinuz-${KVER}-${KREL}.fc43.x86_64
sudo reboot
```

For post-7 (skip kernel-tools-* — they file-conflict with pre-7 kernel-tools):

```bash
sudo rpm -ivh --replacepkgs \
   $(ls x86_64/kernel-*.rpm | \
     grep -vE '(kernel-tools|kernel-tools-libs|kernel-tools-libs-devel|perf|libperf-devel|python3-perf|rtla|kernel-debug|kernel-debuginfo|kernel-selftests-internal|kernel-devel|kernel-devel-matched)')
sudo grubby --set-default /boot/vmlinuz-7.1.7-100.p2p_post7.fc43.x86_64
sudo dracut --force "/boot/initramfs-7.1.7-100.p2p_post7.fc43.x86_64.img" 7.1.7-100.p2p_post7.fc43.x86_64
sudo reboot
```

8 packages installed: `kernel`, `kernel-core`, `kernel-modules`,
`kernel-modules-core`, `kernel-modules-extra`, `kernel-modules-internal`,
`kernel-uki-virt`, `kernel-uki-virt-addons` (plus
`kernel-modules-extra-matched` as a dependency).

**Why not all the rpms on post-7?** `kernel-tools-*` packages conflict
on shared userspace binaries (`/usr/bin/cpupower`, `/usr/bin/turbostat`,
`/usr/bin/tmon`, ...). Both `kernel-tools-6.17.6` and `kernel-tools-7.1.7`
claim ownership of these files; rpm refuses to install both side-by-side.
The kernel-tools from the older kernel still work — they read /sys, not
kernel ABI.

If grubby can't find the vmlinuz, the install didn't write to `/boot`. Check:

```bash
ls -la /boot/vmlinuz-${KVER}-${KREL}.fc43.x86_64
```

### Step 6 — Lock dnf

Without this exclude, `dnf update` will silently swap the .p2p buildid
for the stock fedora build, dropping both the kernel-config delta AND
the v620 powercap patch in one shot.

```bash
sudo cp /etc/dnf/dnf.conf /etc/dnf/dnf.conf.bak.$(date +%Y%m%d-%H%M%S)
# Lock dnf: either extend an existing exclude=kernel* line, or append a new one.
# The perl substitution silently does nothing if no exclude= line exists, so check first.
if grep -q '^exclude=' /etc/dnf/dnf.conf; then
  sudo perl -i -pe 's|^exclude=kernel( .*)$|exclude=kernel$1 kernel-tools kernel-tools-libs kernel-tools-libs-devel|' /etc/dnf/dnf.conf
else
  echo 'exclude=kernel kernel-core kernel-devel kernel-devel-matched kernel-modules kernel-modules-core kernel-modules-extra kernel-modules-extra-matched kernel-modules-internal kernel-uki-virt kernel-uki-virt-addons kernel-tools kernel-tools-libs kernel-tools-libs-devel' | sudo tee -a /etc/dnf/dnf.conf
fi
grep ^exclude /etc/dnf/dnf.conf    # verify the line is there
```

### Step 7 — Install the boot-cap service

The kernel patch lowers the floor to 120 W, but the cap stays at the
VBIOS max (≈250 W) until something actively writes 180 W to it. The
oneshot service does that at boot.

```bash
sudo install -m 0755 ../powertuning/scripts/v620-cap-apply.sh /usr/local/sbin/
sudo cp ../powertuning/systemd/v620-powercap.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now v620-powercap.service
systemctl status v620-powercap.service   # expect: active (exited) / SUCCESS
```

Note: the script lives in `/usr/local/sbin/`, not `$HOME`. SELinux
refuses to execute `user_home_t` scripts (203/EXEC).

For full powercap details (the 120 W floor / 180 W boot cap subsystem),
see [`../powertuning/docs/POWERCAP.md`](../powertuning/docs/POWERCAP.md).

### Step 8 — Verify

```bash
bash ../powertuning/scripts/v620-verify.sh
```

Expect: `V620 powerfix: allowing PPT limit down to 120 W on 0000:XX:00.0`
appearing once per V620 in dmesg, and `power1_cap_min=120000000` on every
V620 hwmon.

Then run the full [Verify](#verify) sequence.

### Post-7 only: `CONFIG_DMABUF_MOVE_NOTIFY=y` is silently dropped

The bake script appends all 3 kernel-config flags (`HSA_AMD_P2P`,
`PCI_P2PDMA`, `DMABUF_MOVE_NOTIFY`). On 7.1.7's mainline, the
`DMABUF_MOVE_NOTIFY` Kconfig symbol has been removed/renamed upstream.
`make oldconfig` discards it without breaking the build.

**This is benign.** HSA aperture registration works without it because
the underlying feature is now baked into a parent symbol (likely
`CONFIG_DMABUF=y` with always-on notify). Verified: `rocminfo`
enumerates 5 agents.

If you run `grep CONFIG_DMABUF_MOVE_NOTIFY /boot/config-7.1.7-...`
expect no match. Don't panic.

### Post-7 only: both kernels installed

After the install, both `kernel-6.17.6-300.p2p.fc43.x86_64` and
`kernel-7.1.7-100.p2p_post7.fc43.x86_64` are present in the rpm DB.
Toggle boot with:

```bash
sudo grubby --set-default /boot/vmlinuz-7.1.7-100.p2p_post7.fc43.x86_64 && sudo reboot
# or
sudo grubby --set-default /boot/vmlinuz-6.17.6-300.p2p.fc43.x86_64 && sudo reboot
```

## Verify

Run these in order on the host after install + reboot. Every line must
PASS before the configuration is considered validated.

### Pre-flight

```bash
# No pre-gfx1030 ASIC (only relevant if you have older cards)
PRE_GFX10X=$(lspci -nn | grep -cE '1002:6[0-9a-f]{3}')
[ "$PRE_GFX10X" -eq 0 ] && echo "PASS: no pre-gfx1030 ASIC" || echo "FAIL: $PRE_GFX10X pre-gfx1030 ASIC(s) found; remove them"

# ≥2 V620
COUNT=$(lspci -nn | grep -c '1002:73a1:1002:0e34')
[ "$COUNT" -ge 2 ] && echo "PASS: $COUNT V620" || echo "FAIL: only $COUNT V620"
```

### 1. Kernel + dnf lock

```bash
uname -r
# PASS pre-7:  expect 6.17.6-300.p2p.fc43.x86_64 (or similar pre-7 EVR)
# PASS post-7: expect 7.1.7-100.p2p_post7.fc43.x86_64 (or similar post-7 EVR)

grep ^exclude /etc/dnf/dnf.conf
# PASS: line starts with "exclude=kernel kernel-core kernel-modules ..."
```

### 2. Kernel config (the kernel-config delta)

```bash
grep -E "^CONFIG_(HSA_AMD_P2P|PCI_P2PDMA|DMABUF_MOVE_NOTIFY)=" \
   /boot/config-$(uname -r)
# PASS pre-7:  expect 3 lines, all =y (including DMABUF_MOVE_NOTIFY)
# PASS post-7: expect 2-3 lines; DMABUF_MOVE_NOTIFY may be silently dropped
#               (Kconfig symbol removed upstream in 7.1.7; benign)
# FAIL:        missing HSA_AMD_P2P or PCI_P2PDMA → kernel-config delta
#               not baked in; re-bake with v620-kernel-bake.sh
```

### 3. Hardware

```bash
lspci -nn | grep -E '1002:73a1:1002:0e34' | wc -l
# PASS: 4 (or your ≥2 count)
```

### 4. Powercap subsystem

```bash
# Did the patch fire at boot?
dmesg | grep -c 'V620 powerfix'
# PASS: 4 (one notice per V620)
# FAIL: 0 → patch didn't apply; check bake logs

# Did the boot-cap service run?
systemctl status v620-powercap.service --no-pager
# PASS: Active: active (exited) since <boot>; status=0/SUCCESS

# Are all V620 hwmons at 180000000?
for h in /sys/class/hwmon/hwmon*/power1_cap; do
  echo "$(basename $(dirname $h)) = $(cat $h)"
done
# PASS: every V620 hwmon = 180000000
# FAIL: V620 hwmon at 250000000 → service didn't run; check journalctl

# Floor check
for h in /sys/class/hwmon/hwmon*/power1_cap_min; do
  echo "$(basename $(dirname $h)).cap_min = $(cat $h)"
done
# PASS: 120000000 on every V620 hwmon
# FAIL: 250000000 → patch didn't lower the floor
```

For full powercap subsystem details (the 120 W floor / 180 W boot cap story),
see [`../powertuning/docs/POWERCAP.md`](../powertuning/docs/POWERCAP.md).

### 5. KFD topology (12/12 P2P links)

```bash
# KFD nodes count
ls /sys/class/kfd/kfd/topology/nodes/ | wc -l
# PASS: 5 (1 CPU + N V620)

# Per-node io/p2p link counts
for n in $(seq 1 $((COUNT-1+1))); do
  d=/sys/class/kfd/kfd/topology/nodes/$n
  io=$(grep -oE 'io_links_count [0-9]+' $d/properties 2>/dev/null | head -1 | cut -d' ' -f2)
  p2p=$(grep -oE 'p2p_links_count [0-9]+' $d/properties 2>/dev/null | head -1 | cut -d' ' -f2)
  printf "  node %d (%s): io=%s p2p=%s (expect io=1 p2p=%s)\n" \
    "$n" "$(cat $d/name 2>/dev/null)" "$io" "$p2p" "$((COUNT-1))"
done
# PASS: io=1, p2p=N-1 (where N = V620 count; for 4 V620, p2p=3)
# FAIL: io=0 → GPU not registered with KFD; check dmesg
# FAIL: p2p=0 → CONFIG_HSA_AMD_P2P=y not baked in
```

### 6. amd-smi runtime P2P (12/12 ENABLED)

```bash
LD_LIBRARY_PATH=${ROCM_HOME:-/opt/rocm/core-7.14}/lib ${ROCM_HOME:-/opt/rocm/core-7.14}/bin/amd-smi topology 2>&1 \
  | head -30
# PASS: ACCESS TABLE shows 12/12 ENABLED, weight 40, hops 2, link PCIE,
#       atomics 64,32
# FAIL: any cell shows DISABLED → runtime P2P not provisioned
```

### 7. amdgpu module params

```bash
cat /sys/module/amdgpu/parameters/pcie_p2p /sys/module/amdgpu/parameters/use_xgmi_p2p
# PASS: pcie_p2p=Y, use_xgmi_p2p=1
# FAIL: pcie_p2p=0 → echo 'options amdgpu pcie_p2p=1' | sudo tee /etc/modprobe.d/amdgpu-p2p.conf && sudo dracut --force && reboot
```

### 8. HSA agents (the wall test)

```bash
LD_LIBRARY_PATH=${ROCM_HOME:-/opt/rocm/core-7.14}/lib ${ROCM_HOME:-/opt/rocm/core-7.14}/bin/rocminfo 2>&1 \
  | grep -E 'Agent [0-9]+|Device Type|Marketing Name|^\*\*\* Done'
# PASS: 5 agents (1 CPU + 4 V620), ends with "*** Done ***", exit 0
# FAIL: < 5 agents, or "*** ERROR ***", or "Failed to map remapped mmio page" →
#       pre-gfx1030 ASIC in host, OR kernel-config delta missing
```

### One-shot verification script

A consolidated runner is at [`scripts/verify-p2p.sh`](scripts/verify-p2p.sh).
Install it:

```bash
sudo install -m 0755 ../pcie_p2p/scripts/verify-p2p.sh /usr/local/sbin/
```

Then run `sudo verify-p2p.sh` after install. It executes checks 1-8
above in sequence and prints a PASS/FAIL summary.

### What "validated" means

All of the above checks PASS simultaneously. If any fails, the
configuration is **not validated** — even if the kernel boots. The
pre-7 stack and the post-7 stack both meet this bar on this guide's
validated host.

## What can go wrong

### Wall: `rocminfo` fails with `Failed to map remapped mmio page on gpu_mem 0`

The HSA aperture registration is the deepest test of whether P2P is
working. If `rocminfo` bails at line 1349 with this error, one of the
3 layers of the validated fix is broken.

#### Layer-by-layer diagnostic

| Layer | Check | Fix |
|---|---|---|
| **Layer 1: kernel-config delta** | `grep -E "^CONFIG_(HSA_AMD_P2P|PCI_P2PDMA)=" /boot/config-$(uname -r)` returns both =y | rebuild kernel with `../powertuning/scripts/v620-kernel-bake.sh`; the script applies the delta in step 1.5/4 |
| **Layer 2: pre-gfx1030 ASIC** | `lspci -nn \| grep -cE '1002:6[0-9a-f]{3}'` is 0 | power off, physically remove pre-gfx1030 AMD GPUs, power on (only relevant if your host has older cards) |
| **Layer 3: v620 patch** | `dmesg \| grep 'V620 powerfix'` returns ≥1 line | rebuild kernel with the canonical patch (`v620-powercap-min-120W.patch`); check the build log if it didn't apply |

Detailed walk:

```bash
# Step 1: is the kernel-config delta in?
grep -E "^CONFIG_(HSA_AMD_P2P|PCI_P2PDMA)=" /boot/config-$(uname -r)
# if missing, the kernel wasn't baked with v620-kernel-bake.sh; re-bake

# Step 2: are pre-gfx1030 ASICs still in?
lspci -nn | grep -E '1002:6[0-9a-f]{3}'
# if any line, power off and remove those GPUs; they're pre-HSA
# (ROCm 7.x dropped gfx802/gfx900/etc. support — applies only if your host has older AMD cards)

# Step 3: did the v620 patch fire?
dmesg | grep -E 'V620 powerfix'
# if missing, the patch didn't apply. check kernel build log for
# rejected hunks or symbol errors.
```

Complete diagnostic matrix:

| `lspci \| grep 1002:6[0-9a-f]{3}` | `dmesg \| grep V620 powerfix` | `grep CONFIG_HSA_AMD_P2P=y` | Cause |
|---|---|---|---|
| empty | 4 lines | yes | wall fully broken on something else; check `amd-smi topology` and `rocminfo` logs |
| empty | 0 lines | no | patch didn't apply AND kernel-config delta missing |
| empty | 4 lines | no | patch fired but kernel-config delta missing |
| **non-empty** | (any) | (any) | **pre-gfx1030 ASIC(s) still in host; remove them and reboot** |
| empty | 0 lines | yes | patch didn't apply (wrong version or build glitch) |

### Powercap: `power1_cap` write rejected at 180 W

If `echo 180000000 | sudo tee /sys/class/hwmon/hwmonN/power1_cap`
returns `EINVAL`, the kernel patch didn't apply.

```bash
# 1. Did the patch fire at boot?
dmesg | grep 'V620 powerfix'
# 2. Is the kernel actually using the patch?
dmesg | grep 'sienna_cichlid_get_power_limit'
# 3. Confirm you're using the canonical patch:
#    cat ../powertuning/patches/v620-powercap-min-120W.patch
#    (must use `noinline`, NOT `__noipa`)
```

If step 1 returns 0 lines, the patch didn't apply. Most common causes:
- Hand-modified patch switched to `__noipa` (undefined on the running kernel).
- Build flag `--without` corrupted the kernel build.
- The patch hunks didn't apply because the upstream source changed.

For more detail on the powercap subsystem, see
[`../powertuning/docs/POWERCAP.md`](../powertuning/docs/POWERCAP.md).

### Boot: kernel doesn't boot

If the new kernel panics or doesn't come back up:

1. **Use grub to boot the old kernel**: at boot, hit `e` to edit,
   or interrupt the default boot and pick the previous kernel entry.
   The previous (validated) kernel is still installed alongside, so you
   can always roll back.
2. **Check `journalctl -b -1`** (the previous boot log) for the panic.
3. Common cause: kernel-config delta applied wrong, or `sienna_cichlid_ppt.c`
   moved in the source tree (the patch's hunk targets are line-specific).
4. Less common: a hand-modified patch switched to an attribute that
   is undefined on this specific kernel (e.g., `__noipa` on ≤6.19.x).
   Restore the canonical patch from `../powertuning/patches/v620-powercap-min-120W.patch`.

### Install: file conflicts on `cpupower`, `turbostat`, etc.

`kernel-tools-*` packages claim ownership of userspace binaries that
are NOT versioned per-kernel. Installing both
`kernel-tools-6.17.6-300.p2p.fc43.x86_64` and
`kernel-tools-7.1.7-100.p2p_post7.fc43.x86_64` will fail with:

```
file /usr/bin/cpupower from install of kernel-tools-7.1.7-100.p2p_post7.fc43.x86_64
     conflicts with file from package kernel-tools-6.17.6-300.p2p.fc43.x86_64
```

Fix: install only the kernel + modules family. Skip kernel-tools-*.
The kernel-tools from the older kernel still work (they read /sys, not
kernel ABI).

```bash
sudo rpm -ivh --replacepkgs \
   $(ls x86_64/kernel-*.rpm | \
     grep -vE '(kernel-tools|kernel-tools-libs|kernel-tools-libs-devel|perf|libperf-devel|python3-perf|rtla|kernel-debug|kernel-debuginfo|kernel-selftests-internal|kernel-devel|kernel-devel-matched)')
```

### Bake: `rpmbuild: Illegal char '-' in Release:`

If you used a buildid with a hyphen like `.p2p-post7`, rpmbuild
rejects it:

```
error: line 777: Illegal char '-' (0x2d) in: Release: 100.p2p-post7.fc43
```

RPM's `Release:` field rejects `-`. Use `_` instead:

```bash
../powertuning/scripts/v620-kernel-bake.sh --build-dir ... --buildid .p2p_post7 --patch ...
```

### Bake: `__noipa undeclared` or `expected ';' before 'void'`

You shouldn't see these errors with the canonical patch
(`../powertuning/patches/v620-powercap-min-120W.patch`) — it uses the
portable `noinline` attribute that compiles on every kernel version ≥5.15.

If you see them, you are using a hand-modified patch that switched to
`__noipa` on a kernel where it's undefined (e.g., ≤6.19.x). Restore
the canonical patch from
`../powertuning/patches/v620-powercap-min-120W.patch`.

### Common recipe issues (pre-7 and post-7)

| Symptom | Cause | Fix |
|---|---|---|
| `rpmbuild: line 777: Illegal char '-' in Release:` | buildid has `-` (e.g. `.p2p-post7`) | use `_` (e.g. `.p2p_post7`) |
| `expected ';' before 'void'` in `sienna_cichlid_ppt.c` | hand-modified patch switched to `__noipa` (undefined on 6.x) | restore `noinline` from the canonical patch |
| `__noipa undeclared` | hand-modified patch switched to `__noipa` on a kernel where it's undefined | restore `noinline` from the canonical patch |
| `amdgpu-install` fails with EPEL | you tried to install ROCm userland separately | don't — only the kernel-side changes are needed for the wall; this guide does not cover ROCm userland install |
| `rocminfo` bails at line 1349 | pre-gfx1030 ASIC still in host, OR kernel-config delta missing | check `lspci -nn \| grep -E '1002:6[0-9a-f]{3}'` is empty + `/boot/config-$(uname -r)` has the 3 flags |
| `power1_cap` write rejected (below 120W) | patch not applied | check dmesg for `V620 powerfix` notices |
| File conflicts on `cpupower`, `turbostat`, etc. | tried to install both kernel-tools versions | exclude kernel-tools-* from the install glob |
| `grubby: cannot find vmlinuz` | install didn't write to /boot | check `ls -la /boot/vmlinuz-...`; if missing, re-run install step |
| `Cannot find module directory` from dracut (post-7) | initramfs regen target missing | only run dracut AFTER the install completes |
| Init time 13 min instead of 30 s (post-7) | torch.compile cache is cold | expected on a fresh host; not a regression |

### SRPM fetch: 404 from kojipkgs

Fedora scrubs old kernel SRPMs from active mirrors. kojipkgs is the
**only** canonical source. If kojipkgs also 404s:

- The kernel build may be EOL — check the koji web UI
- Use the dist-git tag (`https://src.fedoraproject.org/rpms/kernel.git`)
  for the spec, and kernel.org for the upstream tarball

### Useful commands for digging deeper

```bash
# What does KFD actually see?
ls /sys/class/kfd/kfd/topology/nodes/
cat /sys/class/kfd/kfd/topology/nodes/1/properties    # hex dump + ascii

# What does amd-smi see?
LD_LIBRARY_PATH=${ROCM_HOME:-/opt/rocm/core-7.14}/lib ${ROCM_HOME:-/opt/rocm/core-7.14}/bin/amd-smi list
LD_LIBRARY_PATH=${ROCM_HOME:-/opt/rocm/core-7.14}/lib ${ROCM_HOME:-/opt/rocm/core-7.14}/bin/amd-smi topology

# What's the kernel doing?
sudo dmesg | grep -E 'amdgpu|kfd|hsa' | head -50

# What's the disk usage for caches?
du -sh ${XDG_CACHE_HOME:-$HOME/.cache}/triton
```

If none of the above resolves your issue:

1. Run [`scripts/verify-p2p.sh`](scripts/verify-p2p.sh) and capture the full output.
2. Capture `dmesg | grep -E 'amdgpu|kfd|hsa'`.
3. Capture `${ROCM_HOME:-/opt/rocm/core-7.14}/bin/rocminfo` output with `HSAKMT_DEBUG_LEVEL=3`.
4. Reference this guide in the bug report (especially the diagnostic matrix).

## See also

- [`AGENTS.md`](AGENTS.md) — conventions for AI agents modifying this guide
- [`../README.md`](../README.md) — repo overview
- [`../powertuning/docs/POWERCAP.md`](../powertuning/docs/POWERCAP.md) — the 120 W floor / 180 W boot cap subsystem deep-dive