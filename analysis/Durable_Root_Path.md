# A durable, exploit-independent root path for the 2025 K1C / K1 Max (Ingenic X2600)

**Status: the OTA update path is fully reverse-engineered and demonstrated forgeable — verified against the printer's own validator running under QEMU.**

Goal: give owners a way to run their own firmware on hardware they own, that survives Creality patching the `wsslicer` RCE.

---

## 1. The complete device-side validation chain

`quintusp` (the update daemon) shells out to **`/bin/upgchck.sh`**. That script *is* the gate, in full:

```sh
[ -f "${upgfile}" ] || exit 1                                  # 1. file exists
grep -c 'rootfs-app.*ext4$' "${upgfile}" -gt 0 && exit 1        # 2. reject one legacy image type
upgbox -C -f "${upgfile}" -A || exit 1                          # 3. THE ONLY REAL CHECK
# then: write /usr/data/upgrade/state {action:upg, mode, path, date}; reboot
```

At next boot `seed.sh` → `upg_do()`:
```sh
upgbox -U -f "$upgfile" -t "$disktype" -p "$partlist" -l "$log"
echo "${newjump}" > /dev/mmcblk0p1      # flip A/B flag on success
```

**What is NOT checked, anywhere:**
- ❌ No digital signature — **`upgbox` links only `libc`** (no libcrypto/libssl, no embedded public key found anywhere in the app binaries)
- ❌ No version comparison / anti-rollback (`upg_check_flag` only parses `action:`/`mode:`/`path:`/`date:` from a plain text file)
- ❌ No model/board gating
- ✅ Only: **CRC32** integrity + partition size sanity

`upgbox` ships **unstripped with debug_info** — symbols include `check_head_info`, `check_image_info`, `check_node_info`, `crc32_table`, `hd_crc32`.

---

## 2. OTA package format (verified byte-exact)

**Header** (little-endian):

| Offset | Type | Field |
|---|---|---|
| 0x000 | char[128] | package filename |
| 0x080 | char[64] | description (`Creality x2600 software`) |
| 0x0C0 | char[64] | build stamp (`20251225153931`) |
| 0x100 | char[32] | version (`V1.1.0.27.20251225`) |
| 0x128 | u64 | total package size (== file size) |
| 0x130 | u32 | node count |
| 0x134 | u32 | write mode |
| 0x138 | u32 | **header CRC32 = `crc32(bytes[0x000:0x138])`** |

**Node records** — start `0x13C`, stride `0xE0` (224 B), one per image:

| Offset | Type | Field |
|---|---|---|
| +0x00 | char[128] | image filename |
| +0x80 | char[64] | target partition (`mmcblk0p7`) |
| +0xC0 | u64 | payload size |
| +0xC8 | u64 | payload offset (absolute in package) |
| +0xD0 | u64 | write offset into partition |
| +0xD8 | u32 | **image CRC32 = `crc32(payload)`** |
| +0xDC | u32 | **node CRC32 = `crc32(record[0x00:0xDC])`** ← covers the image CRC |

All CRCs are **standard `zlib.crc32`**. Node records are *not* covered by the header CRC, so editing a node only requires fixing that node + (optionally) the size field.

**Fix order when repacking:** image CRC → node CRC → header CRC.

---

## 3. Proof (executed, not theorised)

Using `qemu-mipsel-static` + the firmware's own `/bin/upgbox` in a chroot:

| Test | Result |
|---|---|
| Stock firmware → `upgbox -C -f … -A` | **exit 0**, dumps full package info |
| Flip 1 byte in the p7 rootfs payload, CRCs untouched | **exit 255** — `[ERROR] Check index 4 image mmcblk0p7 no pass` |
| Same tampered payload, CRCs recomputed with our tool | **exit 0 — ACCEPTED** |

Conclusion: **arbitrary modified firmware is accepted by the device's own validator provided the CRCs are consistent.** No key material required.

Tool: `analysis/tools/ota_tool.py` (`info` / `extract` / `replace` / `fixcrc`).

---

## 4. The safe build: rootfs-only package

The kernel is the one component that *might* be covered by secure boot (unresolved — see report §9.2; the bootloader isn't shipped in the OTA so it can't be checked from these files).

**Therefore: never touch p5/p6 (kernel) or the bootloader.** Build a package containing **only the rootfs nodes (p7/p8)**:

- `upgbox -U` takes `-p <partlist>`, and `seed.sh` passes only the inactive bank's partitions — so a rootfs-only package is written to the **inactive bank**, leaving the running bank intact as fallback.
- This sidesteps the secure-boot question entirely: even if u-boot verifies the kernel, we never modify the kernel.
- A/B means a bad rootfs still leaves the other bank bootable (recovery via the A/B flag in `mmcblk0p1`).

**Payload size constraint:** node payload offsets are absolute, so the simplest safe edit keeps the **new squashfs the exact same size** as the original (pad to size). A full repacker that recomputes offsets is straightforward but must rewrite every following node's `off`.

---

## 5. What goes *in* the modified rootfs

Anything you want, since `/usr` is that squashfs. For a root-enabling image:
- `authorized_keys` for dropbear / enable root SSH
- a boot hook in `apps/etc/init.d/` (this is the read-only squashfs — which is exactly why baking it in here **solves the persistence problem** that bind-mounts only work around)
- the Cartographer `scanner.py` in `klippy/extras/`
- a modified default `printer.cfg` so the `CS55klipper_service` re-seed can't strip our config

---

## 6. Remaining unknowns (must be answered on hardware)

1. **How the USB update is triggered** — what filename/location the touchscreen UI looks for on the stick, and whether `quintusp`/the UI applies any check *before* calling `upgchck.sh`. (`upgchck.sh` itself is unconditional.)
2. Whether the cloud/OTA path adds a server-side checksum (irrelevant for USB, which is our path).
3. Whether `upgbox -U` tolerates a package whose node list is a *subset* of `partlist` (the `# Check index %d image %s skip` string suggests yes).
4. Secure-boot scope — settle by dumping u-boot off eMMC.

**`upgbox -m/--mimic` performs a dry-run upgrade with no disk writes** — use it on-device to rehearse safely before a real flash.

---

## 7. Honest risk statement

- This bypasses **no cryptography** — there is none on this path. It is an integrity check, not an authenticity check.
- **There is no vendor recovery.** A/B banking is the only safety net; keep the good bank intact and never include kernel/bootloader nodes.
- Test every package with `upgbox -C` under QEMU *before* it goes near a printer, then `upgbox -m` on-device.
- Filenames containing `V9.9.9.99` trigger `clear_userdata` (factory wipe) in `upg_do` — avoid that string unless you want it.
