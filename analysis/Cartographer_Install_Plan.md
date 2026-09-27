# Cartographer on 2025 K1C + K1 Max (X2600) — Execution Plan

**Target:** Cartographer v4 working on both 2025 printers, same setup on each.
**Strategy:** Prove everything on the **K1C** (already unboxed, expendable-ish). **Do not touch the Max until the K1C works end-to-end.**
**Platform (verified from firmware):** Ingenic X2600, Linux 5.10.186 MIPS, Klipper fork w/ Python 3.8.2.

---

## Verified-good (already confirmed in QEMU — no longer unknowns)

| Requirement | Status |
|---|---|
| `numpy` available to klippy (Cartographer needs it) | ✅ **1.16.4, imports OK** under QEMU |
| `pyserial` (MCU comms) | ✅ 3.4 |
| `python-can` | ✅ 3.3.1 |
| `greenlet`, `jinja2`, `markupsafe` | ✅ present |
| Can a `.py` extra load next to Creality's `.pyc`? | ✅ **proven** — imported a test `scanner.py` from a `.pyc` dir |
| `probe.pyc`, `manual_probe.pyc`, `bed_mesh.pyc` (scanner deps) | ✅ present |
| Writable space for our files | ✅ `/usr/data` (p10, ext4, rw) |
| `scipy` | ❌ **missing** — only matters if the Cartographer version used requires it (most don't) |

---

## THE open question — persistence (must be answered on hardware)

Boot runs `/etc/appetc/init.d/S*` (as **root**) and `CS*` (as **creality**) — from `seed.sh`.
But: `/etc/appetc` → `/usr/apps/etc` → `/usr/deplibs/...` = **the read-only squashfs**.
And **no boot script executes anything from the writable `/usr/data`** (verified by grep).

So the exploit's documented persistence path (`/etc/appetc/init.d/S999persistence`) implies `/usr/apps` is writable on the real device — which contradicts this firmware's `seed.sh` (its `mount_do_apps` is commented out). Possibly a version difference.

**Resolve on-device, in this order (safest first):**
1. Run `mount` + `touch /usr/apps/etc/init.d/.wtest` → is `/usr/apps` a writable ext4 (p8) or RO squashfs?
   - **Writable** → use `S999persistence`-style hook. Clean, done.
2. If RO → look for any other writable, boot-executed hook (moonraker/creality daemon configs).
3. **Fallback (zero-risk, always works):** re-apply the bind-mount from the PC after each boot via a one-line SSH command / small script. Ugly but safe; fine while proving things out.
4. **Last resort (risky):** rewrite the inactive squashfs bank + flip the A/B flag. **Not recommended** — no recovery on this board.

---

## Phase 0 — What I need from you

**Hardware / physical**
- [ ] K1C **plugged in, powered, connected to network (WiFi or ethernet)**
- [ ] K1C **IP address** (touchscreen → Settings → Network, or your router's client list)
- [ ] **Cartographer v4** in hand + a **USB-A→USB-C (or whatever it uses) data cable** — must be a *data* cable, not charge-only
- [ ] Confirm the Cartographer's **RP2040 is already flashed** with Cartographer firmware (usually is from factory; if not, it's flashed from a PC via USB bootloader — easier before mounting)
- [ ] The **printed mount/bracket** for a K1C toolhead (Cartographer needs to sit at a known Z relative to the nozzle)

**Info**
- [ ] K1C **firmware version** (Settings → About). Determines whether the exploit still applies.
- [ ] Whether this K1C is **still glass-modded** or back to the stock plate (changes Z numbers / whether we bother calibrating)

**Decisions**
- [ ] Confirm you accept the **brick risk** (no firmware recovery on this board)
- [ ] Confirm: **Path A** (keep Creality stack, add Cartographer) — recommended
- [ ] Keep `prtouch_v3` as the "face" probe for the Creality UI, and use Cartographer for `[bed_mesh]`? (**recommended** — preserves screen/app leveling) or go full Cartographer-as-Z-probe (cleaner Klipper, more UI breakage)

**From me (nothing needed from you)**
- I have the full firmware extracted, both printers' stock `printer.cfg` (K1C 220×220, Max 300×300), the QEMU environment, and the exact paths/offsets.

---

## Phase 1 — Recon (no changes to printer)

1. Power on K1C, get on network, note IP.
2. Confirm firmware version; compare against exploit's supported range.
3. **Do NOT update firmware** — a newer version may patch the `wsslicer` hole and lock root out permanently.
4. From PC: confirm the printer answers on **port 9999** (the `wsslicer`/`vectorp` service) and 80/4408 (Fluidd/Moonraker).
5. Record stock state: current `printer.cfg`, firmware version, whether Fluidd is reachable.

## Phase 2 — Root

1. **Review the C0DEbrained exploit script before running it** (I'll read it line by line — it's third-party code that runs as root on your device).
2. Generate an SSH keypair on the PC for the printer.
3. Run the exploit (needs: your PC's IP, printer IP, your pubkey). It serves a payload on :4444 and pokes :9999.
4. Verify `ssh root@<printer>` works.
5. **Immediately** answer the persistence question (`mount`, write-test `/usr/apps`).
6. **Snapshot before changing anything:**
   - `dd` copies of key partitions (p1 OTA flag, p2 sn_mac) to the PC
   - full copy of `/usr/data`
   - `mount`, `dmesg`, `lsusb`, `cat /proc/cmdline`, partition table
   - This is our only "undo" — there's no vendor recovery.

## Phase 3 — Cartographer on the K1C

1. **Plug in Cartographer**, confirm it enumerates:
   `ls /dev/serial/by-id/`, `ls /dev/ttyACM*`, `dmesg | grep -i -E "cdc_acm|ttyACM"`
   (base image uses `mdev` — `by-id` symlinks may not exist; we may need the raw node or an mdev rule)
2. Stage a writable klippy extras dir under `/usr/data`, drop in Cartographer's `scanner.py` (+ any deps), and **`mount --bind`** it over `/usr/share/klipper/klippy/extras/` (no overlayfs in this kernel — bind is the mechanism).
3. **Compatibility test** — this is the real technical risk: Creality's klippy is a *fork* (compiled `.pyc`, ~Klipper 0.12-era based on the extras present). Cartographer's `scanner.py` hooks into `probe`/`bed_mesh` internals; a fork API mismatch may need patching. Test by starting klippy and reading the log.
4. Add config to `/usr/data/printer_data/config`:
   - `[scanner]` (serial/by-id, x_offset/y_offset from the mount, `mesh_runs`)
   - `[bed_mesh]` for K1C: mesh area within 220×220 (stock is `mesh_min 10,10` / `mesh_max 210,210`)
   - Decide `prtouch_v3` coexistence per your Phase-0 choice
5. **Protect from the config re-seed:** `CS55klipper_service` overwrites `printer.cfg` when the default's `# Version:` differs (keeps only the `SAVE_CONFIG` block). Bind-mount a modified *default* so re-seeds carry our config, or neutralize that logic.
6. Calibrate: Cartographer touch/Z-offset → `BED_MESH_CALIBRATE` **after full heat-soak** (that's what beats the aluminum warp).
7. Test print. Verify Orca→Moonraker→Fluidd path and check the touchscreen still behaves.

## Phase 4 — Clone to the K1 Max

**Only after the K1C is fully working and stable.**
1. Unbox, power on, **capture firmware version BEFORE connecting to Creality cloud / accepting updates**.
2. Same root → same injection → same files.
3. Change only the geometry: bed **300×300×300** (X max 306.5, Y 306, Z 305) → mesh area and scanner offsets scale up. Stock Max profile is `k1max-x2600-cfs-c` (already extracted).
4. Re-run calibration on that machine (offsets are per-machine).

---

## Risks (stated plainly)

- **No firmware recovery.** A bad flash of a protected partition = dead printer. Our plan never writes kernel/bootloader/verified partitions — that's deliberate.
- **Exploit may be patched** in newer firmware → root before updating, and don't update casually.
- **Creality fork API mismatch** could require real patching of `scanner.py`. Most likely failure mode, but it's a software problem, not a brick.
- **Touchscreen leveling UI** may misbehave if Cartographer replaces `prtouch` as Z probe (mitigated by keeping `prtouch` as the UI-facing probe).
- Persistence may end up being the manual re-apply fallback until we find a proper hook.
