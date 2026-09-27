#!/bin/sh
# ==========================================================================
#  Moonraker-database maintenance for the 2025 K1C / K1 Max
#
#  WHY: Fluidd's System page has "Create Backup" and "Compact Database"
#  buttons, plus a namespace list. On this firmware ALL of them fail with
#  403 "Method unimplemented" — Creality's nexusp (a C reimplementation of
#  Moonraker) implements database get_item/post_item/delete_item but NOT
#  list, compact, backup or restore.
#
#  Those calls go over the WEBSOCKET, so they cannot be intercepted by the
#  nginx in front of Fluidd. This script does the real work instead.
#
#  The store is a genuine SQLite 3 database and sqlite3 is present on the
#  printer, so backup/compact/list are straightforward — and verified safe
#  to run while Klipper and nexusp are live (sqlite handles the locking).
#
#  Usage (as root on the printer):
#     sh db-tool.sh backup      # timestamped copy + integrity check
#     sh db-tool.sh compact     # VACUUM, reclaims free pages
#     sh db-tool.sh list        # namespaces + row counts (what 'list' would show)
#     sh db-tool.sh restore <file>
#     sh db-tool.sh prune [N]   # keep newest N backups (default 10)
# ==========================================================================
set -eu

DB=/usr/data/printer_data/database/nexusp-sql.db
BACKUP_DIR=/usr/data/db_backups

ok()   { echo "[+] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[-] $*" >&2; exit 1; }

[ -f "$DB" ] || die "database not found: $DB"
command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 not available"

cmd_backup() {
    mkdir -p "$BACKUP_DIR"
    out="$BACKUP_DIR/nexusp-sql.$(date +%Y%m%d_%H%M%S).db"
    # .backup is the online backup API - safe while nexusp holds the db open.
    sqlite3 "$DB" ".backup $out" || die "backup failed"
    res=$(sqlite3 "$out" "PRAGMA integrity_check;")
    [ "$res" = "ok" ] || die "backup wrote but integrity_check said: $res"
    chmod 644 "$out"
    ok "backup -> $out  ($(wc -c < "$out") bytes, integrity ok)"
}

cmd_compact() {
    before=$(wc -c < "$DB")
    sqlite3 "$DB" "VACUUM;" || die "vacuum failed (try again when idle)"
    res=$(sqlite3 "$DB" "PRAGMA integrity_check;")
    [ "$res" = "ok" ] || die "vacuum ran but integrity_check said: $res"
    after=$(wc -c < "$DB")
    ok "compact: ${before} -> ${after} bytes (reclaimed $((before - after)))"
}

cmd_list() {
    echo "namespaces:"
    sqlite3 "$DB" "select namespace, count(*) from namespace_store group by namespace;" \
        | sed 's/|/  /' | sed 's/^/  /'
    echo "tables:"
    sqlite3 "$DB" ".tables" | tr -s ' ' '\n' | sed '/^$/d;s/^/  /'
    echo "size: $(wc -c < "$DB") bytes"
}

cmd_restore() {
    src="${1:-}"
    [ -n "$src" ] || die "usage: $0 restore <backup-file>"
    [ -f "$src" ] || die "no such file: $src"
    [ "$(sqlite3 "$src" 'PRAGMA integrity_check;')" = "ok" ] || die "source db failed integrity check"
    warn "Stop Klipper first, or nexusp may overwrite this from memory:"
    warn "  /etc/appetc/init.d/CS55klipper_service stop"
    printf "Restore %s over %s ? [y/N] " "$src" "$DB"
    read -r a; [ "$a" = "y" ] || die "aborted"
    cp "$DB" "$DB.before-restore"
    cp "$src" "$DB"
    chown creality:creality "$DB"; chmod 644 "$DB"
    ok "restored. previous db kept at $DB.before-restore"
}

cmd_prune() {
    keep="${1:-10}"
    [ -d "$BACKUP_DIR" ] || { ok "no backups yet"; return 0; }
    n=$(ls -1 "$BACKUP_DIR"/nexusp-sql.*.db 2>/dev/null | wc -l)
    [ "$n" -le "$keep" ] && { ok "$n backups, keeping $keep - nothing to prune"; return 0; }
    ls -1t "$BACKUP_DIR"/nexusp-sql.*.db | tail -n +$((keep + 1)) | while read -r f; do
        rm -f "$f"; echo "    removed $(basename "$f")"
    done
    ok "pruned to newest $keep"
}

case "${1:-}" in
    backup)  cmd_backup ;;
    compact) cmd_compact ;;
    list)    cmd_list ;;
    restore) shift; cmd_restore "$@" ;;
    prune)   shift; cmd_prune "$@" ;;
    *) echo "usage: $0 {backup|compact|list|restore <file>|prune [N]}"; exit 1 ;;
esac
