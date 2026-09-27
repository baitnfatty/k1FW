#!/bin/sh
# ==========================================================================
#  Cartographer 3D installer for the 2025 Creality K1C / K1 Max
#  (Ingenic X2600 board  CR4SU200382C13  —  firmware K1C-2025_V1.0.0.x)
#
#  Pairs with probe firmware:  CARTOGRAPHER V4 6.0.0 Lite  (pellcorp's
#  recommendation for K1 series V4 probes)
#  Installs:                   cartographer3d-plugin (the official plugin)
#
#  WHY THIS EXISTS
#  The 2025 board is not the old rootable K1. klippy-env lives on a
#  READ-ONLY squashfs (mmcblk0p7), so `pip install` into it is impossible
#  and the upstream installer cannot be used as-is. This script installs the
#  package into writable /usr/data and points Klipper at it with a scaffold.
#
#  Nothing here touches the bootloader, kernel, or any secure-boot /
#  SCBT-encrypted partition. Fully reversible with --uninstall.
#
#  Requires root (see the C0DEbrained K1C-2025 exploit) and internet.
#  Run ON the printer:   sh install.sh
# ==========================================================================
set -eu

LIB_DIR="/usr/data/cartographer/lib"
KLIPPER_DIR="/usr/apps/usr/share/klipper"
EXTRAS_DIR="${KLIPPER_DIR}/klippy/extras"
SCAFFOLD="${EXTRAS_DIR}/cartographer.py"
PYTHON="/usr/share/klippy-env/bin/python3"
CONFIG_DIR="/usr/data/printer_data/config"
PKG="cartographer3d-plugin"
EXPECTED_BOARD="CR4SU200382C13"

log()  { echo "[*] $*"; }
ok()   { echo "[+] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[-] $*" >&2; exit 1; }

# ---------------------------------------------------------------- checks --
preflight() {
  [ "$(id -u)" -eq 0 ] || die "must run as root"
  [ -x "$PYTHON" ]     || die "klippy python not found at $PYTHON"
  [ -d "$EXTRAS_DIR" ] || die "klipper extras not found at $EXTRAS_DIR"

  board="$(cat /etc/hardware 2>/dev/null || echo unknown)"
  if [ "$board" != "$EXPECTED_BOARD" ]; then
    warn "board is '$board', expected '$EXPECTED_BOARD'."
    warn "This installer targets the 2025 K1C/K1Max. Continuing anyway in 5s..."
    sleep 5
  else
    ok "board $board"
  fi

  # extras must be writable (it is on p8/ext4; p7 squashfs would be read-only)
  touch "${EXTRAS_DIR}/.wtest" 2>/dev/null || die "extras dir is read-only: $EXTRAS_DIR"
  rm -f "${EXTRAS_DIR}/.wtest"
  ok "klipper extras writable"
}

backup_config() {
  [ -f "${CONFIG_DIR}/printer.cfg" ] || { warn "no printer.cfg found; skipping backup"; return 0; }
  stamp="$(date +%Y%m%d_%H%M%S)"
  cp "${CONFIG_DIR}/printer.cfg" "${CONFIG_DIR}/printer.cfg.bak-carto-${stamp}"
  ok "printer.cfg backed up -> printer.cfg.bak-carto-${stamp}"
}

# --------------------------------------------------------------- install --
install_pkg() {
  log "installing ${PKG} into ${LIB_DIR} (klippy-env is read-only)"
  mkdir -p "$LIB_DIR"
  chmod 755 /usr/data/cartographer "$LIB_DIR"   # klippy runs as 'creality' and must traverse
  "$PYTHON" -m pip install --quiet --no-cache-dir --upgrade --target "$LIB_DIR" "$PKG" \
    || die "pip install failed (no internet?)"
  ver="$("$PYTHON" -c "import sys;sys.path.insert(0,'$LIB_DIR');import cartographer;print(cartographer.__version__)" 2>/dev/null || echo '?')"
  chmod -R a+rX /usr/data/cartographer          # root umask leaves these unreadable
  ok "${PKG} ${ver} installed"
}

install_scipy_shim() {
  # Real scipy has no mips32el wheels and cannot realistically be built on
  # this SoC. CARTOGRAPHER_TEMPERATURE_CALIBRATE needs scipy.optimize.curve_fit
  # for fits that are all linear-in-parameters, so extras/scipy_shim provides a
  # numpy-only stand-in (validated against real scipy). Without coil temperature
  # calibration, scan homing DIES ("Toolhead stopped outside model range") once
  # the coil heats past ~60C on an enclosed/heated-bed print.
  local src
  src="$(dirname "$0")/extras/scipy_shim/scipy"
  [ -d "$src" ] || { warn "scipy shim not found at $src - skipping"; return 0; }
  cp -r "$src" "$LIB_DIR/"
  chmod -R a+rX "$LIB_DIR/scipy"
  ok "scipy shim installed (numpy-only curve_fit for TEMPERATURE_CALIBRATE)"
}

remove_legacy() {
  # upstream installer removes these; a stale legacy module shadows the package
  for f in idm.py scanner.py cartographer.py cartographer.pyc; do
    [ -e "${EXTRAS_DIR}/${f}" ] && { rm -f "${EXTRAS_DIR}/${f}"; log "removed legacy ${f}"; }
  done
  rm -rf "${EXTRAS_DIR}/__pycache__/cartographer"* 2>/dev/null || true
}

write_scaffold() {
  cat > "$SCAFFOLD" <<EOF
# cartographer3d-plugin scaffolding - 2025 K1C/K1Max (X2600).
# klippy-env is on a read-only squashfs, so the package lives in /usr/data.
import sys
_LIB = "${LIB_DIR}"
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)
from cartographer.extra import *


# Creality's homing.py (compiled) omits mainline Klipper's check_no_movement()
# call in probing_move, so the "Probe triggered prior to movement" error can
# never be raised on this firmware. The plugin's TOUCH_CALIBRATE relies on
# exactly that error (as ProbeTriggerError) to reject noise-triggering
# thresholds. Restore the guard at our layer instead of touching compiled code.
def _restore_prior_trigger_guard():
    from cartographer.adapters.klipper_like.toolhead import KlipperLikeToolhead
    from cartographer.interfaces.errors import ProbeTriggerError

    _orig = KlipperLikeToolhead.z_probing_move

    def z_probing_move(self, endstop, *, speed):
        start_z = self.get_position().z
        trigger_z = _orig(self, endstop, speed=speed)
        if abs(trigger_z - start_z) < 0.001:
            raise ProbeTriggerError("Probe triggered prior to movement")
        return trigger_z

    KlipperLikeToolhead.z_probing_move = z_probing_move


_restore_prior_trigger_guard()


# Upstream computes the scan-home trigger frequency at a HARDCODED 40C (their
# own TODO admits it). On an enclosed printer with a 100C bed the coil runs
# 60-70C; even with coil temperature calibration saved, the mistargeted
# trigger makes the toolhead halt at a height whose compensated distance falls
# outside the scan model domain -> "Toolhead stopped outside model range" on
# every hot G28 Z. Use the actual coil temperature instead. Harmless without
# a coil calibration (compensation is a no-op then, same as upstream).
def _fix_scan_trigger_temperature():
    from cartographer.probe.scan_mode import ScanMode

    _orig = ScanMode.home_start

    def home_start(self, print_time):
        sample = self._mcu.get_last_sample()
        temp = getattr(sample, "temperature", None) if sample is not None else None
        if temp is None:
            return _orig(self, print_time)
        trigger_frequency = self.get_model().distance_to_frequency(self.probe_height, temperature=temp)
        return self._mcu.start_homing_scan(print_time, trigger_frequency)

    ScanMode.home_start = home_start


_fix_scan_trigger_temperature()
EOF
  chmod 644 "$SCAFFOLD"                         # MUST be world-readable: klippy runs as 'creality'
  ok "scaffold written -> ${SCAFFOLD}"
}

verify() {
  log "verifying import chain against Creality's klippy"
  ( cd "${KLIPPER_DIR}/klippy" && "$PYTHON" -c "
import sys
sys.path.insert(0,'${LIB_DIR}'); sys.path.insert(0,'.')
import cartographer, cartographer.extra
assert hasattr(cartographer.extra,'load_config')
print('    cartographer', cartographer.__version__, 'load_config OK')
" ) 2>/dev/null || die "import verification FAILED"
  ok "import chain verified"
}

show_next_steps() {
  cat <<'EOF'

--------------------------------------------------------------------------
 Installed. Klipper will NOT load Cartographer until you add config.

 1. Find the probe's serial device (should be /dev/ttyACM0):
      ls -l /dev/ttyACM*
    NOTE: this image uses mdev, so /dev/serial/by-id does NOT exist.

 2. Copy the config template you want into your config dir and include it
    from printer.cfg:
      [include cartographer.cfg]

    NOTE - two edits are REQUIRED in printer.cfg (see README):
      * comment out [creality_quick_control]  -> it broadcasts the proprietary
        'quick_ctl_set' command to ALL mcus; Cartographer rejects it and
        Klipper dies with "MCU Protocol error".
      * add 'zero_reference_position' to [bed_mesh] -> required by the plugin,
        and shrink mesh_max so the COIL can reach it.

    coexist.cfg  - keeps Creality's prtouch_v3 as the probe (touchscreen
                   leveling keeps working); Cartographer used for scanning.
                   Uses register_as_probe: False.
    replace.cfg  - Cartographer becomes THE probe (comment out prtouch_v3).
                   Best Cartographer experience; Creality's screen leveling
                   will likely misbehave.

 3. Set x_offset / y_offset to your mount's real measured values.

 4. Restart Klipper, then calibrate (bed HEAT-SOAKED first):
      CARTOGRAPHER_TOUCH_CALIBRATE
      CARTOGRAPHER_SCAN_CALIBRATE
      BED_MESH_CALIBRATE

 After a Creality firmware update, /usr/apps is rewritten - just re-run
 this script (the package in /usr/data survives).
--------------------------------------------------------------------------
EOF
}

# ------------------------------------------------------------- uninstall --
do_uninstall() {
  log "uninstalling"
  rm -f "$SCAFFOLD"; ok "scaffold removed"
  rm -rf "$LIB_DIR"; ok "package removed"
  warn "your printer.cfg was NOT modified - remove any [cartographer] sections"
  warn "and the [include ...] line yourself, then restart Klipper."
}

# ------------------------------------------------------------------ main --
case "${1:-}" in
  --uninstall) preflight; do_uninstall ;;
  --help|-h)   echo "usage: $0 [--uninstall]"; exit 0 ;;
  "")          preflight; backup_config; remove_legacy; install_pkg; install_scipy_shim; write_scaffold; verify; show_next_steps ;;
  *)           die "unknown option: $1" ;;
esac
