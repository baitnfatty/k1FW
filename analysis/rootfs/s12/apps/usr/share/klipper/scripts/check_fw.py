import os
import subprocess
import json
import re
import time
import logging

# 定义常量
PWR_PIN = "PB28"
RESET_PIN = "PA07"

# 定义 MCU 配置字典
MCU_CONFIG = {
    "mcu0": {
        "fw_path": "/lib/firmware/mcu0_120_G32.bin",
        "tty": "/dev/ttyS7"
    },
    "noz0": {
        "fw_path": "/lib/firmware/noz0_120_G30.bin",
        "tty": "/dev/ttyS1"
    },
    "bed0": {
        "fw_path": "/lib/firmware/bed0_110_G21.bin",
        "tty": "/dev/ttyS9"
    }
}

MCU_UTIL = "/usr/share/klipper/scripts/mcu_util.py"
MCU0_FW = MCU_CONFIG["mcu0"]["fw_path"]
MCU0_TTY = MCU_CONFIG["mcu0"]["tty"]
NOZ0_FW = MCU_CONFIG["noz0"]["fw_path"]
BED0_FW = MCU_CONFIG["bed0"]["fw_path"]
NOZ0_TTY = MCU_CONFIG["noz0"]["tty"]
BED0_TTY = MCU_CONFIG["bed0"]["tty"]

# 重置 MCU 的函数
def reset_mcu():
    logging.info("Resetting MCU...")
    os.environ["LD_LIBRARY_PATH"] = "/usr/apps/usr/lib"
    subprocess.run(["cmd_gpio", "set_func", PWR_PIN, "output0"])
    subprocess.run(["cmd_gpio", "set_func", RESET_PIN, "output0"])
    time.sleep(1)
    subprocess.run(["cmd_gpio", "set_func", PWR_PIN, "output1"])
    subprocess.run(["cmd_gpio", "set_func", RESET_PIN, "output1"])

# 烧写mcu固件
def flash_mcu(mcu_name):
    mcu_config = MCU_CONFIG.get(mcu_name)
    reset_mcu()
    if mcu_config: 
        fw_path = mcu_config["fw_path"]
        tty = mcu_config["tty"]
        logging.info("Flashing %s with firmware from %s...", mcu_name, fw_path)
        subprocess.run([
            "python3", 
            MCU_UTIL, 
            "-c",
            "-i", 
            tty,
            "-u",
            "-f", 
            fw_path
        ])
    else:
        logging.info("MCU %s not found in configuration.", mcu_name)

# 获取硬件固件信息
def get_hw_fw_info():
    reset_mcu()
    result = []
    tty_to_mcu = {config["tty"]: mcu_name for mcu_name, config in MCU_CONFIG.items()}
    
    for tty in [MCU0_TTY, NOZ0_TTY, BED0_TTY]:
        # 使用与您提供的命令相同的参数格式
        process = subprocess.run(
            ["python3", MCU_UTIL, "-c", "-i", tty, "-g"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10
        )

        output = process.stdout
        if "FW Version:" not in output:
            logging.info("Error reading %s: %s", tty, process.stderr.strip() or output.strip())
            continue

        # 提取固件信息行
        fw_lines = [line for line in output.splitlines() if "FW Version:" in line]
        if not fw_lines:
            logging.info("No FW Version found in output for %s", tty)
            continue
            
        fw_line = fw_lines[0]
        fw_info = fw_line.split(":", 1)[1].strip()
        
        # 增强解析逻辑 - 使用正则表达式提取版本信息
        # 处理格式如: "noz0_006_000" 或 "bed0_006_000"
        match = re.search(r'(\w+)_(\d+)_(\d+)$', fw_info)
        if not match:
            # 尝试其他可能的格式
            match = re.search(r'(\w+)[_-](\d+)[_-](\d+)$', fw_info)
        
        if match:
            # 成功匹配版本号部分
            mcu_part = match.group(1)
            fw_version = match.group(2)
            revision = match.group(3)
            
            # 从配置中获取正确的MCU名称
            mcu_name = tty_to_mcu.get(tty, "unknown")
            
            result.append({
                "mcu": mcu_name,
                "fw_version": fw_version,
                "revision": revision
            })
        else:
            logging.info("Could not parse version info: %s", fw_info)
            
    return result

# 提取固件文件信息
def get_update_fw_info(firmware_path):
    try:
        with open(firmware_path, "rb") as f:
            f.seek(512)  # 0x200
            data = f.read(12)
            return data.decode("ascii", errors="ignore").strip('\x00')
    except Exception as e:
        logging.info("Error reading firmware: %s", e)
        return None

def collect_update_fw_info():
    update_fw_info = []
    firmware_files = [
        {"mcu": "mcu0", "path": MCU0_FW},
        {"mcu": "noz0", "path": NOZ0_FW},
        {"mcu": "bed0", "path": BED0_FW},
    ]

    for firmware in firmware_files:
        fw_info = get_update_fw_info(firmware["path"])
        if fw_info:
            # 解析格式: "noz0_006_000"
            match = re.match(r'(\w+)_(\d+)_(\d+)$', fw_info)
            if match:
                update_fw_info.append({
                    "mcu": firmware["mcu"],
                    "fw_version": match.group(2),
                    "revision": match.group(3)
                })
            else:
                logging.info("Could not parse firmware info: %s", fw_info)
    return update_fw_info

def start_mcu(mcu_name):
    mcu_config = MCU_CONFIG.get(mcu_name)
    if mcu_config: 
        tty = mcu_config["tty"]
        logging.info("Starting MCU %s on %s...", mcu_name, tty)
        subprocess.run([
            "python3", 
            MCU_UTIL, 
            "-c",
            "-i", 
            tty,
            "-s"
        ])
    else:
        logging.info("MCU %s not found in configuration.", mcu_name)    

# 主函数
def main():
    need_to_flash = []  # 改为局部变量
    
    # 获取硬件固件信息
    logging.info("Collecting hardware firmware information...")
    hw_fw_info = get_hw_fw_info()
    logging.info("Detected hardware firmware:" + json.dumps(hw_fw_info, indent=2))

    # 获取更新固件信息
    logging.info("Collecting available firmware information...")
    update_fw_info = collect_update_fw_info()
    logging.info("Available firmware updates:" + json.dumps(update_fw_info, indent=2))

    # 转换为字典便于查找
    update_fw_dict = {info["mcu"]: info for info in update_fw_info}

    # 比较版本信息
    for hw_info in hw_fw_info:
        mcu = hw_info["mcu"]
        if mcu in update_fw_dict:
            update_info = update_fw_dict[mcu]
            # 比较版本号
            if (int(update_info["fw_version"]) > int(hw_info["fw_version"]) or
                (int(update_info["fw_version"]) == int(hw_info["fw_version"]) and 
                 int(update_info["revision"]) > int(hw_info["revision"]))):
                logging.info("MCU %s needs update: %s.%s -> %s.%s",
                             mcu, hw_info['fw_version'], hw_info['revision'],
                             update_info['fw_version'], update_info['revision'])
                need_to_flash.append(mcu)
            else:
                logging.info("MCU %s is up to date: %s.%s",
                             mcu, hw_info['fw_version'], hw_info['revision'])
                start_mcu(mcu)
        else:
            logging.info("No firmware update available for %s", mcu)

    # 处理未检测到的MCU
    detected_mcus = {info["mcu"] for info in hw_fw_info}
    for mcu in MCU_CONFIG.keys():
        if mcu not in detected_mcus:
            logging.info("MCU %s not detected, needs flashing", mcu)
            need_to_flash.append(mcu)

    # 烧写固件
    if need_to_flash:
        logging.info("Flashing required for: %s", need_to_flash)
        for mcu_name in set(need_to_flash):  # 去重
            flash_mcu(mcu_name)
        logging.info("Flashing completed. Please restart the system.")
    else:
        logging.info("All MCUs are up to date.")

if __name__ == "__main__":
    main()