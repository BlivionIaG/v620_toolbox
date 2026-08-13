# v620_toolbox

A guide per feature for the AMD Radeon PRO V620 (gfx1030) on Fedora + AMD CPU:

| Folder | Feature | Status |
|---|---|---|
| [`pcie_p2p/`](pcie_p2p/) | GPU↔GPU PCIe Peer-to-Peer (P2P) aperture | ✅ validated on Fedora 43, kernels 6.17.6 (pre-7) + 7.1.7 (post-7) |
| [`powertuning/`](powertuning/) | Lower V620 power cap to 120 W floor + 180 W boot cap | ✅ validated on Fedora 43, same kernel matrix |

Each feature has its own `README.md` with the full recipe, prerequisites, and verification steps. Follow them in either order.

## License

GPL-3 (see [LICENSE](LICENSE)). Kernel patches in `powertuning/patches/` are derivative works of the Linux kernel source (GPL-2.0); see [NOTICE](NOTICE) for per-file licensing.

## Repo conventions

See [AGENTS.md](AGENTS.md) for what belongs where, what "validated" means, and how to extend a feature.
