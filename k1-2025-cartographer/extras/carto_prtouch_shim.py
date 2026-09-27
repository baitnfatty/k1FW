# ==========================================================================
#  prtouch_v3 shim  —  2025 Creality K1C / K1 Max (X2600)
#
#  WHY THIS EXISTS
#  Creality patched Klipper's homing.py to poke prtouch during Z homing:
#
#      self.prtouch_v3 = printer.lookup_object("prtouch_v3", None)
#      ...
#      if rails[0].get_name() == "stepper_z":
#          self.prtouch_v3.mcu_probe.pres.set_homeing_tri(0)   # <-- no None check
#
#  The lookup has a default, but the USE does not guard against None. So if
#  you disable [prtouch_v3] (required to let Cartographer own the 'probe'
#  object and do scan-based meshing), every G28 dies with:
#
#      AttributeError: 'NoneType' object has no attribute 'mcu_probe'
#
#  Rather than replace the compiled homing.pyc (core motion code, and the
#  only source we have is an unreliable decompile), we register a stand-in
#  object under the name 'prtouch_v3' exposing exactly the three attributes
#  Creality's homing touches. They are no-ops: with no strain-gauge probe
#  present there is no trigger threshold to set.
#
#  Attribute surface required (verified by decompiling homing.pyc):
#      prtouch_v3.mcu_probe.pres.set_homeing_tri(int)
#      prtouch_v3.mcu_probe.pres.tri_hold
#      prtouch_v3.mcu_probe.z_full_movement_flag
#
#  Install:  copy to  /usr/apps/usr/share/klipper/klippy/extras/
#            chmod 644   (klippy runs as the 'creality' user)
#  Enable:   add  [carto_prtouch_shim]  to printer.cfg
#  Remove:   delete the config section; nothing else references it.
# ==========================================================================

import logging


class _PresShim:
    """Stands in for prtouch's pressure-sensor handle."""

    # read by homing.py as `old_tri_hold` and restored later
    tri_hold = 0

    def set_homeing_tri(self, value):
        # Real prtouch adjusts strain-gauge trigger sensitivity for homing.
        # With no strain gauge in the loop this is intentionally a no-op.
        logging.debug("carto_prtouch_shim: set_homeing_tri(%s) ignored", value)

    def __getattr__(self, name):
        # Be forgiving if a firmware revision reaches for something else,
        # so a future Creality update degrades instead of crashing G28.
        logging.info("carto_prtouch_shim: unhandled pres attribute %r", name)
        return _noop


class _McuProbeShim:
    """Stands in for prtouch's mcu_probe."""

    def __init__(self):
        self.pres = _PresShim()
        self._z_full_movement_flag = False

    @property
    def z_full_movement_flag(self):
        return self._z_full_movement_flag

    @z_full_movement_flag.setter
    def z_full_movement_flag(self, value):
        if value:
            # Creality's homing_move sets this True at the exact moment it
            # SUPPRESSES a "No trigger on z after full movement" error
            # (verified by bytecode disassembly of homing.pyc - the branch is
            # `if self.prtouch_v3 is not None and name == 'z': error = None`).
            # A Z homing move just finished WITHOUT the probe triggering, and
            # Klipper thinks it homed. Z is NOT trustworthy after this.
            logging.warning(
                "carto_prtouch_shim: Creality homing.py suppressed a "
                "'No trigger on z after full movement' error - a Z homing "
                "move completed without the probe triggering! Z position "
                "is NOT trustworthy; re-home before printing."
            )
        self._z_full_movement_flag = value

    def __getattr__(self, name):
        logging.info("carto_prtouch_shim: unhandled mcu_probe attribute %r", name)
        return _noop


def _noop(*args, **kwargs):
    return None


class CartoPrtouchShim:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.mcu_probe = _McuProbeShim()
        # Register under the name Creality's homing.py looks for. Safe only
        # because [prtouch_v3] is disabled; Klipper raises on duplicates.
        if self.printer.lookup_object("prtouch_v3", None) is None:
            self.printer.add_object("prtouch_v3", self)
            logging.info("carto_prtouch_shim: registered stand-in 'prtouch_v3'")
        else:
            logging.warning(
                "carto_prtouch_shim: real prtouch_v3 present - shim NOT registered"
            )


def load_config(config):
    return CartoPrtouchShim(config)
