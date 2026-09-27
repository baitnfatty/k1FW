#!/bin/sh
#
# Restart mcu shell.
#

PROG=/usr/apps/usr/bin/cmd_mcu
FIRMWARE=/lib/firmware/klipper_main_ipc.bin
LOGFILE=/usr/data/printer_data/logs/cmd_mcu.log
MAX_RETRIES=5

restart() {
    $PROG shutdown >> $LOGFILE 2>&1
    if [ $? -ne 0 ]; then
        return 1;
    fi
    $PROG write_firmware $FIRMWARE >> $LOGFILE 2>&1
    if [ $? -ne 0 ]; then
        return 1;
    fi
    $PROG bootup >> $LOGFILE 2>&1
    if [ $? -ne 0 ]; then
        return 1;
    fi
    return 0
}

restart_mcu() {
    count=0
    mkdir -p /usr/data/printer_data/logs
    echo "[`date "+%Y-%m-%d %H:%M:%S"`] start mcu upgrade..." > $LOGFILE
    while [ $count -lt $MAX_RETRIES ]; do
        echo "[`date "+%Y-%m-%d %H:%M:%S"`] try $count time..." >> $LOGFILE
        restart
        
        if [ $? -eq 0 ]; then
            exit 0
        else
            count=$((count+1))
            sleep 1
        fi
    done

    exit 1
}

restart_mcu