#!/bin/sh
# Fluidd on :4408 for the 2025 K1C/K1Max. Creality ships a dangling fluidd
# symlink and an empty init dir - the app itself is absent. nginx IS present.
#
#   /usr/data/fluidd/www   static files      (persistent)
#   /usr/data/fluidd       nginx.conf, tmp, logs
#   /usr/apps/etc/init.d/S98fluidd           boot hook (persistent)
#
# /etc and /var are the RAM initramfs - nothing may live there.
# Run as root ON the printer. Needs fluidd.zip alongside this script
# (the printer's busybox wget cannot do GitHub TLS - download on a PC).
set -eu
D=/usr/data/fluidd
[ -f fluidd.zip ] || { echo "fluidd.zip not found next to this script"; exit 1; }
mkdir -p "$D/www" "$D/tmp" "$D/logs"
cd "$D/www" && unzip -oq "$OLDPWD/fluidd.zip"
cp "$OLDPWD/nginx.conf" "$D/nginx.conf"
cp "$OLDPWD/S98fluidd" /usr/apps/etc/init.d/S98fluidd
chmod 755 /usr/apps/etc/init.d/S98fluidd
chmod -R a+rX "$D"
/usr/sbin/nginx -t -c "$D/nginx.conf"
/usr/apps/etc/init.d/S98fluidd restart
echo "Fluidd on http://<printer-ip>:4408"
