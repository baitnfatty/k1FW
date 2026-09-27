#!/bin/sh
#
# Starts mcu and upgrade firmware.
#
DEVICES=""
UUID=0
PROG=/usr/apps/usr/bin/cmd_iap
IFACE=can0
MAX_RETRIES=5
FWUSBCAN=/usr/apps/lib/firmware/cfs_usb_can_app.bin
FWCUTTER=/usr/apps/lib/firmware/cfs_cutter_can_app.bin
FWBOX=/usr/apps/lib/firmware/cfs_box_can_app.bin
LOGFILE=/usr/data/printer_data/logs/cfs_iap_upgrade.log
KLIPPER=/usr/apps/etc/init.d/CS55klipper_service


while getopts "t:i:f:h" opt; do
    case $opt in
        t)
            DEVICE=$OPTARG
            if [ "${DEVICE:0:2}" != "0x" ]; then
                DEVICE="0x${DEVICE}"
            fi
            DEVICES="$DEVICES $DEVICE"
            ;;
        i)
            UUID=$OPTARG
            ;;
        f)
            FIRMWARE=$OPTARG
            ;;
        h)
            echo "Usage:  -t <device type> -i <uuid> -f <firmware>"
            echo "  if device type is 0 or not specified, all devices will be upgraded."
            echo "  if uuid is 0 or not specified, all devices of the same type will be upgraded."
            echo "  if firmware is not specified, the default firmware will be used."
            exit 0
            ;;
        *)
            exit 1
            ;;
    esac
done

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

cfs_upgrade_device() {
    local count=0
    local DEVICE_TYPE=$1
    local WAITTIME=$2

    if [[ "$DEVICE_TYPE" = "0xB0" || "$DEVICE_TYPE" = "0xb0" ]]; then 
        NODEID=0x58    #The real node id set by cmd_iap is ((0x58<<1)+0x100)=0x1B0, don't conflict with klipper.
        CMPMODE=1
        if [ -z "$FIRMWARE" ]; then
            FIRMWARE=$FWUSBCAN
        fi
    elif [[ "$DEVICE_TYPE" = "0xA4" || "$DEVICE_TYPE" = "0xa4" ]]; then
        NODEID=0x60    #The real node id set by cmd_iap is ((0x60<<1)+0x100)=0x1C0, don't conflict with klipper.
        CMPMODE=0
        if [ -z "$FIRMWARE" ]; then
            FIRMWARE=$FWCUTTER
        fi
    else
        NODEID=0x68    #The real node id set by cmd_iap is ((0x68<<1)+0x100)=0x1D0, don't conflict with klipper.
        CMPMODE=0
        if [ -z "$FIRMWARE" ]; then
            FIRMWARE=$FWBOX
        fi
    fi

    while [ $count -lt $MAX_RETRIES ]; do
        echo "...........try $((count+1)) time..........." >> $LOGFILE
        $PROG -n $IFACE -t $DEVICE_TYPE -i $UUID -a $NODEID -w $WAITTIME -u -c $CMPMODE -f $FIRMWARE >> $LOGFILE 2>&1
        if [ $? -eq 0 ]; then
            FIRMWARE=""
            return 0
        else
            count=$((count+1))
            sleep 1
        fi
    done

    return 1
}

cfs_upgrade() {
    local upgrade_result=0
    local upgrade_usbcan=0
    local upgrade_cutter=0
    local upgrade_box=0

    get_usb_can
    if [ $? -ne 0 ]; then
        echo "no usb can interface found." >> $LOGFILE
        return 1
    fi

    ip link set $IFACE up type can bitrate 1000000 > /dev/null 2>&1
    sleep 2

    echo -e "\n\n================================" >> $LOGFILE

    $KLIPPER mute > /dev/null 2>&1

    [ -z "$DEVICES" ] && DEVICES="0"

    for DEVICE in $DEVICES; do
        if [[ $DEVICE = "0" || $DEVICE = "0x0" ]]; then
            upgrade_usbcan=1
            upgrade_cutter=1
            upgrade_box=1
            break
        elif [[ $DEVICE = "0xb0" || $DEVICE = "0xB0" ]]; then
            upgrade_usbcan=1
        elif [[ $DEVICE = "0xa4" || $DEVICE = "0xA4" ]]; then
            upgrade_cutter=1
        elif [[ $DEVICE = "0xa2" || $DEVICE = "0xA2" ]]; then
            upgrade_box=1
        else
            echo "unknown device type: $DEVICE" >> $LOGFILE
        fi
    done

    if [ $upgrade_usbcan -eq 1 ]; then 
        echo -e "\n--------------------------------" >> $LOGFILE
        echo -e "["$(date "+%Y-%m-%d %H:%M:%S")"]"  >> $LOGFILE
        cansend $IFACE 0B0#F7FE04FF25A6E7
        sleep 2
        ip link set $IFACE up type can bitrate 1000000 > /dev/null 2>&1
        cfs_upgrade_device 0xB0 0
        if [ $? -ne 0 ]; then
            upgrade_result=1
        else
            sleep 2
            ip link set $IFACE up type can bitrate 1000000 > /dev/null 2>&1
        fi
    fi

    if [ $upgrade_cutter -eq 1 ] || [ $upgrade_box -eq 1 ]; then 
        if [ $upgrade_result -eq 0 ]; then
            echo -e "\n++++++++++++++++++++++++++++++++" >> $LOGFILE
            cansend $IFACE 0FE#F7FE04FF25A2FB
            cansend $IFACE 0FD#F7FD04FF25A4E9
            sleep 2
            $PROG -n $IFACE -t A2 -i $UUID -a 0x68 -w 300000 >> $LOGFILE 2>&1
            $PROG -n $IFACE -t A4 -i $UUID -a 0x60 -w 300000 >> $LOGFILE 2>&1

            if [ $upgrade_box -eq 1 ]; then
                echo -e "\n--------------------------------" >> $LOGFILE
                echo -e "["$(date "+%Y-%m-%d %H:%M:%S")"]"  >> $LOGFILE
                cfs_upgrade_device 0xA2 300000
                if [ $? -ne 0 ]; then
                    upgrade_result=1
                fi
            fi

            if [ $upgrade_cutter -eq 1 ]; then
                echo -e "\n--------------------------------" >> $LOGFILE
                echo -e "["$(date "+%Y-%m-%d %H:%M:%S")"]"  >> $LOGFILE
                cfs_upgrade_device 0xA4 300000
                if [ $? -ne 0 ]; then
                    upgrade_result=1
                fi
            fi

            echo -e "\n--------------------------------" >> $LOGFILE
            $PROG -n $IFACE -t A2 -i $UUID -a 0x68 -j >> $LOGFILE 2>&1
            $PROG -n $IFACE -t A4 -i $UUID -a 0x60 -j >> $LOGFILE 2>&1
            echo -e "\n++++++++++++++++++++++++++++++++" >> $LOGFILE
        fi
    fi

    $KLIPPER unmute > /dev/null 2>&1

    if [ "$LOGFILE" != "/dev/stdout" ]; then
        sed -i '/progress/d' $LOGFILE
    fi

    exit $upgrade_result
}

cfs_upgrade
