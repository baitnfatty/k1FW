#
# don't use adb* matching, Prevent accidental deletion of other files
#
for f in `ls /usr/deplibs/share/adbd/bin/`; do
    rm -rf /usr/apps/usr/bin/$f
done

rm -rf /usr/apps/etc/adb_profile
rm -rf /usr/apps/etc/init.d/S90adb
rm -rf /usr/apps/etc/init.d/adb