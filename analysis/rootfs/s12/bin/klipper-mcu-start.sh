#!/bin/sh
# System startup script to start the MCU Linux firmware

### BEGIN INIT INFO
# Provides:          klipper_mcu
# Required-Start:    $local_fs
# Required-Stop:
# Default-Start:     3 4 5
# Default-Stop:      0 1 2 6
# Short-Description: Klipper_MCU daemon
# Description:       Starts the MCU for Klipper.
### END INIT INFO

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DESC="klipper_mcu startup"
NAME="klipper_mcu"
KLIPPER_HOST_MCU=/usr/bin/klipper_mcu
KLIPPER_HOST_ARGS="-r"
PIDFILE=/var/run/klipper_mcu.pid

#. /lib/lsb/init-functions

mcu_host_stop()
{
    # Shutdown existing Klipper instance (if applicable). The goal is to
    # put the GPIO pins in a safe state.
    if [ -c /tmp/klipper_host_mcu ]; then
        set -e
        ( echo "FORCE_SHUTDOWN" > /tmp/klipper_host_mcu ) 2> /dev/null || ( log_action_msg "Firmware busy! Please shutdown Klipper and then retry." && exit 1 )
        sleep 1
        ( echo "FORCE_SHUTDOWN" > /tmp/klipper_host_mcu ) 2> /dev/null || ( log_action_msg "Firmware busy! Please shutdown Klipper and then retry." && exit 1 )
        sleep 1
        set +e
    fi

    killall klipper_mcu
}

mcu_host_start()
{
    [ -x $KLIPPER_HOST_MCU ] || return

    if [ -c /tmp/klipper_host_mcu ]; then
        mcu_host_stop
    fi

    start-stop-daemon --start --quiet --exec $KLIPPER_HOST_MCU \
                      --background --pidfile $PIDFILE --make-pidfile \
                      -- $KLIPPER_HOST_ARGS
    chmod 666 /tmp/klipper_host_mcu
}

case "$1" in
start)
    mcu_host_start
    ;;
stop)
    mcu_host_stop
    ;;
restart)
    $0 stop
    $0 start
    ;;
esac
exit 0
