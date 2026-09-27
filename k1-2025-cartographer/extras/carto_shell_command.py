# ==========================================================================
#  carto_shell_command  —  run pre-declared shell commands from G-code
#
#  WHY: Fluidd's "Create Backup" / "Compact Database" buttons call Moonraker
#  API methods that Creality's nexusp never implemented (403 "Method
#  unimplemented"). Those calls go over the websocket and cannot be
#  intercepted. This extra lets us expose WORKING equivalents as Klipper
#  macros, which Fluidd renders as buttons.
#
#  SAFETY: unlike the usual community gcode_shell_command, this does NOT
#  accept a command string from G-code. Every command must be declared in
#  printer.cfg first; G-code may only invoke one by name. So a rogue macro
#  or a malicious .gcode file cannot run arbitrary shell.
#
#  Config:
#      [carto_shell_command backup_db]
#      command: sh /usr/data/tools/db-tool.sh backup
#      timeout: 120          # seconds, default 60
#      verbose: True         # echo output to the console, default True
#
#  Use:
#      RUN_SHELL_COMMAND CMD=backup_db
#
#  Long jobs should background themselves in the declared command (e.g.
#  `nohup ... &`) so Klipper is not held up.
# ==========================================================================

import shlex
import subprocess
import logging


class CartoShellCommand:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object("gcode")

        # section name: "carto_shell_command <name>"
        self.name = config.get_name().split(None, 1)[-1]
        self.command = config.get("command")
        self.timeout = config.getfloat("timeout", 60.0, above=0.0)
        self.verbose = config.getboolean("verbose", True)

        self.proc = None
        self.partial = ""

        # Register the dispatcher once, on whichever instance loads first.
        if not hasattr(self.printer, "_carto_shell_registered"):
            self.gcode.register_command(
                "RUN_SHELL_COMMAND",
                self.cmd_RUN_SHELL_COMMAND,
                desc="Run a shell command declared in printer.cfg: CMD=<name>",
            )
            self.printer._carto_shell_registered = True

    # ---------------------------------------------------------------- run --
    def _respond(self, msg):
        for line in str(msg).rstrip().split("\n"):
            if line.strip():
                self.gcode.respond_info(line.rstrip())

    def run(self, gcmd):
        if self.proc is not None and self.proc.poll() is None:
            raise gcmd.error("shell command '%s' is already running" % self.name)

        argv = shlex.split(self.command)
        self._respond("running: %s" % self.command)
        logging.info("carto_shell_command[%s]: %s", self.name, self.command)

        try:
            self.proc = subprocess.Popen(
                argv,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                # NOT expanduser("~"): klippy runs as 'creality' and HOME may
                # resolve to /root (mode 700) -> Permission denied on spawn.
                cwd="/usr/data",
            )
        except Exception as e:
            raise gcmd.error("failed to start '%s': %s" % (self.name, e))

        # Poll without blocking klipper's reactor for the whole duration.
        eventtime = self.reactor.monotonic()
        deadline = eventtime + self.timeout
        while True:
            if self.proc.poll() is not None:
                break
            if self.reactor.monotonic() > deadline:
                self.proc.terminate()
                self._respond("TIMEOUT after %.0fs - terminated" % self.timeout)
                self.proc = None
                raise gcmd.error("shell command '%s' timed out" % self.name)
            eventtime = self.reactor.pause(self.reactor.monotonic() + 0.15)

        out = b""
        try:
            out = self.proc.stdout.read() or b""
            self.proc.stdout.close()
        except Exception:
            pass
        rc = self.proc.returncode
        self.proc = None

        if self.verbose and out:
            self._respond(out.decode("utf-8", "replace"))
        if rc != 0:
            raise gcmd.error("'%s' exited %d" % (self.name, rc))
        self._respond("done: %s" % self.name)

    # --------------------------------------------------------- dispatcher --
    def cmd_RUN_SHELL_COMMAND(self, gcmd):
        name = gcmd.get("CMD", None)
        if not name:
            raise gcmd.error("usage: RUN_SHELL_COMMAND CMD=<name>")
        obj = self.printer.lookup_object("carto_shell_command %s" % name, None)
        if obj is None:
            raise gcmd.error(
                "no [carto_shell_command %s] declared in printer.cfg" % name
            )
        obj.run(gcmd)


def load_config_prefix(config):
    return CartoShellCommand(config)
