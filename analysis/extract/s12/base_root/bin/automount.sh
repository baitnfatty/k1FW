#! /bin/sh
# sd([a-z]+)([0-9]+)      0:0 660 */bin/automount.sh
# sd([a-z]+)              0:0 660 */bin/automount.sh

username="creality"
if id ${username}; then
    mountpath="/media/${username}/${MDEV}"
    usermask="uid=`id -u ${username}`,gid=`id -g ${username}`"
else
    mountpath="/media/root/${MDEV}"
    usermask="uid=`id -u`,gid=`id -g`"
fi

do_mount()
{
    mkdir -p "${mountpath}"
    
    fs_type=$(blkid /dev/sda2 | grep -o 'TYPE="[^"]*"' | sed 's/TYPE="//;s/"//')
    
    if [ "${fs_type}" == "ntfs" ]; then
	ntfs-3g -o "${usermask}" /dev/"${MDEV}" "${mountpath}" > /dev/console
        if [ $? -ne 0 ]; then
            echo "Failed to mount NTFS drive /dev/${MDEV}" > /dev/console
        fi
    elif [ "${fs_type}" == "vfat" ]; then
        mount -t vfat -o "${usermask}",noatime,shortname=mixed,utf8 /dev/"${MDEV}" "${mountpath}" > /dev/console
        if [ $? -ne 0 ]; then
            mount -o "${usermask}" /dev/"${MDEV}" "${mountpath}" > /dev/console
        fi
    elif [ "${fs_type}" == "exfat" ]; then
	 mount.exfat-fuse -o "${usermask}" /dev/"${MDEV}" "${mountpath}" > /dev/console
    else
        mount -o "${usermask}" /dev/"${MDEV}" "${mountpath}" > /dev/console
    fi

    echo "Mount ${MDEV} to ${mountpath} !" > /dev/console
}

if [ "${ACTION}" == "add" ]; then
    if mount | grep "${MDEV}" | grep "${mountpath}"; then
        exit 0
    fi

    if [ "${DEVTYPE}" == "partition" ]; then
        do_mount
    elif [ "${DEVTYPE}" == "disk" ]; then
        if /bin/busybox blkid &> /dev/null; then
            if [ "`busybox blkid /dev/${MDEV}`" ]; then
                do_mount
            fi
        fi
    else
        echo "UNKNOWN ${MDEV} type ${DEVTYPE}" > /dev/console
        exit 1
    fi

elif [ "${ACTION}" == "remove" ]; then
    if mount | grep "${MDEV}" | grep "${mountpath}"; then
        umount -l "${mountpath}" && rmdir "${mountpath}"
        echo "Umount ${MDEV} from ${mountpath} !" > /dev/console
    fi
fi
