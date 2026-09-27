#!/bin/sh
#
# Starts mcu and upgrade firmware.
#
DEVICE=0
UUID=0
PROG=/usr/apps/usr/bin/cmd_iap
IFACE=can0
MAX_RETRIES=5
FWUSBCAN=/usr/apps/lib/firmware/cfs_usb_can_app.bin
FWCUTTER=/usr/apps/lib/firmware/cfs_cutter_can_app.bin
FWBOX=/usr/apps/lib/firmware/cfs_box_can_app.bin


get_usb_can() {
    for iface_dir in /sys/class/net/can*; do
        iface=$(basename "$iface_dir")
        if [ "$(cat "/sys/class/net/$iface/type")" = "280" ]; then
            if grep -q "usb" /sys/class/net/$iface/device/uevent; then
                IFACE=$iface
                return 0
            fi
            if readlink /sys/class/net/$iface | grep -q '/usb[0-9]/'; then
                IFACE=$iface
                return 0
            fi
        fi
    done
    return 1
}

cfs_upgrade_check() {
    get_usb_can
    if [ $? -ne 0 ]; then
        exit 1
    fi

    ip link set $IFACE up type can bitrate 1000000 > /dev/null 2>&1

    cansend $IFACE 0FD#F7FD04FF25A4E9
    cansend $IFACE 0FE#F7FE04FF25A2FB
    sleep 2
    $PROG --net $IFACE --dtype 0xA4 --compare 0 --firmware $FWCUTTER
    $PROG --net $IFACE --dtype 0xA2 --compare 0 --firmware $FWBOX
    $PROG --net $IFACE --dtype 0xB0 --uuid 1 --nodeid 0xB0 --compare 1 --firmware $FWUSBCAN

    exit 0
}

cfs_upgrade_check
