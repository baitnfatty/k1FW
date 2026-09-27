#!/bin/sh
# ==========================================================================
#  Firmware / system backup for the 2025 K1C / K1 Max  (CR4SU200382C13)
#
#  Fluidd's "Create Backup" button only ever backed up Moonraker's 143 KB
#  SQLite database - and on this firmware it does not work at all
#  (403 "Method unimplemented" from Creality's nexusp). This backs up what
#  actually matters.
#
#  THERE IS NO VENDOR RECOVERY FOR THIS BOARD. Keep a copy OFF the printer.
#
#  Tiers:
#    config   seconds,  ~1 MB    printer.cfg + configs + moonraker db + our mods
#    apps     ~1 min,   ~65 MB   mmcblk0p8 - Klipper, plugin scaffold, shim
#    full     ~5-10 min,~175 MB  p1..p9: ota flag, sn_mac, rtos, kernels, rootfs
#
#  p10 (userdata, 6.7 GB) is deliberately skipped - it is gcodes/logs and is
#  covered by the 'config' tier for the parts worth keeping.
#
#  sn_mac (p2) holds this unit's UNIQUE serial/MAC. It is irreplaceable.
#  It is included in 'full', which is the main reason to run 'full' once.
#
#  Usage (root, on the printer):
#     sh firmware-backup.sh config
#     sh firmware-backup.sh apps
#     sh firmware-backup.sh full
#     sh firmware-backup.sh list
#  Add DEST=/mnt/udisk (or any path) to write to a USB stick instead.
# ==========================================================================
set -eu

DEST="${DEST:-/usr/data/fw_backups}"
STAMP="$(date +%Y%m%d_%H%M%S)"
CFG=/usr/data/printer_data

ok()   { echo "[+] $*"; }
info() { echo "[*] $*"; }
die()  { echo "[-] $*" >&2; exit 1; }

need_space() {
    need_mb="$1"
    avail=$(df -m "$DEST" 2>/dev/null | awk 'NR==2{print $4}')
    [ -z "$avail" ] && return 0
    [ "$avail" -lt "$need_mb" ] && die "need ~${need_mb}MB, only ${avail}MB free at $DEST"
    return 0
}

dump_part() {
    part="$1"; label="$2"; out="$3"
    [ -b "/dev/$part" ] || { info "skip $part (absent)"; return 0; }
    info "dumping $part ($label)"
    dd if="/dev/$part" bs=1M 2>/dev/null | gzip -1 > "$out.gz"
    sz=$(wc -c < "$out.gz")
    echo "$part  $label  $(basename "$out").gz  $sz" >> "$MANIFEST"
    ok "$part -> $(basename "$out").gz ($sz bytes)"
}

cmd_config() {
    d="$DEST/config_$STAMP"; mkdir -p "$d"; MANIFEST="$d/MANIFEST.txt"
    need_space 20
    : > "$MANIFEST"
    echo "# config backup $STAMP" >> "$MANIFEST"
    # busybox tar has no -z; pipe through gzip
    tar cf - -C "$CFG" config 2>/dev/null | gzip -1 > "$d/printer_config.tar.gz" \
        && ok "configs ($(wc -c < "$d/printer_config.tar.gz") bytes)"
    if [ -f "$CFG/database/nexusp-sql.db" ]; then
        sqlite3 "$CFG/database/nexusp-sql.db" ".backup $d/nexusp-sql.db" 2>/dev/null \
            && ok "moonraker database" || info "db backup skipped"
    fi
    # our own additions, which a firmware update will wipe
    mods=""
    for m in /usr/data/cartographer /usr/data/tools /usr/data/fluidd/nginx.conf \
             /usr/apps/usr/share/klipper/klippy/extras/cartographer.py \
             /usr/apps/usr/share/klipper/klippy/extras/carto_prtouch_shim.py \
             /usr/apps/usr/share/klipper/klippy/extras/carto_shell_command.py \
             /usr/apps/etc/init.d/S98fluidd; do
        [ -e "$m" ] && mods="$mods $m"
    done
    if [ -n "$mods" ]; then
        tar cf - $mods 2>/dev/null | gzip -1 > "$d/mods.tar.gz" \
            && ok "mods ($(wc -c < "$d/mods.tar.gz") bytes)"
    fi
    cat /etc/version > "$d/firmware_version.txt" 2>/dev/null || true
    cat /etc/hardware >> "$d/firmware_version.txt" 2>/dev/null || true
    chmod -R a+rX "$d"
    ok "config backup -> $d  ($(du -sh "$d" | cut -f1))"
}

cmd_apps() {
    d="$DEST/apps_$STAMP"; mkdir -p "$d"; MANIFEST="$d/MANIFEST.txt"
    need_space 150
    : > "$MANIFEST"; echo "# apps backup $STAMP" >> "$MANIFEST"
    dump_part mmcblk0p8 "rootfs2 / usr-apps" "$d/mmcblk0p8.img"
    ok "apps backup -> $d"
}

cmd_full() {
    d="$DEST/full_$STAMP"; mkdir -p "$d"; MANIFEST="$d/MANIFEST.txt"
    need_space 400
    : > "$MANIFEST"; echo "# full backup $STAMP" >> "$MANIFEST"
    cat /etc/version >> "$MANIFEST" 2>/dev/null || true
    info "this takes several minutes - gzip on a 2-core MIPS is slow"
    dd if=/dev/mmcblk0 bs=1M count=1 2>/dev/null | gzip -1 > "$d/boot_first1M.img.gz"
    ok "first 1MB (GPT + u-boot SPL + u-boot, SCBT-encrypted)"
    dump_part mmcblk0p1 "ota flag"            "$d/mmcblk0p1.img"
    dump_part mmcblk0p2 "sn_mac (UNIQUE!)"    "$d/mmcblk0p2.img"
    dump_part mmcblk0p3 "rtos"                "$d/mmcblk0p3.img"
    dump_part mmcblk0p4 "rtos2"               "$d/mmcblk0p4.img"
    dump_part mmcblk0p5 "kernel"              "$d/mmcblk0p5.img"
    dump_part mmcblk0p6 "kernel2"             "$d/mmcblk0p6.img"
    dump_part mmcblk0p7 "rootfs (squashfs)"   "$d/mmcblk0p7.img"
    dump_part mmcblk0p8 "rootfs2 / usr-apps"  "$d/mmcblk0p8.img"
    dump_part mmcblk0p9 "rootfs_data"         "$d/mmcblk0p9.img"
    ok "full backup -> $d  ($(du -sh "$d" | cut -f1))"
    echo
    echo "  !! COPY THIS OFF THE PRINTER. There is no vendor recovery. !!"
    echo "     scp -r root@<ip>:$d ."
}

cmd_list() {
    [ -d "$DEST" ] || { info "no backups at $DEST"; return 0; }
    du -sh "$DEST"/* 2>/dev/null | sed 's/^/  /' || info "none yet"
    echo "  free: $(df -h "$DEST" | awk 'NR==2{print $4}')"
}

case "${1:-}" in
    config) cmd_config ;;
    apps)   cmd_apps ;;
    full)   cmd_full ;;
    list)   cmd_list ;;
    *) echo "usage: $0 {config|apps|full|list}   [DEST=/path]"; exit 1 ;;
esac
