# patches/

The V620 powerfix patch. Single canonical file — matches the V620 model ID
(subsystem `1002:0e34`) and works for any number of V620s in the host
regardless of physical slot.

## Files

| File | Purpose |
|---|---|
| `v620-powercap-min-120W.patch` | Canonical patch. Lowers the kernel's `min_power_limit` clamp to 120 W for any V620 reference board. |

## What the patch does

A 4-line clamp in `sienna_cichlid_get_power_limit()` (in
`drivers/gpu/drm/amd/pm/swsmu/smu11/sienna_cichlid_ppt.c`) that lowers
`min_power_limit` from the VBIOS-declared 250 W to 120 W when the device
matches the V620 PCI ID.

The match is on **subsystem_device `0x0e34`**, not on the physical BDF
(bus:slot.function). A single patch text covers every V620 in the host.

## Identity match string

The patch matches on:

| Field | Value |
|---|---|
| Vendor | `0x1002` (AMD) |
| Device | `0x73a1` (Radeon PRO V620) |
| Subsystem vendor | `0x1002` (AMD) |
| Subsystem device | `0x0e34` (V620 reference board) |
| Revision | `0x00` |

Other gfx1030 cards (RX 6900 XT, RX 6800/6800 XT — device `0x73bf`,
different subsystem IDs) are not matched.

## What the patch does NOT do

- It does **not** touch the V620's VBIOS.
- It does **not** write `pp_table` or `pp_features` (those wedge the SMU).
- It does **not** flash a custom VBIOS.
- It does **not** write a soft PowerPlay table.
- It does **not** enable OverDrive (the `cap[0..3]` flags stay zeroed).

The patch only relaxes the kernel's min_power_limit clamp. The SMU was
always willing to accept values below 250 W; the kernel was the gate.

## Why no BDF variants

A separate patch per (BDF, floor) pair is unnecessary: the match string
is on subsystem_device, so one patch text covers every V620 regardless of
physical slot. For a different floor wattage, edit the constant in the
canonical patch (`min_power_limit = 120U`); for a different card model,
edit the PCI ID match string.
