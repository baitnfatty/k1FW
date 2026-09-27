#!/bin/sh

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <parameter>" >&2
    exit 1
fi

PARAM=$(echo "$1" | tr 'A-Z' 'a-z')

SN_FILE="creality_sn"
MAC_FILE="creality_mac"
MODEL_FILE="creality_model"
MODEL_STR_FILE="creality_model_str"
BOARD_FILE="creality_board"
PCBA_TEST_FILE="creality_pcba_test"
MACHINE_SN_FILE="creality_machine_sn"
SYS_VER_FILE="/etc/version"
HW_VER_FILE="/etc/hardware"
CFS_USBCAN_FILE="/usr/apps/lib/firmware/cfs_usb_can_app.bin"
CFS_CUTTER_FILE="/usr/apps/lib/firmware/cfs_cutter_can_app.bin"
CFS_BOX_FILE="/usr/apps/lib/firmware/cfs_box_can_app.bin"



check_sn() {
    local input="$1"
    local sn
    if echo "$input" | grep -q '^SN:'; then
        # 去除 "SN:" 前缀
        sn=$(echo "$input" | sed 's/^SN://')
    else
        sn="$input"
    fi
    if echo "$sn" | grep -Eq '^[0-9A-Fa-f]{14}$'; then
        return 0
    else
        return 1
    fi
}

check_mac() {
    local input="$1"
    if echo "$input" | grep -Eq '^[0-9A-Fa-f]{12}$'; then
        return 0
    else
        return 1
    fi
}

get_sn() {
    local sn
    sn=$(creality_sn read "$1")
    if ! check_sn "$sn"; then
        echo "0000"
        exit 1
    fi
    echo "$sn"
}

get_mac() {
    local ret=1 MAC
    MAC=$(creality_sn read "$1")
    if check_mac "$MAC"; then
        ret=0
    fi
    if [ "$ret" -ne 0 ]; then
        # 从 /usr/data/macaddr.txt 中获取
        if [ -f /usr/data/macaddr.txt ]; then
            MAC=$(sed 's/[^0-9a-fA-F]//g' /usr/data/macaddr.txt)
            if [ "${#MAC}" -eq 12 ]; then
                echo "$MAC"
                exit 0
            fi
        fi
        # 从随机数中获取
        if [ -f /proc/sys/kernel/random/uuid ]; then
            MAC=$(sed 's/[^0-9a-fA-F]//g' /proc/sys/kernel/random/uuid)
            MAC="d03110${MAC:0:6}"
            echo "$MAC"
            exit 0
        fi
    fi
    echo "$MAC"
}

get_model_str() {
    local value
    value=$(creality_sn read "$1")
    value=${value#"CR-"}
    value=${value// /}
    echo "$value"
}

get_hostname() {
    local model=$(get_model_str "$MODEL_STR_FILE")
    local mac=$(creality_sn read $MAC_FILE)
    local last4MAC=${mac: -4}
    local result="${model}-${last4MAC}"
    echo "$result"
}

get_parm() {
    if [ ! -f "$1" ]; then
        echo "0000"
        exit 1
    fi
    cat "$1"
}

get_creality_sn_sh() {
    local value
    value=$(creality_sn read "$1")
    echo "$value"
}

get_bedsize() {
    local bedsizes="K1C:220,220,250 K1Max:300,300,300 K1:220,220,250 K1SE:220,220,250 ENDER3V3Plus:300,300,300 other:100,100,100"
    local model_str
    model_str=$(get_model_str "$MODEL_STR_FILE")
    for bedsize in $bedsizes; do
        local key value
        key=$(echo "$bedsize" | cut -d':' -f1)
        value=$(echo "$bedsize" | cut -d':' -f2)
        if [[ "$key" == "$model_str" || "CR-$key" == "$model_str" ]]; then
            echo "$value"
            exit 0
        fi
    done
}

get_cfs_fw_version() {
    value=$(dd if="$1" bs=1 skip=$((0x224)) 2>/dev/null | {
        while read -r -n1 c; do
            [ -z "$c" ] && break
            printf "%c" "$c"
        done
    })
    echo "$value"
}

case "$PARAM" in
    sn)
        get_sn "$SN_FILE"
        ;;
    mac)
        get_mac "$MAC_FILE"
        ;;
    model_str)
        get_model_str "$MODEL_STR_FILE"
        ;;
    board)
        get_creality_sn_sh "$BOARD_FILE"
        ;;
    pcba_test)
        get_creality_sn_sh "$PCBA_TEST_FILE"
        ;;
    machine_sn)
        get_creality_sn_sh "$MACHINE_SN_FILE"
        ;;
    sys_version)
        get_parm "$SYS_VER_FILE" | sed 's/^.*V/V/'
        ;;
    hw_version)
        get_parm "$HW_VER_FILE"
        ;;
    bedsize)
        get_bedsize
        ;;
    hostname)
        get_hostname
        ;;
    cfs_box_version)
        get_cfs_fw_version "$CFS_BOX_FILE"
        ;;
    cfs_cutter_version)
        get_cfs_fw_version "$CFS_CUTTER_FILE"
        ;;
    cfs_usbcan_version)
        get_cfs_fw_version "$CFS_USBCAN_FILE"
        ;;
    *)
        exit 1
        ;;
esac

exit 0
