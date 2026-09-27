#! /bin/sh
source /etc/profile

part_userdata_name="userdata"
part_userdata_devblk="/dev/mmcblk0p10"
part_userdata_mount="/usr/data"

part_deplibs_name="deplibs"
part_deplibs_devblk="/dev/mmcblk0p7"
part_deplibs_mount="/usr/deplibs"

part_apps_name="apps"
part_apps_devblk="/dev/mmcblk0p8"
part_apps_mount="/usr/apps"

userdata_err_flag="false"
mount_do_userdata()
{
    retry_count=0
    max_retries=5
    while [ ! -b "${part_userdata_devblk}" ]; do
        if [ $retry_count -ge $max_retries ]; then
            echo "Blkdev ${part_userdata_devblk} inexistence !" > /dev/console
            return -1
        fi
        sleep 1
        retry_count=$((retry_count + 1))
    done

    mkdir -p ${part_userdata_mount}
    fsck -y -t ext4 "$part_userdata_devblk" > /dev/null
    if ! mount -t ext4 -o sync,data=ordered,barrier=1 ${part_userdata_devblk} ${part_userdata_mount} > /dev/null; then
        if ! mount -t ext4 -o sync ${part_userdata_devblk} ${part_userdata_mount} > /dev/null; then
            if ! mke2fs -F -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 ${part_userdata_devblk} > /dev/null; then
                echo "Blkdev ${part_userdata_devblk} mk2fs fail !" > /dev/console
                return -1
            fi

            echo "Blkdev ${part_userdata_devblk} mk2fs over !" > /dev/console
            if ! mount -t ext4 -o sync,data=ordered,barrier=1 ${part_userdata_devblk} ${part_userdata_mount} > /dev/null; then
                echo "Mount partition ${part_userdata_name} fail" > /dev/console
                return -1
            fi
        fi
    fi

    return 0
}


mount_do_deplibs()
{
    if [ "$(dd if=/dev/mmcblk0p1 bs=1 count=32 | grep ota:kernel2)" ]; then
        part_deplibs_devblk="/dev/mmcblk0p8"
    fi
    if ! mount -t squashfs "${part_deplibs_devblk}" "${part_deplibs_mount}"; then
        echo "Mount partition ${part_deplibs_name} fail" > /dev/console
        return 1
    fi
    return 0
}


mount_do_apps()
{
    if [ "${userdata_err_flag}" == "true" ]; then
        resize2fs ${part_apps_devblk} > /dev/null
        echo "Resize2fs ${part_apps_devblk} finish" > /dev/console
    fi

    if ! mount -t ext4 -o sync,data=ordered,barrier=1 "${part_apps_devblk}" "${part_apps_mount}"; then
        echo "Mount partition ${part_apps_name} fail" > /dev/console
        return 1
    fi

    return 0
}


clear_userdata()
{
    if [ -d "/usr/data/" ]; then
        dir=$(pwd)
        mv /usr/data/printer_data/gcodes /usr/data
        cd /usr/data
        rm -rf $(ls | grep -Ev "gcodes")
        mkdir -p /usr/data/printer_data
        mv /usr/data/gcodes /usr/data/printer_data
        cd ${dir}
    fi
}


resize_apps()
{
    blkname=${part_apps_devblk}
    resize2fs ${blkname} > /dev/null
    echo "Resize2fs ${blkname} finish" > /dev/console
}


modify_date()
{
    if [ "" != "`ps | grep ntpd | grep -v grep`" ]; then
        return 0
    fi

    strtime=$1
    tm="`echo ${strtime} | sed -E 's/(....)(..)(..)(..)(..)(..)/\1-\2-\3 \4:\5:\6/'`"
    if ! date -s "${tm}"; then
        echo "Set time [${tm}] fail" > /dev/console
        return 1
    fi

    return 0
}

init_sys_date()
{
    if [ "1970-01-01" \< "$(date +"%Y-%m-%d")" ]; then
        return 0
    fi

    local buildtime_file="/usr/apps/etc/buildtime"
    if [ ! -f "$buildtime_file" ]; then
        echo "Error: $buildtime_file not found."
        return 1
    fi

    target_time=$(cat "$buildtime_file")
    if ! date -s "${target_time}"; then
        echo "Set time [${target_time}] fail"> /dev/console
        return 1
    fi

    return 0
}

upgmode=""
upgfile=""
strdate=""
upgdir="${part_userdata_mount}/upgrade"
upg_check_flag()
{
    upgstate=${upgdir}/state

    if [ ! -d "${upgdir}" -o ! -f "${upgstate}" ]; then
        #echo "Not set upgrade flag" > /dev/console
        return 1;
    fi

    hasupg="false"
    while IFS= read -r line; do
        if echo "${line}" | grep -qE '^#'; then
            continue
        fi
        nline=${line// /}
        key=$(echo "$nline" | awk -F':' '{print $1}')
        val=$(echo "$nline" | awk -F':' '{print $2}')
        if [ "${key}" == "action" -a "${val}" == "upg" ]; then
            hasupg="true"
        elif [ "${key}" == "mode" -a "${val}" != "" ]; then
            upgmode=${val}
        elif [ "${key}" == "path" -a "${val}" != "" ]; then
            upgfile=${val}
        elif [ "${key}" == "date" -a "${val}" != "" ]; then
            strdate=${val}
        fi
    done < "${upgstate}"

    if [ "${hasupg}" != "true" -o "${upgfile}" == "" ]; then
        echo "Check ${upgstate} nopass !" > /dev/console
        return 1
    fi

    return 0
}


upg_wait_mobiledisk()
{
    now_wait_count=0
    max_wait_count=100
    while true; do
        if mount | grep "/dev/sd[a-z]"; then
            break
        fi
        let "now_wait_count++"
        if [ $now_wait_count -ge $max_wait_count ]; then
            echo "Not find mobile disk to mount !" > /dev/console
            break
        fi
        sleep 0.1
    done
}


disktype="0"
upg_check_disk()
{
    while IFS= read -r line; do
        tymmc="`echo` ${line} |grep `mmcblk0`"
        tynand="`echo` ${line} |grep `mtd`"
        if [ "${tymmc}" != "" ]; then
            #echo "Disk type mmc" > /dev/console
            disktype="0"
            return 0
        fi

        if [ "${tynand}" != "" ]; then
            #echo "Disk type nand" > /dev/console
            disktype="1"
            return 0
        fi

    done < "/proc/partitions"

    disktype="0"
    return 0
}


err_flag_path="${part_userdata_mount}/.errflag"
handle_err_flag()
{
    opt=$1
    if [ "$opt" == "set" ]; then
        touch -t `date +"%Y%m%d%H%M.%S"` ${err_flag_path}
        sync
        return 0

    elif [ "$opt" == "get" ]; then
        if [ -f "${err_flag_path}" ]; then
            return 0
        fi
        return 1

    elif [ "$opt" == "clean" ]; then
        if [ -f "${err_flag_path}" ]; then
            rm ${err_flag_path}
            sync
        fi
        return 0
    fi

    return 1
}

upgresult="${upgdir}/upgresult"
upg_do()
{
    if ! upg_check_flag; then
        return 1
    fi

    if [ "${upgmode}" == "external" ]; then
        echo "Wait mobile disk to mount !" > /dev/console
        upg_wait_mobiledisk
    fi

    if [ ! -f "${upgfile}" ]; then
        echo "Upgrade package ${upgfile} inexistence !" > /dev/console
        echo "upgresult: file_inexistence" > ${upgresult}
        return 1
    fi

    upg_check_disk
    modify_date "${strdate}"
    logfile="${upgdir}/`date +\"%Y%m%d%H%M%S\"`".log
    if ! touch "${logfile}"; then
        echo "Detection ${upgdir} file system happen error !" > /dev/console
        need_restore_flag="true"
        umount ${part_userdata_mount} && mount_do_userdata
    fi

    if ! handle_err_flag "get"; then
        handle_err_flag "set"
    else
        need_restore_flag="true"
        echo "Detection before happen breakoff error !" > /dev/console
    fi

    if [ "$(dd if=/dev/mmcblk0p1 bs=1 count=32 | grep ota:kernel2)" ]; then
        partlist="mmcblk0p3,mmcblk0p5,mmcblk0p7"
        newjump="ota:kernel"
    else
        partlist="mmcblk0p4,mmcblk0p6,mmcblk0p8"
        newjump="ota:kernel2"
	fi
    echo "Run upgrade ${upgfile} start" > /dev/console
    if ! upgbox -U -f "${upgfile}" -t "${disktype}" -p "${partlist}" -l "${logfile}" &> /dev/console; then
        echo "Upgrade run fail !" > /dev/console
        echo "upgresult: failed" > ${upgresult}
        echo "upgdate: `date +\"%Y%m%d%H%M%S\"`" >> ${upgresult}
        exit 1
    else
        echo "${newjump}" > /dev/mmcblk0p1
        if [ "$(echo "${upgfile}" | grep V9.9.9.99)" ]; then
            clear_userdata
        fi
    fi

    if [ "${upgmode}" == "interior" ]; then
        rm ${upgfile}
    fi

    rm ${upgdir}/state
    handle_err_flag "clean"
    echo "Run upgrade ${upgfile} finish" > /dev/console
    echo "upgresult: succeed" > ${upgresult}
    echo "upgdate: `date +\"%Y%m%d%H%M%S\"`" >> ${upgresult}

    sync && umount ${part_userdata_mount}
    resize_apps
    return 0
}


reset_clean_list_file="${part_userdata_mount}/clean_list"
do_reset_clean()
{
    if [ ! -f ${reset_clean_list_file} ]; then
        return 0
    fi

    echo "Run reset ..." > /dev/console

    while read cls mode
    do
        if [ -d ${cls} ]; then
            if [ "${mode}" == "-d" ]; then
                rm -rf ${cls}
            else
                rm -rf ${cls}/*
            fi

            continue
        fi

        if [ -f ${cls} ]; then
            rm -rf ${cls}
        fi
    done < "${reset_clean_list_file}"

    if [ -d ${upgdir} ]; then
        rm -rf ${upgdir}/*.log
    fi

    rm -rf ${reset_clean_list_file}
    need_restore_flag="true"
    umount ${part_userdata_mount} && mount_do_userdata
}


run_system_service()
{
    for i in /etc/appetc/init.d/S??*; do
        [ ! -f "$i" ] && continue

        case "$i" in
        *.sh)
            (
            trap - INT QUIT TSTP
            set start
            . $i
            )
            ;;
        *)
            $i start
            ;;
        esac
    done
}

run_creality_service()
{
    for i in /etc/appetc/init.d/CS??*; do
        [ ! -f "$i" ] && continue

        case "$i" in
        *.sh)
            (
            su -c "trap - INT QUIT TSTP" creality
            su -c "set start" creality
            su -c ". $i" creality
            )
            ;;
        *)
            su -c "$i start" creality
            ;;
        esac
    done
}


wait_system()
{
    now_wait_count=0
    max_wait_count=50
    while true; do
        if [ -e "/dev/mmcblk0" ]; then
            break
        fi
        let "now_wait_count++"
        if [ $now_wait_count -ge $max_wait_count ]; then
            echo "The partition table not found!" > /dev/console
            break
        fi
        sleep 0.1
    done
}

x2000e_version()
{
    model=$(/usr/apps/usr/bin/creality_sn read creality_model_str)
    model=${model#"CR-"}
    model=${model// /}
    model=$(echo "$model" | tr 'a-z' 'A-Z')
    version=$(cat /etc/version)
    version=${version#*_}
    echo "${model}_${version}" > /etc/version

    if [ ! -f /usr/data/cfs-c ]; then
        clear_userdata
        echo "${model}_${version}" > /usr/data/cfs-c
    fi
}

main()
{
    wait_system

    if mount_do_userdata; then
        if upg_do; then
            reboot && exit 0
        fi

        do_reset_clean
    fi

    ulimit -c unlimited
    mkdir -p /usr/data/core
    echo "|/bin/core_helper %e" > /proc/sys/kernel/core_pattern

    mount_do_deplibs
    #mount_do_apps
    x2000e_version
    init_sys_date
    run_system_service
    run_creality_service
    return 0
}

main
