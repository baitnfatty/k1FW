#! /bin/sh

upgfile=$1
upgpath="/usr/data/upgrade"
upgstate="${upgpath}/state"

if [ ! -f "${upgfile}" ]; then
    echo "${upgfile}: No such file or directory !!" > /dev/console
    exit 1
fi

if [ "`grep -c rootfs-app.*ext4$ ${upgfile}`" -gt "0" ]; then
    echo "${upgfile} check nopass !!" > /dev/console
    exit 1
fi

if ! upgbox -C -f "${upgfile}" -A &> /dev/null; then
    echo "${upgfile} check nopass !!" > /dev/console
    exit 1
fi

mkdir -p ${upgpath}
echo "action: upg" > ${upgstate}

if [ "" != "`df -T ${upgfile} | grep '/dev/sd[a-z]'`" ]; then
    echo "mode: external" >> ${upgstate}
else
    echo "mode: interior" >> ${upgstate}
fi

echo "path: `realpath ${upgfile}`" >> ${upgstate}
echo "date: `date '+%Y%m%d%H%M%S'`" >> ${upgstate}

echo "Upgrade file check pass, run reboot do upgrade !!!" > /dev/console
sync && sleep 1 && reboot