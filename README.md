This Repository contains a deep firmware analysis and some tooling to allow for Firmware repacking of creality  stock  "2025"
firmware used on the K1 series. 

With the provided you should be able to get a stock creality printer setup with a cartographer3d by simply running the install script which gives you access to the fluidd webpage and full root persistence,. 




# K1FW — 2025 Creality K1C / K1 Max (Ingenic X2600) firmware research
This repo is setup for an agentic install of the stock creality firmware with minor changes that allow the use of cartagrapher3D on the 2025 platform. 

Reverse-engineering notes, tooling, and a working Cartographer-probe enablement
package for the **2025-revision** Creality K1C and K1 Max — the Ingenic
**X2600** board (`CR4SU200382C13`, firmware `K1C-2025_V1.0.0.x`). These are
*not* the older rootable K1 boards; the usual community tools do not apply.

---

## Repository layout

```
analysis/
  K1C_Firmware_Review.md       # the security review: partitions, boot, integrity model
  Durable_Root_Path.md         # OTA format (byte-exact) + why modified firmware validates
  Cartographer_Install_Plan.md # end-to-end plan to add Cartographer on the 2025 board
  tools/ota_tool.py            # info/extract/replace/fixcrc for the X2600 OTA package
  rootfs/, extract/            # extracted stock firmware (analysis substrate)
  cartographer/                # probe integration analysis + drafts
  live_k1c/, live_k1max/       # sanitized on-device configs and logs (no backups)
  exploit_review/, homing_patch/, wsshim/, fluidd/, scbt/, c13/, notes/
k1-2025-cartographer/          # the installable Cartographer package (see its README)
```

---

## Firmware inputs (obtain these yourself)

The two stock OTA images the analysis is built against are gitignored. Download the matching release
from Creality for your board, then verify:

| file | version | SHA256 |
|------|---------|--------|
| `CR4CU220812S11_ota_img_V2.3.5.34.img` | 2.3.5.34 (AES-256 7z) | `5c2716f437909446299498eeeb1bd86b02baad4c561d7a5bbf45fa2fa87fe149` |
| `CR4CU220812S12_ota_X2000E_V1.1.0.27.20251225.img` | X2000E V1.1.0.27.20251225 (Creality OTA wrapper) | `a9c6a3cb46d5dff71061125563455b842dd5736999b7e6037ced77a3c3e3c350` |

Place them at the repo root. The `S12` (1.1.0.27) image is the primary subject;
the `S11` (2.3.5.34) image is encrypted and used only for comparison.


---

## The two halves

### 1. Firmware: understand and (optionally) repack

Start with [`analysis/K1C_Firmware_Review.md`](analysis/K1C_Firmware_Review.md)
for the partition map, boot chain, and integrity model, then
[`analysis/Durable_Root_Path.md`](analysis/Durable_Root_Path.md) for the OTA
package format and the update-path analysis (verified against the device's own
`upgbox` validator under qemu-mipsel).

`analysis/tools/ota_tool.py` reads and rewrites the X2600 OTA package:

```sh
python3 analysis/tools/ota_tool.py info    <pkg.img>
python3 analysis/tools/ota_tool.py extract <pkg.img> <outdir>
python3 analysis/tools/ota_tool.py replace <pkg.img> <mmcblk0pN> <newpayload> <out.img>
python3 analysis/tools/ota_tool.py fixcrc  <pkg.img>
```

A safe repack modifies **only the rootfs nodes** and is written to the inactive
A/B bank, leaving the running bank as fallback — never touch the kernel or
bootloader. See `Durable_Root_Path.md` §4–5.

### 2. Cartographer probe on the 2025 board

The installable package lives in
[`k1-2025-cartographer/`](k1-2025-cartographer/) — read its `README.md`. In
short: root the printer, `sh install.sh` (needs internet once), copy the config
templates, add the `[include ...]` lines, and calibrate. After a Creality
firmware update rewrites `/usr/apps`, `sh reapply.sh` re-lays everything
offline. Planning and on-device decisions are in
[`analysis/Cartographer_Install_Plan.md`](analysis/Cartographer_Install_Plan.md).

---


