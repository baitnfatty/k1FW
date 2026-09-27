#!/bin/sh
# Install moonraker-db-shim: implements the 5 database JSON-RPC methods
# Creality's nexusp returns 403 "Method unimplemented" for.
# Run as root ON the printer, from this directory. Needs internet for pip.
set -eu
D=/usr/data/wsshim
mkdir -p "$D/lib" /usr/data/db_backups
/usr/share/klippy-env/bin/python3 -m pip install --quiet --no-cache-dir \
    --target "$D/lib" "websockets<11" || { echo "pip failed (no internet?)"; exit 1; }
cp moonraker-db-shim.py "$D/moonraker-db-shim.py"; chmod 755 "$D/moonraker-db-shim.py"
cp S97dbshim /usr/apps/etc/init.d/S97dbshim;      chmod 755 /usr/apps/etc/init.d/S97dbshim
chmod -R a+rX "$D"; chown -R creality:creality /usr/data/db_backups 2>/dev/null || true
/usr/apps/etc/init.d/S97dbshim restart
echo
echo "Now point nginx's /websocket at the shim (see fluidd/nginx.conf):"
echo "  upstream db_shim { server 127.0.0.1:4409 max_fails=2 fail_timeout=10s;"
echo "                     server 127.0.0.1:7125 backup; }"
echo "  location /websocket { proxy_pass http://db_shim/websocket; ... }"
echo "Then: /usr/apps/etc/init.d/S98fluidd restart"
