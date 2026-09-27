# Cartographer 3D on the 2025 Creality K1C / K1 Max

Installs the official **[cartographer3d-plugin](https://github.com/Cartographer3D/cartographer3d-plugin)** on the **2025-revision** K1C / K1 Max — the Ingenic **X2600** board (`CR4SU200382C13`, firmware `K1C-2025_V1.0.0.x`).

These are *not* the old rootable K1 boards. **SimpleAF, the Guilouz helper script, and the upstream Cartographer installer do not work here.** This package bridges that gap.

> **Verified working end-to-end** on a real K1C: board `CR4SU200382C13`, firmware `K1C-2025_V1.0.0.22.20250711S`, probe firmware `CARTOGRAPHER V4 6.0.0 Lite`, plugin `1.8.0`.
> Result: non-contact Z homing, scan-based bed mesh, survives reboot.

---

## Prerequisites

1. **Root.** Use the [C0DEbrained K1C-2025 exploit](https://github.com/C0DEbrained/Creality-K1C-Tools). Root *before* updating firmware — a newer release may patch the `wsslicer` hole, and there is **no downgrade and no vendor recovery** on this board.
2. **Probe firmware: `CARTOGRAPHER V4 6.0.0 Lite`** — pellcorp's recommendation for K1-series V4 probes. "Lite" is the low-spec-host build, which matters on this SoC (2-core MIPS, ~200 MB RAM).
3. **Internet on the printer** (for `pip`).

⚠️ **Do not use the legacy `cartographer-klipper` module.** It is scan-only (no `CARTOGRAPHER_TOUCH_*`) and tracks firmware 5.1.x. With 6.0.0 you need `cartographer3d-plugin`.

---

## Install

```sh
# on the printer, as root
sh install.sh
```

Then copy the config files and add the includes to `printer.cfg`:

```ini
[carto_prtouch_shim]
[include cartographer.cfg]
[include cartographer_macros.cfg]
[include safe_wipe.cfg]
```

> `safe_wipe.cfg` re-plugs the start-of-print nozzle wipe: Creality's compiled
> `START_PRINT` (and `G29`) call `NOZZLE_CLEAR`, which was registered by the
> disabled prtouch module — without this file, prints start with **no wipe**.
> Measure your pad position/height and set the `_WIPER_PARAMS` variables
> (defaults are the stock strip location with a deliberately-high `wipe_z`).

Set `x_offset` / `y_offset` for your mount (see `mounts/mounts.tsv`), then calibrate.

Uninstall: `sh install.sh --uninstall`

## Re-apply after a firmware update / re-seed

**A normal reboot needs nothing** — it all persists. The plugin, shims and your
config live on `/usr/data` (p10), and the klippy extras + boot hooks that
`install.sh` writes into `/usr/apps` stay put because on the real 2025 board
`/usr/apps` is a **writable ext4 partition (p8)**, not the read-only squashfs.

The one event that wipes them is a Creality **firmware update / re-seed**, which
rewrites `/usr/apps` from the new image: it destroys the klippy extras (scaffold
+ `carto_prtouch_shim.py` + `carto_shell_command.py`) and the `S97dbshim` /
`S98fluidd` boot hooks (and can reset `printer.cfg` via `CS55klipper_service`).
To lay those back down in one command, **offline** (no pip/internet):

```sh
sh reapply.sh
```

Keep this whole directory on the printer under `/usr/data` (e.g.
`/usr/data/k1-2025-cartographer`) so the script and its sources survive a
firmware update too. `reapply.sh` restores the cartographer scaffold from a persistent
cache, re-copies the custom extras and boot hooks, ensures the `printer.cfg`
include lines are present (backing it up first), verifies the import chain, and
restarts Klipper. First-time setup still needs internet: run `sh install.sh`
(plus the wsshim/fluidd installers) once.

---

## ⚠️ The five blockers nobody documents

Every one of these was hit on a real machine. They are the reason this package exists.

### 1. Permissions — klippy runs as `creality`, not root
Root-created files land as `0600` / `0700`, so klippy can't read them:
```
Permission denied: '.../klippy/extras/cartographer.py'
```
Needs `chmod 644` on the scaffold and `chmod 755` on `/usr/data/cartographer` (the *parent* — `chmod -R` on `lib/` alone is not enough; the parent blocks traversal). Handled by `install.sh`.

### 2. USB baud — `cdc_acm` rejects Klipper's default
```
Failed to set custom baud rate (250000): [Errno 25] Inappropriate ioctl for device
```
This kernel's `cdc_acm` won't take 250000. Use **`baud: 115200`** in `[mcu cartographer]`. USB CDC ignores the rate anyway.

### 3. `[creality_quick_control]` must be disabled
It broadcasts the proprietary `quick_ctl_set` command to **every** MCU. Cartographer rejects it:
```
MCU Protocol error - mcu 'cartographer': Unknown command: quick_ctl_set
```
Comment out `[creality_quick_control]`. **This blocks *any* third-party MCU on this firmware.** Costs you `QUICK_MCU_STOP/RESUME/QUERY` and `CLEAN_HOME`.

### 4. `[bed_mesh]` needs `zero_reference_position`, and a reachable `mesh_max`
The plugin requires `zero_reference_position` (no default); stock config lacks it. Also the **coil** must reach every mesh point, not the nozzle — so shrink `mesh_max` by your offset. With `y_offset: -22`, probing bed Y=200 needs the nozzle at Y=222 (limit 225).

### 5. Creality's `homing.py` hard-requires `prtouch_v3` → **use the shim**
This is the big one. Decompiling `homing.pyc` shows:
```python
self.prtouch_v3 = printer.lookup_object("prtouch_v3", None)   # optional lookup
...
if rails[0].get_name() == "stepper_z":
    self.prtouch_v3.mcu_probe.pres.set_homeing_tri(0)         # NO None check
```
The lookup is guarded; the **use is not**. Disable `[prtouch_v3]` and every `G28` dies:
```
AttributeError: 'NoneType' object has no attribute 'mcu_probe'
```
`extras/carto_prtouch_shim.py` registers a stand-in `prtouch_v3` exposing the only three attributes Creality's homing touches (`mcu_probe.pres.set_homeing_tri()`, `mcu_probe.pres.tri_hold`, `mcu_probe.z_full_movement_flag`) as no-ops. Safer than replacing compiled motion code.

---

## coexist vs replace — **you must use replace**

| | coexist (`register_as_probe: False`) | **replace (`True`)** |
|---|---|---|
| Bed mesh | ❌ **prtouch — touches every point** | ✅ **Cartographer scan** |
| Z homing | prtouch (nozzle tap) | ✅ **non-contact scan** |
| Creality touchscreen leveling | works | breaks |
| `G28` | works | works **only with the shim** |

**Coexist does not give you scan meshing.** `prtouch_v3`'s endstop wrapper registers `BED_MESH_CALIBRATE` and wins over Cartographer's, so the mesh probes by touching. Cartographer registers it with `use_prefix=False`, so there is no alternate command name to call instead.

To use replace mode: install the shim, comment out `[prtouch_v3]`, add `homing_retract_dist: 0` to `[stepper_z]`, set `register_as_probe: True`.

> Comment out the **whole** `[prtouch_v3]` block (~26 lines). Commenting only the header orphans its options into the previous section.

---

## Calibration

**Scan first** — the paper test sets Z=0, which gives touch a safe reference. Touch-first risks driving the nozzle into the bed.

```
CARTO_A_SCAN_CALIBRATE     # interactive paper test -> saves scan model
CARTO_D_SAVE               # SAVE_CONFIG (restarts Klipper)
CARTO_C_BED_MESH           # scan the bed
CARTO_D_SAVE
```

Touch is **optional** — the scan model is all `BED_MESH_CALIBRATE` needs. If you do run touch: nozzle **clean and below 150 °C**, Z homed first, and consider capping the threshold sweep (`CARTOGRAPHER_TOUCH_CALIBRATE MAX=1500`) so a failed detection can't escalate to full force.

**Macro names must not contain digits.** Creality's gcode parser truncates them — `CARTO_1_SCAN_CALIBRATE` fails as `Unknown command:"CARTO_1"`. Hence the A/B/C/D naming.

---

## Touch mode: the ~3mm false-trigger zone (glass-modded beds)

Debugged on a real K1C with a glass sub-bed mod (PEI flex plate → mag pad → glass → aluminum, bed on springs). The glass gap moves the aluminum ~4mm further from the coil, distorting the frequency→distance curve in the mid-range. The probe firmware detects touch as *"distance stopped decreasing"* — and on this bed the distorted curve produces exactly that signature around **~3mm above the plate**.

The observed rule (all verified on-device):

| Touch descent starts at | Result |
|---|---|
| ≤ 2.5mm | ✅ real contact |
| ~3–6mm | ❌ false trigger at ~2.9mm, never touches |
| ≥ 10mm | ✅ real contact (enough run-up for the detector to converge) |

This is why stock `CARTOGRAPHER_TOUCH_HOME` failed while `TOUCH_PROBE` / `TOUCH_ACCURACY` / `TOUCH_CALIBRATE` worked: those all descend from the 2.0mm scan-park height, but TouchHome hops +2 first and descends from ~4.0 — inside the bad zone. **`CARTO_TOUCH_HOME` therefore scan-homes Z, moves to the zero-reference point, drops to Z0.5, and only then calls the plugin** (its +2 hop lands the descent start at 2.5).

**After any calibration or bed-stack change, run `CARTO_TOUCH_VERIFY`.** It scan-homes (bed = Z0 by definition), touch-probes from the safe zone, and errors if the touch reads more than 0.3mm off the bed. `TOUCH_CALIBRATE`'s only acceptance criterion is sample *consistency* — mid-air false triggers are perfectly consistent, so a calibration can "succeed" without ever touching. This macro is the missing absolute check.

**`BED_MESH_CALIBRATE METHOD=touch` is not implemented upstream** ([their docs](https://docs.cartographer3d.com/cartographer-probe/features/touch) say so). It silently falls back to Klipper's native point-by-point mesh driven by the plugin's *contactless scan* probe object — it will never touch, by design. Scan mesh (`CARTO_C_BED_MESH`) is the only mesh; touch's job is just true Z=0 via `CARTO_TOUCH_HOME`.

### Coil temperature calibration is MANDATORY on heated/enclosed prints

Without it, scan measurements go **out of the scan model's domain once the
coil heats past ~55–60 °C** (enclosed chamber + 100 °C bed gets there easily)
and every scan home dies mid-print with:

```
{"code": "XS2000", "msg": "Toolhead stopped outside model range"}
```

The scan model is calibrated at one reference temperature (~44 °C here); with
no coil compensation the frequency→distance mapping is applied raw, and hot
frequencies fall outside the calibrated domain → `inf` → error. The first G28
of a print works (machine still cool); re-homes 20 minutes in fail. A stale
hot mesh is also silently wrong — a likely cause of "purge sticks but parts
lift".

Fix: run `CARTO_TEMPERATURE_CALIBRATE` once (start with the machine cool,
bed off; it heat-cycles the bed and fits the compensation), then `SAVE_CONFIG`.
Upstream requires `scipy.optimize.curve_fit` for the fit, which doesn't exist
for this MIPS SoC — `extras/scipy_shim/` provides a numpy-only stand-in
(every fitted function is linear-in-parameters; validated against real scipy).
`install.sh` installs it automatically.

Two latent Creality-firmware hazards found while debugging (both now handled):

1. **Creality's compiled `homing.py` silently suppresses "No trigger on z after full movement"** whenever a `prtouch_v3` object exists (bytecode-verified: `if self.prtouch_v3 is not None and name == 'z': error = None`) — and the shim makes it exist. A failed Z homing move would look like success. The shim now logs a loud warning when this branch fires (it sets `z_full_movement_flag = True`, which the shim traps).
2. **Creality's `probing_move` omits mainline's `check_no_movement()`**, so `"Probe triggered prior to movement"` — which `TOUCH_CALIBRATE` relies on (as `ProbeTriggerError`) to reject noise thresholds — could never fire. The scaffold now restores this guard around `z_probing_move`.

---

## Other gotchas

- **A wedged Cartographer MCU needs a full power cycle.** After a mid-homing crash it stops answering (`Unable to connect` / `Wait for identify_response`). A soft reboot or Klipper restart will **not** clear it — the probe stays powered over USB.
- **`/dev/serial/by-id` does not exist** (this image uses `mdev`, not udev). Use `/dev/ttyACM0`; the only other USB device is the internal `CREALITY CAM`, a video device.
- **Fluidd is not installed** on this firmware — the symlink is dangling and the init dir is empty. See `fluidd/` for serving it on `:4408` via the nginx already on the box.
- **Fluidd's "Moonraker Database" panel — FIXED by `wsshim/`.** Creality's `nexusp` (a closed C reimplementation of Moonraker) returns **403 "Method unimplemented"** for `database.list`, `compact`, `post_backup`, `delete_backup` and `restore`, so the System page's namespace list and its Create Backup / Compact buttons are all dead.
  `nexusp` is a stripped MIPS binary, SCBT-encrypted at rest and decrypted into tmpfs at boot, so the methods cannot be added to it. Instead `wsshim/moonraker-db-shim.py` is a **transparent websocket proxy** that implements those five methods and relays everything else untouched — to Fluidd they simply exist, and the native buttons work.
  ```
  vectorp (touchscreen) ───────────────────────> nexusp:7125    (UNCHANGED)
  Fluidd ──> nginx:4408 ──> db-shim:4409 ──────> nexusp:7125
  ```
  Creality's own services are **not** in this path — the touchscreen talks to `nexusp` directly on localhost. nginx lists `nexusp` as a **backup upstream**, so if the shim dies Fluidd falls straight through: the five methods go back to failing, the UI keeps working (verified by killing the shim mid-session).
  Hardened: loopback-only bind, sqlite work off the event loop, path-traversal refused on every filename, and compact/restore refuse to run mid-print (as Moonraker does). Install with `wsshim/install-shim.sh`; starts at boot via `S97dbshim` (before `S98fluidd`).
- **A Creality firmware update rewrites `/usr/apps`**, removing the scaffold and shim. The package in `/usr/data` survives — re-run `install.sh`. Root is not persistent across updates either.

---

## Why not the upstream installer

`klippy-env` is on **`/dev/mmcblk0p7`, a read-only squashfs**, so `pip install` into it is impossible.

| Path | Device | Mode |
|---|---|---|
| `/usr/deplibs` (→ `/usr/share`, `klippy-env`) | `mmcblk0p7` | **squashfs, read-only** |
| `/usr/apps` (→ Klipper, `klippy/extras`) | `mmcblk0p8` | ext4, **writable** |
| `/usr/data` | `mmcblk0p10` | ext4, **writable** |

So this installer `pip install --target`s into `/usr/data/cartographer/lib` and writes a scaffold in `klippy/extras/` that prepends that path before upstream's `from cartographer.extra import *`.

**Nothing touches the bootloader, kernel, or any secure-boot / `SCBT`-encrypted partition.**

### Compatibility (verified on device)

| Requirement | Cartographer K1 CI wants | 2025 K1C has |
|---|---|---|
| Python | ≥3.8 | 3.8.2 ✓ |
| numpy | 1.16.4 | 1.16.4 ✓ |
| pyserial | 3.4 | 3.4 ✓ |
| greenlet | 0.4.15 | 0.4.15 ✓ |
| scipy | *not required on K1* | absent ✓ |

---

## Credits

- [Cartographer3D](https://github.com/Cartographer3D) — probe, firmware, plugin
- [C0DEbrained](https://github.com/C0DEbrained/Creality-K1C-Tools) — 2025 root exploit and board docs
- [pellcorp](https://pellcorp.github.io/creality-wiki/cartographer/) — K1-series firmware guidance and mount offsets
