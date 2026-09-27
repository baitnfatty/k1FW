#!/bin/sh
#
# Starts mcu and upgrade firmware.
#

INTERFACE=$1
DEVICE_TYPE=$2
DEVICE=$3
BAUDRATE=$4
FIRMWARE=$5

PROG=/usr/apps/usr/bin/cmd_iap
MAX_RETRIES=5

start_can() {
    $PROG --net $DEVICE --dtype $DEVICE_TYPE --upgrade --firmware $FIRMWARE
}

start_uart() {
    $PROG --device $DEVICE --baudrate $BAUDRATE --dtype $DEVICE_TYPE --upgrade --firmware $FIRMWARE
}

start_mcu() {
    count=0
    while [ $count -lt $MAX_RETRIES ]; do
        echo "[`date "+%Y-%m-%d %H:%M:%S"`] try $count time..."
        if [ "$INTERFACE" = "CAN" ]; then
            start_can
        else
            start_uart
        fi
        
        if [ $? -eq 0 ]; then
            exit 0
        else
            count=$((count+1))
            sleep 1
        fi
    done

    exit 1
}

start_mcu