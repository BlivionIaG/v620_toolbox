# AMD PCIe P2P — Knowledge Base

Compiled 2026-08-03 for the 5× V620 fleet on `` (Fedora 43/44, ROCm 7.2.0).

This document is the answer to "what do we need to make AMD PCIe P2P work on
AMD systems with AMD cards." It synthesizes the upstream kernel P2PDMA
framework, the AMDGPU driver integration, the ROCm userspace APIs, and the
hardware topology requirements.

The short version: **P2P needs four things to all be true at the same time**:

1. **Kernel** — `CONFIG_HSA_AMD_P2P=y` (and the related P2PDMA / DMABUF options)
2. **Hardware** — GPUs on the same PCIe root complex, "large BAR" exposing the
   full VRAM through the PCIe aperture
3. **BIOS/UEFI** — Above 4G Decoding and Resizable BAR enabled, ACS configured
   correctly for the use case
4. **Runtime** — `HSA_FORCE_FINE_GRAIN_PCIE=1` for HIP/RCCL, and the AMDGPU
   `pcie_p2p` module param enabled

If any one is missing, the transfer falls back to a host-staged copy
(GPU A → host RAM → GPU B) which is 2–3× slower and uses CPU cycles.

---

## 1. What P2P is and why we want it

PCIe Peer-to-Peer (P2P) is a direct DMA transfer between two endpoint devices
on the same PCIe fabric. Without P2P, GPU-to-GPU data movement requires:

```
GPU A → host RAM (PCIe write) → CPU DMA → host RAM (PCIe read) → GPU B
```

With P2P:

```
GPU A → GPU B (direct PCIe DMA)
```

For our 5× V620 fleet, the typical use cases are:

- **Multi-GPU inference** — KV cache transfer for tensor parallelism
- **Multi-GPU training** — gradient all-reduce via RCCL
- **P2P copies** — kernel-to-kernel data exchange without host bounce
- **MoE all-to-all** — expert dispatch in mixture-of-experts models

The throughput difference on PCIe Gen4 x16 is roughly:

| Path | Unidirectional BW | Host CPU usage |
|---|---|---|
| P2P DMA (best case) | ~25 GB/s | 0 |
| Host-staged bounce | ~13 GB/s | heavy (memcpy) |

The 2× bandwidth difference and the zero CPU overhead are why P2P matters.

---

## 2. The four gates

### 2.1 Gate 1: Kernel config

The kernel-side support is split across several config options. The user's
existing `~/build/build-p2p-kernel.sh` already enforces the full set:

```
CONFIG_HSA_AMD=y
CONFIG_HSA_AMD_SVM=y
CONFIG_HSA_AMD_P2P=y
CONFIG_PCI_P2PDMA=y
CONFIG_DMABUF_MOVE_NOTIFY=y
CONFIG_DEVICE_PRIVATE=y
CONFIG_ZONE_DEVICE=y
```

What each does:

| Config | What it enables |
|---|---|
| `HSA_AMD` | KFD (Kernel Fusion Driver) base for AMD GPUs |
| `HSA_AMD_SVM` | Shared Virtual Memory — CPU↔GPU pointer coherence |
| `HSA_AMD_P2P` | GPU-to-GPU peer accessibility in `amdgpu_device_is_peer_accessible()` |
| `PCI_P2PDMA` | Core P2PDMA framework (the `pci_p2pdma_*` APIs) |
| `DMABUF_MOVE_NOTIFY` | Dynamic DMA-buf migration callbacks |
| `DEVICE_PRIVATE` | ZONE_DEVICE pages for unaddressable device memory |
| `ZONE_DEVICE` | Base support for `struct page` over device memory |

`HSA_AMD_P2P` depends on `PCI_P2PDMA` and `DMABUF_MOVE_NOTIFY`. On kernel
6.13+/7.2+, `DMABUF_MOVE_NOTIFY` is no longer optional — it was promoted
to always-on. The Kconfig `select` chain handles this automatically.

### 2.2 Gate 2: Hardware topology

P2P requires the two GPUs to be in the **same PCIe hierarchy domain** (same
root complex, no intervening root port that blocks P2P). The kernel checks
this via `pci_p2pdma_distance()`, which returns:

- `-1` if P2P is not routable (different root complex, blocked by ACS)
- `0` for same device (best)
- `2` for same device, two functions
- `4` for same PCIe switch
- greater numbers for cross-root-port via whitelisted host bridge

**What can break this**:

- **ACS (Access Control Services)** redirect enabled on a switch port
- **IOMMU** in full translation mode and not whitelisted
- **Different root complexes** between GPUs (rare on consumer/server boards)

For the 5× V620 on ``, we expect all GPUs to be on the same root complex
(EPYC). The verification commands are in §5.

### 2.3 Gate 3: BIOS / UEFI

The "large BAR" condition is the most common reason P2P fails:

- **Above 4G Decoding: Enabled** — allows BARs > 4 GB
- **Resizable BAR: Enabled** — exposes the full VRAM through the aperture
- **MMIO High Base/Size** — aperture must be below 2^44 (the V620's DMA mask)

If the BAR is small (e.g., 256 MB aperture covering 32 GB VRAM), the kernel
check `amev->gmc.visible_vram_size == amev->gmc.real_vram_size` fails and
P2P is disabled at the driver level.

**Verification**:

```bash
# Look for "size=32G" (large) vs "size=256M" (small)
lspci -vvv -s $(lspci -nn -d 1002:73a1 | head -1 | awk '{print $1}') \
  | grep -A3 "Memory.*prefetchable"
```

ACS configuration in BIOS:

| Use case | ACS setting | BIOS notes |
|---|---|---|
| Bare-metal P2P only (no VMs) | ACS off, IOMMU off | Easiest path |
| Bare-metal P2P + ROCm tools | ACS on, IOMMU pass-through | `iommu=pt` |
| Mixed (incl. VMs) | ACS on, pcie_acs_override kernel param | Compromise |

**Distro support caveat**: AMD officially supports V620 on **Ubuntu 22.04/24.04
only** for ROCm 7.x. Fedora 43/44 is not officially supported but the
software stack generally works — the user is in "engineering territory" and
should validate carefully.

### 2.4 Gate 4: Runtime

The runtime side needs:

```bash
# Required for HIP/RCCL P2P on RDNA2 (gfx1030)
export HSA_FORCE_FINE_GRAIN_PCIE=1

# Optional: prefer P2P over host copies
export NCCL_P2P_LEVEL=PHB

# Verify amdgpu module param is enabled
cat /sys/module/amdgpu/parameters/pcie_p2p   # should be Y
echo "Y" | sudo tee /sys/module/amdgpu/parameters/pcie_p2p  # if not
```

Without `HSA_FORCE_FINE_GRAIN_PCIE=1`, HIP and RCCL silently fall back to
host-staged copies on RDNA2.

---

## 3. RDNA2 vs RDNA3 vs CDNA — the critical difference

The V620 is **RDNA2** (gfx1030). The W7800 is **RDNA3** (gfx1100). The P2P
story differs by GPU family:

| GPU family | Architecture | PCIe P2P | XGMI P2P | Use case |
|---|---|---|---|---|
| **Radeon PRO V620** (gfx1030, `0x73a1`) | RDNA2 | ✅ via BAR | ❌ no XGMI | Consumer/professional |
| **Radeon PRO W6800** (gfx1030) | RDNA2 | ✅ via BAR | ❌ no XGMI | Workstation |
| **Radeon PRO W7800** (gfx1100, `0x7470`) | RDNA3 | ✅ via BAR | ❌ no XGMI | Workstation, 48GB |
| **Radeon RX 7900 XTX** (gfx1100, `0x7448`) | RDNA3 | ✅ via BAR | ❌ no XGMI | Consumer |
| **Instinct MI100** (gfx908) | CDNA | ✅ via BAR | ✅ XGMI | Datacenter |
| **Instinct MI250X** (gfx90a) | CDNA2 | ✅ via BAR | ✅ XGMI | Datacenter |
| **Instinct MI300X** (gfx942) | CDNA3 | ✅ via BAR | ✅ XGMI | Datacenter |

**RDNA2 and RDNA3 both use PCIe BAR-based P2P** — no XGMI fabric. So our
mixed fleet (5× V620 + N× W7800) uses PCIe BAR-based P2P exclusively.
The bandwidth is whatever PCIe Gen4/Gen5 gives us (typically 25–32 GB/s
per direction, lane-width-dependent).

**CDNA uses XGMI**, which is much faster (50–500 GB/s per direction
depending on the GPU family and link count). For P2P on CDNA, XGMI is
the primary path and PCIe is a fallback.

For our V620 fleet, the kernel check `amdgpu_device_is_peer_accessible()`
gates everything on `visible_vram_size == real_vram_size` (large BAR) and
the PCIe distance check.

### 3.3 PLX 88096 (PEX 88096) — the Gen4 fan-out switch

The final fleet uses **2× PLX 88096 PCIe Gen4 switches** with 4 V620s on each
and 2 W7800s direct on the CPU root complex. The PLX 88096 is a 96-lane
PCIe Gen4 switch configured as 6 downstream ports × 16 lanes (only 4 ports
used per switch for the V620s).

```text
                  ┌─────────────────────────┐
                  │   CPU root complex        │
                  │   (EPYC, PCIe Gen4)      │
                  └────────────┬──────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
   ┌────┴──────┐         ┌────┴──────┐         ┌──────┴──────┐
   │ PLX 88096 │         │ PLX 88096 │         │             │
   │  switch 1 │         │  switch 2 │         │  W7800 #1   │
   │  (Gen4)   │         │  (Gen4)   │         │  (direct)   │
   │           │         │           │         │  PCIe Gen4  │
   └─┬─┬─┬─┬───┘         └─┬─┬─┬─┬───┘         └─────────────┘
     │ │ │ │               │ │ │ │
     V V V V               V V V V
    0 1 2 3               4 5 6 7
   (V620)                (V620)            W7800 #2 (direct, not shown)
```

**Key implications**:

- **Bandwidth**: All P2P paths are PCIe Gen4 x16 ≈ **32 GB/s** per direction
  (no Gen3 bottleneck since the 88096 is Gen4)
- **All GPUs end-to-end P2P** reachable via the same or adjacent root complex
- **P2P across switches** works via the root complex ports (the PLX supports
  non-transparent bridging via NT VPs)
- **Same-arch and cross-arch P2P** both work (V620 ↔ V620, W7800 ↔ W7800,
  V620 ↔ W7800)

**ACS considerations for PLX 88096**:

The PLX 88096 ships with **ACS enabled** on all downstream ports. To enable
P2P between GPUs behind the switch, you need either:

1. **In the PLX EEPROM**: disable ACS on the downstream ports (requires a
   PLX config tool; not scriptable from the host)
2. **In the kernel**: add `pcie_acs_override=downstream,multifunction` to
   the kernel cmdline (the script updates the existing build script to
   enforce this)

The kernel override is the standard HPC workaround. The PLX 88096's VSEC
register exposes inter-switch link topology that the kernel uses when
`CONFIG_PCIE_P2P_LINK` is enabled.

**CONFIG_PCIE_P2P_LINK** (kernel 6.13+):

This option enables the kernel's PLX VSEC consumer, which reads the
inter-switch link capabilities exposed by the PLX 88096's Vendor-Specific
Extended Capability. With this enabled, the kernel can detect inter-switch
P2P paths and report them via sysfs (`/sys/bus/pci/.../p2p_link`). This is
especially useful for the 2-switch topology where pairs of V620s may use
different paths.

**W7800 (RDNA3) on the same root complex**:

The 2 W7800s are direct on the CPU root complex, not behind the PLX. This
means:

- **No PLX hop** between W7800 ↔ W7800 (best case)
- **One PLX hop** between W7800 ↔ V620 (still good, ~32 GB/s)
- **Bandwidth is asymmetric**: W7800↔W7800 is full Gen4, V620↔V620 same
  switch is Gen4, V620↔V620 across switches is Gen4 via cross-PLX bridge

**PCIe topology discovery** (add to the verification commands):

```bash
# Find PLX 88096 switches
lspci -nn -d 10b5:88096

# Find all AMD GPUs (RDNA2 + RDNA3)
lspci -nn -d '1002:73a1|1002:7470'

# Check ACS on the PLX switches
for bdf in $(lspci -nn -d 10b5:88096 | awk '{print $1}'); do
  echo "$bdf: ACS=$(sudo setpci -s $bdf ECAP_ACS+6.w)"
done

# Check effective link speed (Gen3 vs Gen4)
for bdf in $(lspci -nn -d '1002:73a1|1002:7470' | awk '{print $1}'); do
  speed=$(lspci -vvv -s "$bdf" | awk '/Speed/ {print $1; exit}')
  echo "$bdf: $speed"
done
```

### 3.1 RDNA3 (gfx1100) specifics — what the same kernel path does

The kernel P2P infrastructure does **not** care about RDNA2 vs RDNA3. The
AMDGPU driver registers both as peer-eligible devices with the same code
path. The differences are:

| Aspect | RDNA2 (V620) | RDNA3 (W7800) |
|---|---|---|
| Device ID | `0x73a1` | `0x7470` |
| Default power cap | 250 W | 260 W |
| DMA mask | 44-bit | 44-bit |
| BAR aperture | must be < 2^44 | must be < 2^44 |
| Large BAR required | ✅ | ✅ |
| `HSA_AMD_P2P` kernel config | ✅ | ✅ |
| `HSA_FORCE_FINE_GRAIN_PCIE=1` | ✅ | ✅ |
| `hipDeviceCanAccessPeer` API | ✅ | ✅ |
| RCCL symmem path | ✅ | ✅ |
| Power-cap kernel patch | needed (this project) | **not needed** (user keeps stock) |

### 3.2 Mixed-architecture P2P (RDNA2 ↔ RDNA3)

Cross-architecture P2P works because the kernel path is the same — both
use the AMDGPU driver, both register with KFD, both expose VRAM through
the same PCIe BAR path. The kernel's `amdgpu_device_is_peer_accessible()`
returns true based on hardware topology and BAR, not on GPU architecture.

What the user should expect:

- **`hipDeviceCanAccessPeer`(V620, W7800)** returns 1 if P2P is configured
- **`rocm-smi --showtopotype`** shows the link type ("PCIE" or "PHB" — not "XGMI", since neither card has XGMI)
- **Bandwidth** is bounded by the slowest PCIe link in the path (PCIe Gen4 vs Gen5)
- **Latency** similar to same-architecture P2P

The user is not power-tuning the W7800, so the kernel patch stays
V620-specific. The W7800 stays at its 260 W stock cap. P2P still works
at the stock cap.

---

## 4. The ROCm userspace APIs

### 4.1 HIP P2P APIs

| API | Purpose |
|---|---|
| `hipDeviceCanAccessPeer(int *canAccess, int dev, int peer)` | Check if P2P is possible (returns 1=YES, 0=NO) |
| `hipDeviceEnablePeerAccess(int peer, unsigned flags)` | Enable P2P for `peer` device's memory in current device's VA space |
| `hipDeviceDisablePeerAccess(int peer)` | Disable P2P for `peer` device |
| `hipMemcpyPeer(dst, dstDev, src, srcDev, size)` | Synchronous P2P copy |
| `hipMemcpyPeerAsync(dst, dstDev, src, srcDev, size, stream)` | Async P2P copy on a stream |

`hipDeviceCanAccessPeer` is the **only** reliable way to know at runtime
whether P2P will work for a given pair. It returns 1 only when the kernel
P2P path is operational, large BAR is exposed, and the hosts are in the
same root complex.

### 4.2 RCCL (AMD's NCCL) and P2P

RCCL uses P2P for all-reduce, all-gather, reduce-scatter when the
peers are P2P-capable. The critical env var on RDNA2:

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
```

Without this, RCCL uses host-mediated transfers even when P2P is available.

Other useful env vars:

```bash
NCCL_P2P_LEVEL=PHB       # default; accept P2P via host bridge
NCCL_P2P_DISABLE=0       # explicitly enable P2P
NCCL_IGNORE_CPU_AFFINITY=0  # use GPU topology
NCCL_DEBUG=INFO          # log p2p transport decisions
```

### 4.3 Verification tools

```bash
# Topology matrix (lower = better)
rocm-smi --showtopo

# Topology link type (PCIE / XGMI / PHB)
rocm-smi --showtopotype

# P2P accessibility (binary matrix)
rocm-smi --showtopoaccess

# KFD-level P2P links (the kernel path)
ls /sys/class/kfd/kfd/topology/nodes/0/p2p_links/

# Bandwidth verification (unidirectional + bidirectional)
rocm-bandwidth-test

# HIP-level check
HSA_FORCE_FINE_GRAIN_PCIE=1 ./p2p_test
```

### 4.4 What "good" looks like

```
$ rocm-smi --showtopoaccess
       GPU0  GPU1  GPU2  GPU3  GPU4
GPU0    1    1    1    1    1
GPU1    1    1    1    1    1
GPU2    1    1    1    1    1
GPU3    1    1    1    1    1
GPU4    1    1    1    1    1

$ ls /sys/class/kfd/kfd/topology/nodes/0/p2p_links/
0  1  2  3  4   # one entry per peer GPU

$ rocm-bandwidth-test
Inter-Device Access
D/D  0  1  2  3  4
0    1  1  1  1  1
1    1  1  1  1  1
2    1  1  1  1  1
3    1  1  1  1  1
4    1  1  1  1  1
```

### 4.5 What "bad" looks like (fallback to host)

```
$ rocm-smi --showtopoaccess
       GPU0  GPU1  GPU2  GPU3  GPU4
GPU0    1    0    0    0    0
GPU1    0    1    0    0    0
...

$ ls /sys/class/kfd/kfd/topology/nodes/0/p2p_links/
(empty — no P2P links exposed)

$ rocm-bandwidth-test
Inter-Device Access
D/D  0  1  2  3  4
0    1  0  0  0  0
1    0  1  0  0  0
...
```

The 0s in the matrix tell you P2P is not active. Walk the four gates
above to find which one is failing.

---

## 5. The setup checklist for ``

### 5.1 BIOS / UEFI (need BMC/web access)

- [ ] **Above 4G Decoding**: Enabled
- [ ] **Resizable BAR** (or "Large BAR"): Enabled
- [ ] **IOMMU / AMD-Vi**: Enabled (for "IOMMU pass-through" mode) OR Off (for bare-metal P2P only)
- [ ] **ACS Enable**: Depends on use case (see §2.3)
- [ ] **CSM**: Disabled (UEFI boot only)
- [ ] **PCIe link speed**: Confirm GPUs are at PCIe Gen4 or Gen5, x16 width

### 5.2 Kernel command line (Fedora 43/44)

For bare-metal P2P only (no VMs):

```
amd_iommu=off
pcie_acs_override=downstream,multifunction
```

For bare-metal P2P + ROCm tools (keep IOMMU for safety):

```
amd_iommu=on iommu=pt
pcie_acs_override=downstream,multifunction
```

On Fedora, edit via:

```bash
sudo rpm-ostree kargs --append="amd_iommu=off pcie_acs_override=downstream,multifunction"
# OR
sudo grubby --update-kernel=ALL --args="amd_iommu=off pcie_acs_override=downstream,multifunction"
```

### 5.3 Runtime environment (every shell)

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
export NCCL_P2P_LEVEL=PHB
```

### 5.4 Quick verification

```bash
# 1. Kernel config
zcat /proc/config.gz | grep -E 'CONFIG_HSA_AMD_P2P|CONFIG_PCI_P2PDMA'

# 2. Module param
cat /sys/module/amdgpu/parameters/pcie_p2p

# 3. KFD P2P links
ls /sys/class/kfd/kfd/topology/nodes/0/p2p_links/

# 4. ROCm topology
rocm-smi --showtopoaccess
rocm-smi --showtopotype

# 5. HIP smoke test
HSA_FORCE_FINE_GRAIN_PCIE=1 /opt/rocm-7.2.0/bin/hipcc /tmp/p2p_test.cpp -o /tmp/p2p_test && /tmp/p2p_test
```

---

## 6. The diagnostic commands in one place

```bash
# === Hardware ===
lspci -tv                                       # PCIe tree
lspci -nn -d 1002:73a1                          # V620 BDFs
lspci -vvv -s <BDF> | grep -A3 "Memory.*pref"   # BAR size (large = 32G)
for b in $(lspci -nn -d ::0604 | awk '{print $1}'); do
  echo "$b: $(sudo setpci -s $b ECAP_ACS+6.w 2>/dev/null)"
done                                          # ACS on each bridge

# === Kernel ===
zcat /proc/config.gz | grep -E 'CONFIG_HSA_AMD_P2P|CONFIG_PCI_P2PDMA|CONFIG_DEVICE_PRIVATE'
cat /sys/module/amdgpu/parameters/pcie_p2p
cat /proc/cmdline | tr ' ' '\n' | grep -i 'iommu\|acs'

# === Runtime ===
ls /sys/class/kfd/kfd/topology/nodes/0/p2p_links/
rocm-smi --showtopo
rocm-smi --showtopoaccess
rocm-smi --showtopotype

# === Higher-level ===
HSA_FORCE_FINE_GRAIN_PCIE=1 /opt/rocm-7.2.0/bin/rocm-bandwidth-test
NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=P2P \
  /opt/rocm-7.2.0/bin/all_reduce_perf -b 1M -e 16M -f 2 -g 1
```

---

## 7. Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `hipDeviceCanAccessPeer` returns 0 for all pairs | Large BAR not enabled, or `HSA_AMD_P2P=n` in kernel | BIOS: Above 4G Decoding + Resizable BAR; kernel config |
| `rocm-smi --showtopoaccess` shows 0s | `pcie_acs_override` missing, or ACS blocking in BIOS | Kernel cmdline: `pcie_acs_override=downstream,multifunction` |
| `p2p_links/` directory is empty | `HSA_AMD_P2P=n` or `amdgpu.pcie_p2p=0` | Check kernel config, set `echo Y > /sys/module/amdgpu/parameters/pcie_p2p` |
| P2P works but performance is mediocre | ACS causes THRU_HOST_BRIDGE path | Either disable ACS or set `pcie_acs_override` |
| IOMMU dmesg errors about DMA | `iommu=on` blocking P2P addresses | Use `iommu=pt` or `amd_iommu=off` for bare-metal |
| ROCm 7.x on Fedora: package missing | Not officially supported on Fedora | Use the existing ROCm 7.2.0 install at `/opt/rocm-7.2.0`; containerize if needed |

---

## 8. References

- Linux kernel PCI P2PDMA docs: <https://docs.kernel.org/driver-api/pci/p2pdma.html>
- Linux kernel PCI P2PDMA admin guide: <https://docs.kernel.org/admin-guide/pci/p2pdma.html>
- AMDGPU driver P2P patches: <https://lists.freedesktop.org/archives/amd-gfx/2022-June/079976.html>
- ROCm BAR Memory Guide: <https://rocm.docs.amd.com/en/docs-7.2.2/how-to/Bar-Memory.html>
- ROCm V620 BIOS guide: <https://rocm.docs.amd.com/en/docs-7.2.2/how-to/system-optimization/w6000-v620.html>
- ROCm HIP P2P docs: <https://rocm.docs.amd.com/projects/HIP/en/latest/reference/hip_runtime_api/modules/peer_to_peer_device_memory_access.html>
- K8s Recipes disable ACS: <https://kubernetes.recipes/recipes/ai/disable-acs-pcie-gpu-direct-p2p/>

---

## 9. Changelog

- **2026-08-03**: Initial P2P knowledge base. Synthesized from kernel docs, AMDGPU Kconfig, ROCm docs, and topology requirements research.
