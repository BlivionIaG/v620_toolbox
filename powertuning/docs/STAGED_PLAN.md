# Staged Plan — V620 Power Tuning + AMD P2P

Canonical deployment plan. This is the single source of truth for "what to
do, in what order, with what validation." References back to the knowledge
base for the *why*.

**Target**: 5× Radeon PRO V620 (``), Fedora 43/44, ~180 W steady-state per card, with GPU-to-GPU P2P enabled.

**Goal**: Run all 4 idle GPUs at ~180 W + light undervolt, with P2P available
for multi-GPU inference. Active GPU 3 (`0000:83:00.0`) stays at stock 250 W
until the job is out.

---

## Phase 0 — Preflight (no system changes)

Read-only. Run from the local machine, SSH to `` only for `read` commands.

### 0.1 Host identity

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key>

cat /etc/os-release
uname -r
mokutil --sb-state
```

**Required**: Fedora 43 or 44. Secure Boot must be in Setup Mode or disabled.

**Why**: The build script (`build-p2p-kernel.sh`) uses `fedpkg` from the Fedora
dist-git. Ubuntu/SUSE paths don't work. Secure Boot blocks unsigned modules.

### 0.2 GPU identity (all 10 cards)

```bash
# All V620s (gfx1030) + W7800s (gfx1100)
lspci -nn -d '1002:73a1|1002:7470'
```

For each card, capture:

```bash
for BDF in $(lspci -nn -d '1002:73a1|1002:7470' | awk '{print $1}'); do
  DEV=/sys/bus/pci/devices/$BDF
  printf '%s vendor=%s device=%s subsystem=%s:%s revision=%s\n' \
    "$BDF" \
    "$(<"$DEV/vendor")" \
    "$(<"$DEV/device")" \
    "$(<"$DEV/subsystem_vendor")" \
    "$(<"$DEV/subsystem_device")" \
    "$(<"$DEV/revision")"
done
```

**Required**:
- 8 cards report `device=0x73a1` (V620, RDNA2)
- 2 cards report `device=0x7470` (W7800, RDNA3)
- Capture `subsystem_device` for each — the patch match string uses it.

### 0.3 PCIe topology (including PLX 88096 switches)

```bash
# Find PLX 88096 switches
lspci -nn -d 10b5:88096

# Full tree
lspci -tv

# Check ACS on PLX switches
for bdf in $(lspci -nn -d 10b5:88096 | awk '{print $1}'); do
  echo "$bdf: ACS=$(sudo setpci -s $bdf ECAP_ACS+6.w)"
done

# Check effective link speed per GPU
for bdf in $(lspci -nn -d '1002:73a1|1002:7470' | awk '{print $1}'); do
  speed=$(lspci -vvv -s "$bdf" | awk '/Speed/ {print $1; exit}')
  echo "$bdf: $speed"
done
```

**Required**:
- 2 PLX 88096 switches present
- Each V620 reports Gen4 speed (16 GT/s)
- Each W7800 reports Gen4 speed
- ACS check reports the platform-specific value (will be addressed in next phase)

### 0.4 Active job

```bash
export PATH=/opt/rocm-7.2.0/bin:$PATH
rocm-smi --showpidgpus
rocm-smi --showpower
```

**Required**: Record which BDFs are drawing > 150 W (running jobs) and which
are < 20 W (idle).

**Note**: The previous 5-V620 fleet had an active-job GPU that we patched
around. The new fleet has 8 V620s + 2 W7800s; the active-job state depends
on whatever is running at the time of preflight. The patch covers all 8
V620s by default — no per-BDF exclusion needed unless there's an active
job running on a V620 we want to leave at 250 W.

### 0.5 BMC access

```bash
ipmitool -H <bmc_ip> -U <user> -P <pass> chassis power status
```

**Required**: A way to cold-power-cycle the host from outside the OS.

**Why**: V620 has no FLR. SMU wedges require cold power. Without BMC,
recovery means hands at the rack.

### 0.6 Build environment

```bash
sudo dnf install -y --no-install-recommends \
  fedpkg rpm-build rpmdevtools ncurses-devel \
  gcc gcc-c++ make git jq
```

**Required**: `fedpkg` and `jq` available. The rest of the build deps are
pulled automatically by `fedpkg sources`.

### 0.7 Source package

```bash
git -C ~/build/kernel fetch origin
git -C ~/build/kernel branch -a | grep -E '^\s+(f43|f44|rawhide)'
```

**Required**: At least one of `f43`, `f44` is reachable.

### 0.8 Generate the targets config

```bash
# On the local machine (not )
./scripts/generate-targets.sh \
  --from-ssh <user>@:/home/<user>/.config/powertuning/preflight.json \
  --output patches/targets.json
```

This captures all 8 V620 BDFs and their subsystem IDs into a config file
the build script reads.

---

## Phase 1 — P2P readiness verification

Use `scripts/v620-p2p-readiness.sh` to score the four P2P gates on ``.
**Read-only — does not touch the system.**

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> \
  '/home/<user>/Projects/infrastructure/gfx1030_optimized/powertuning/scripts/v620-p2p-readiness.sh --strict'
```

**Required**: 0 FAIL. WARN is OK; FAIL is not.

**Stop conditions**: Any FAIL.

### What each gate checks

| Gate | What fails | What to do |
|---|---|---|
| **kernel** | `CONFIG_HSA_AMD_P2P=n` or `CONFIG_PCI_P2PDMA=n` | Rebuild the kernel with `--skip-powerfix-patch` first (P2P-only build), install, reboot |
| **topology** | No `1002:73a1` devices, or small BAR (< 16 G) | Enable Above 4G Decoding + Resizable BAR in BIOS |
| **acs** | ACS redirect enabled on a switch port | Add `pcie_acs_override=downstream,multifunction` to kernel cmdline |
| **iommu** | `amd_iommu=on` blocking P2P | Use `amd_iommu=on iommu=pt` or `amd_iommu=off` |
| **runtime** | `amdgpu.pcie_p2p=N` or empty `p2p_links/` | `echo Y > /sys/module/amdgpu/parameters/pcie_p2p` (or kernel cmdline) |

### If P2P cannot be made to work

Stop. Without P2P we cannot do multi-GPU inference — the workload falls back
to host-staged copies (~13 GB/s vs ~25 GB/s direct). The kernel patch alone
is still useful for single-GPU throughput. Decide:

- **Accept the loss**: ship with single-GPU only, no P2P.
- **Fix the topology**: BIOS changes, kernel cmdline, etc.
- **Defer**: keep the kernel patch for single-GPU, revisit P2P on a different host.

**Why this gate comes first**: The kernel patch is wasted work if we cannot
use P2P. Verifying P2P *before* building the kernel lets us choose the right
kernel options (`--skip-powerfix-patch` for P2P-only, full for both).

---

## Phase 2 — Kernel build (with both P2P + powerfix)

Run from the local machine with the Fedora source tree at `~/build/kernel`.

### 2.1 First build: P2P-only (sanity)

```bash
./scripts/build-p2p-powerfix-kernel.sh \
  --skip-powerfix-patch \
  --kernel-dir ~/build/kernel \
  --install-deps \
  --no-install-kernel
```

**Validates**: The user's existing build-p2p-kernel.sh works with `.p2p` build
ID, the kernel-local config gets the P2P bits set, and the build completes.

### 2.2 Second build: P2P + powerfix

```bash
./scripts/build-p2p-powerfix-kernel.sh \
  --target-bdf 0000:03:00.0 \
  --min-watts 180 \
  --kernel-dir ~/build/kernel \
  --install-deps \
  --no-install-kernel
```

**Validates**: The patch stages cleanly into `kernel.spec` and the SRPM
rebuilds. No `fedpkg` errors.

### 2.3 Validate the resulting RPM

```bash
./scripts/v620-validate-kernel-rpm.sh \
  --rpm ~/build/kernel/x86_64/kernel-core-*.rpm
```

**Required**: Both P2P config lines AND the powerfix marker string are
present. Exit 0.

**If validation fails**: re-bake with `v620-kernel-bake.sh` and check
the build log. If the kernel source has changed (e.g., `sienna_cichlid_ppt.c`
moved), the patch needs updating for that kernel — see the README's
"Other kernel versions" note.
moved and the patch headers need adjustment.

### 2.4 Sync to ``

```bash
rsync -avz \
  --include='x86_64/kernel-core-*.rpm' \
  --include='x86_64/kernel-*.rpm' \
  --exclude='*' \
  -e "ssh -i ~/.ssh/id_<ssh-key>" \
  ~/build/kernel/ \
  <user>@:~/build/kernel/
```

---

## Phase 3 — Install + one-shot boot on ``

### 3.1 Confirm preflight still holds

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> \
  '/home/<user>/Projects/infrastructure/gfx1030_optimized/powertuning/scripts/v620-p2p-readiness.sh'
```

**Required**: 0 FAIL. (P2P still works on the stock kernel — Phase 1 result.)

### 3.2 Install the kernel

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> \
  "cd ~/build/kernel && \
   sudo dnf -y --nogpgcheck install \
     x86_64/kernel-core-*.rpm \
     x86_64/kernel-*.rpm \
     x86_64/kernel-modules-*.rpm \
     x86_64/kernel-modules-core-*.rpm \
     x86_64/kernel-modules-extra-*.rpm"
```

### 3.3 Make the stock kernel the persistent default

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> \
  "sudo grub2-set-default 'gnulinux-advanced-$(cat /etc/machine-id)>gnulinux-7.0.0-28-generic-advanced-$(cat /etc/machine-id)'"
```

(or equivalent for Fedora's BLS — adjust the GRUB config syntax to match the
host's boot loader; may need `grubby` instead.)

### 3.4 One-shot boot the custom kernel

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> \
  "sudo grub2-reboot 'gnulinux-advanced-$(cat /etc/machine-id)>gnulinux-<new-kernel>-advanced-$(cat /etc/machine-id)'"
```

(or equivalent.)

### 3.5 Reboot

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> \
  "sudo systemctl reboot"
```

### 3.6 Post-boot validation (read-only)

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  uname -r
  /home/<user>/Projects/infrastructure/gfx1030_optimized/powertuning/scripts/v620-p2p-readiness.sh
  /home/<user>/Projects/infrastructure/gfx1030_optimized/powertuning/scripts/v620-validate-kernel-rpm.sh --running
'
```

**Required**:
- `uname -r` matches the new kernel release
- `v620-p2p-readiness.sh` reports 0 FAIL
- `v620-validate-kernel-rpm.sh --running` confirms the powerfix marker is in `amdgpu.ko`

**Stop conditions**: Custom kernel didn't boot, OR the active job on GPU 3 is
unresponsive, OR `dmesg` shows SMU errors.

---

## Phase 4 — V0 baseline (no powerfix applied)

Goal: 4-hour synthetic characterization at the stock 250 W cap, to establish
per-GPU baseline performance and ECC counts.

### 4.1 Generate per-GPU baselines

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  for BDF in 0000:03:00.0 0000:07:00.0 0000:43:00.0 0000:C7:00.0; do
    # rocBLAS 8192^2 FP16 GEMM, 30 seconds
    ROCR_VISIBLE_DEVICES=$BDF ~/v620-kernel-test/rocblas-stress 15
  done
'
```

### 4.2 Capture ECC counter baseline

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  for BDF in 0000:03:00.0 0000:07:00.0 0000:43:00.0 0000:C7:00.0; do
    echo "=== $BDF ==="
    amd-smi static --limit -g $BDF
  done
'
```

**Save** to `~/v620-kernel-test/baseline-v0.txt` on ``.

---

## Phase 5 — V1 proof of life (200 W on GPU 0)

The smallest possible change. One GPU, conservative cap, no undervolt.

### 5.1 Configure the patch

Generate the variant patch for GPU 0 at 200 W:

```bash
./scripts/build-p2p-powerfix-kernel.sh \
  --target-bdf 0000:03:00.0 \
  --min-watts 200 \
  --kernel-dir ~/build/kernel \
  --no-install-deps \
  --no-install-kernel
```

(Reuse the kernel source tree; only the patch text changes.)

### 5.2 Install + boot

Same as Phase 3.2 – 3.5.

### 5.3 Verify (read-only)

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  for BDF in 0000:03:00.0 0000:07:00.0 0000:43:00.0 0000:83:00.0 0000:C7:00.0; do
    DEV=/sys/bus/pci/devices/$BDF
    printf "%s power1_cap_min=%s\n" "$BDF" "$(<"$DEV/hwmon/hwmon*/power1_cap_min")"
  done
  dmesg | grep "V620 powerfix"
'
```

**Required**:
- GPU 0 (`0000:03:00.0`) `power1_cap_min = 200000000` (200 W)
- GPUs 1, 2, 4 still at 250 W
- GPU 3 (active) still at 250 W
- Exactly one `V620 powerfix` line in `dmesg`

### 5.4 Apply 200 W to GPU 0

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  set -euo pipefail
  BDF=0000:03:00.0
  CAP=/sys/bus/pci/devices/$BDF/hwmon/hwmon*/power1_cap
  printf "%s" 200000000 | sudo tee $CAP >/dev/null
  cat $CAP
'
```

**Required**: readback = `200000000`. If not 200000000, STOP.

### 5.5 Run 1 h synthetic + 1 h idle

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  ROCR_VISIBLE_DEVICES=0000:03:00.0 ~/v620-kernel-test/rocblas-stress 60
  sleep 3600
'
```

During the run, check every 15 minutes:

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  journalctl -k -b --no-pager | grep -E "SMU|page fault|reset|AER"
  amd-smi static --limit -g 0000:03:00.0
'
```

**Stop conditions** (any one stops the run):
- SMU error or "I'm not done with your previous command" in `dmesg`
- gfxhub page fault
- AER error
- ECC counter delta
- Workload result mismatch
- Inability to read back 200 W

### 5.6 Restore 250 W

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  printf "%s" 250000000 | sudo tee /sys/bus/pci/devices/0000:03:00.0/hwmon/hwmon*/power1_cap
'
```

### 5.7 Reboot back to stock

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> 'sudo systemctl reboot'
```

---

## Phase 6 — V2 all 4 idle GPUs at 200 W

Extend the patch to 4 idle BDFs at 200 W, GPU 3 stays at 250 W.

### 6.1 Patch coordinates

| BDF | Floor | Rationale |
|---|---|---|
| `0000:03:00.0` | 200 W | Idle GPU 0 |
| `0000:07:00.0` | 200 W | Idle GPU 1 |
| `0000:43:00.0` | 200 W | Idle GPU 2 |
| `0000:83:00.0` | **250 W** | Active GPU 3 — no-op |
| `0000:C7:00.0` | 200 W | Idle GPU 4 |

The patch's BDF table is host-specific. Edit the kernel patch source
in `patches/v620-powercap-min-120W.patch` (change the BDF table entries
and the active-job BDF) before rebuilding, or use a different patch
file entirely.

### 6.2 Rebuild, install, boot

Same as Phase 5.1 – 5.3 plus 5.7.

### 6.3 Verify per-GPU `power1_cap_min`

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  for BDF in 0000:03:00.0 0000:07:00.0 0000:43:00.0 0000:83:00.0 0000:C7:00.0; do
    printf "%s power1_cap_min=%s\n" "$BDF" \
      "$(<"/sys/bus/pci/devices/$BDF/hwmon/hwmon*/power1_cap_min")"
  done
'
```

**Required**: 4 idle GPUs at 200 W, GPU 3 at 250 W.

### 6.4 Apply 200 W to all 4 idle GPUs

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  for BDF in 0000:03:00.0 0000:07:00.0 0000:43:00.0 0000:C7:00.0; do
    CAP=/sys/bus/pci/devices/$BDF/hwmon/hwmon*/power1_cap
    printf "%s" 200000000 | sudo tee $CAP >/dev/null
    echo "$BDF: $(<$CAP)"
  done
'
```

### 6.5 24-hour real workload

Use the actual vLLM bench that the production load will use. For example:

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  vllm serve /models/Qwen3.6-27B-GPTQ-W4A16-G32 \
    --tensor-parallel-size 4 \
    --max-num-seqs 8 \
    --gpu-memory-utilization 0.85 \
    --language-model-only \
    --skip-mm-profiling \
    --port 8000
'
```

(The exact command depends on the production workload. Whatever it is, run it
for 24 hours.)

### 6.6 Telemetry capture

Every 6 hours, capture:

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  for BDF in 0000:03:00.0 0000:07:00.0 0000:43:00.0 0000:C7:00.0; do
    echo "=== $BDF ==="
    /opt/rocm-7.2.0/bin/rocm-smi -d $BDF --showpower --showtemp --showuse --showmemuse
  done
'
```

### 6.7 Restore 250 W, reboot stock

Same as Phase 5.6 – 5.7.

---

## Phase 7 — V3 target cap (180 W + 0 mV)

Same as V2 but `min=180` instead of 200, and no undervolt.

### 7.1 Patch + rebuild

```bash
./scripts/build-p2p-powerfix-kernel.sh \
  --target-bdf 0000:03:00.0 \
  --min-watts 180 \
  --kernel-dir ~/build/kernel \
  --no-install-deps \
  --no-install-kernel
```

(Per-BDF patch variants for 4 idle GPUs.)

### 7.2 Apply 180 W

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  for BDF in 0000:03:00.0 0000:07:00.0 0000:43:00.0 0000:C7:00.0; do
    printf "%s" 180000000 | sudo tee /sys/bus/pci/devices/$BDF/hwmon/hwmon*/power1_cap
  done
'
```

### 7.3 24-hour real workload

Same as Phase 6.5.

### 7.4 Cap enforcement check

After the workload, check that the 180 W cap was actually respected. A
sustained 4× 200 W+ workload should have mean reported power ≈ 175 W per GPU.
If any GPU shows > 195 W mean, the cap is not being enforced.

---

## Phase 8 — V4 first undervolt (180 W + −10 mV)

The first real test of the undervolt path. Conservative; this is the
absolute safest VO setting.

### 8.1 Apply VO −10 mV

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  set -euo pipefail
  for BDF in 0000:03:00.0 0000:07:00.0 0000:43:00.0 0000:C7:00.0; do
    OD=/sys/bus/pci/devices/$BDF/pp_od_clk_voltage
    # Stage
    printf "vo -10" | sudo tee $OD >/dev/null
    # Commit
    printf "c"    | sudo tee $OD >/dev/null
    # Verify
    grep OD_VDDGFX_OFFSET $OD
  done
'
```

**Required**: `OD_VDDGFX_OFFSET: -10mV` on each GPU.

### 8.2 1-hour synthetic + 24-hour real

Same as Phase 7, but with VO −10 mV applied.

### 8.3 Stop conditions

(Already in `AGENTS.md`. The relevant ones for V4:)

- Workload result mismatch
- VRAM data mismatch (run the VRAM stress test if suspicious)
- gfxhub page fault
- ECC counter delta
- Inability to restore 0 mV

### 8.4 Restore defaults

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  for BDF in 0000:03:00.0 0000:07:00.0 0000:43:00.0 0000:C7:00.0; do
    OD=/sys/bus/pci/devices/$BDF/pp_od_clk_voltage
    printf "r" | sudo tee $OD >/dev/null
    printf "c" | sudo tee $OD >/dev/null
    grep OD_VDDGFX_OFFSET $OD
  done
'
```

**Required**: `OD_VDDGFX_OFFSET: 0mV` on each GPU.

---

## Phase 9 — V5 per-GPU characterization (up to −30 mV)

The "silicon lottery" phase. The local guide found per-card failure
boundaries from −100 mV to −150 mV on the same SKU. We go to −30 mV (the
guide's default) and stop there.

### 9.1 One GPU at a time

Start with GPU 0 (the most thermally headroom per the local guide).
Sequential order: 0 → 1 → 2 → 4.

### 9.2 For each GPU: step −10 mV → −20 mV → −30 mV

For each step (per GPU):

1. **Apply** the VO (`vo -10` → `c`, then `vo -20` → `c`, then `vo -30` → `c`)
2. **Cool-down** 60 s idle
3. **Run** 1 h synthetic workload
4. **Check** ECC delta, gfxhub page faults, workload result
5. **Run** 2 h soak at the new VO
6. **Check** again
7. **If pass**: continue to next step
8. **If fail**: stop, this is the failure boundary. Back off 20 mV.

### 9.3 Find the "deepest short pass" per GPU

From the local guide:
- "Deepest short pass at 30 mV" or "first hard failure at 40 mV" → use 30 mV
- "Deepest short pass at 20 mV" → use 20 mV (back off from 30 mV failure)

### 9.4 Record per-GPU final offsets

```bash
# Saved to ~/v620-kernel-test/per-gpu-vo-finals.txt on 
BDF       DeepestShort  HardFail  Recommendation
0000:03   -30           -40       -30
0000:07   -30           -40       -30
0000:43   -20           -30       -20
0000:C7   -30           -40       -30
```

(The numbers are placeholders; fill in from your actual measurements.)

---

## Phase 10 — V6 production profile

Per-GPU final offsets, 24-hour real workload.

### 10.1 All 4 idle GPUs at 180 W + per-GPU VO

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> '
  for BDF in 0000:03:00.0 0000:07:00.0 0000:43:00.0 0000:C7:00.0; do
    # Set cap
    DEV=/sys/bus/pci/devices/$BDF
    CAP=/sys/bus/pci/devices/$BDF/hwmon/hwmon*/power1_cap
    OD=/sys/bus/pci/devices/$BDF/pp_od_clk_voltage
    printf "%s" 180000000 | sudo tee $CAP >/dev/null
    # Find this card recommended VO from the per-gpu-vo-finals.txt
    VO=$(grep "$BDF" ~/v620-kernel-test/per-gpu-vo-finals.txt | awk "{print \$4}")
    printf "vo %s" "$VO" | sudo tee $OD >/dev/null
    printf "c" | sudo tee $OD >/dev/null
  done
'
```

### 10.2 24-hour vLLM bench

Same as Phase 6.5. Capture throughput, latency, ECC, temperatures.

### 10.3 Confirm target efficiency

Expected: ~0.19 TFLOPS/W per GPU vs the 0.150 TFLOPS/W at stock 250 W. That's
a ~27% efficiency improvement.

---

## Phase 11 — Production deployment

### 11.1 Make the kernel persistent

After V6 passes the 7-day production soak:

```bash
ssh <user>@ -i ~/.ssh/id_<ssh-key> \
  "sudo grub2-set-default 'gnulinux-advanced-$(cat /etc/machine-id)>gnulinux-<new-kernel>-advanced-$(cat /etc/machine-id)'"
```

### 11.2 Persist the cap + offset

Two options:

**Option A: Apply manually after each boot (safer, matches the local guide)**

The user runs the apply command after each reboot. No SystemD service.

**Option B: SystemD service to apply on boot**

```bash
# /etc/systemd/system/v620-power-tuning.service
[Unit]
Description=Apply V620 power cap and offset
After=amdgpu.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/apply-v620-tuning.sh

[Install]
WantedBy=multi-user.target
```

The local guide deliberately did **not** deploy this. Recommend same.

### 11.3 Skip auto-rebuild automation

The local guide does not deploy any scheduled rebuild timer. The
operator runs `scripts/v620-check-kernel-update.sh` followed by the manual
rebuild sequence when ready.

---

## Stop conditions (binding at every phase)

ANY one of these stops the run, restores defaults, and reboots stock:

- Write timeout or nonzero return
- Readback mismatch
- SMU, ring, fence, reset, page-fault, RAS, AER, or machine-check error
- GPU disappears or ROCr mapping changes
- Workload result mismatch or non-zero exit
- Missing/stale telemetry
- Inability to restore defaults
- Edge ≥ 80 °C, hotspot ≥ 85 °C, memory ≥ 80 °C
- AMD-SMI UUID mismatch (after kernel boot)

If the SMU becomes unresponsive, **cold power-cycle through BMC and boot stock**.

---

## Estimated time per phase

| Phase | Description | Time |
|---|---|---|
| 0 | Preflight | 1 h |
| 1 | P2P verification | 10 m |
| 2 | Kernel build (P2P + powerfix) | 2 h |
| 3 | Install + boot | 30 m |
| 4 | V0 baseline | 4 h |
| 5 | V1 proof of life | 2 h |
| 6 | V2 all 4 GPUs at 200 W | 24 h |
| 7 | V3 180 W + 0 mV | 24 h |
| 8 | V4 180 W + −10 mV | 24 h |
| 9 | V5 per-GPU characterization | 6 h (per GPU) |
| 10 | V6 production profile | 24 h |
| 11 | Production deployment | 1 h |
| **Total** | | **~7 days** |

---

## Cross-references

- Knowledge base: `README.md`
- P2P knowledge: `docs/AMD_P2P.md`
- Patch system: `patches/README.md`
- Build pipeline: `README.md` §"Rebuild workflow (manual)"
- Live status: `README.md` §"Status"
- Agent rules: `AGENTS.md`
