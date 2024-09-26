#!/usr/bin/env bash

# 检查命令是否成功的函数
check_command() {
    if [ $? -ne 0 ]; then
        echo "错误: $1"
        exit 1
    fi
}

# 系统信息
HOSTNAME=$(hostname)
check_command "获取主机名失败"

UPTIME=$(uptime | awk '{print $3,$4}' | sed 's/,//')
check_command "获取运行时间失败"

MANUFACTURER=$(cat /sys/class/dmi/id/chassis_vendor)
check_command "获取制造商信息失败"

PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name)
check_command "获取产品名称失败"

VERSION=$(cat /sys/class/dmi/id/product_version)
check_command "获取产品版本失败"

SERIAL_NUMBER=$(cat /sys/class/dmi/id/product_serial)
check_command "获取序列号失败"

MACHINE_TYPE=$(if [ $(lscpu | grep Hypervisor | wc -l) -gt 0 ]; then echo "虚拟机"; else echo "物理机"; fi)
check_command "获取机器类型失败"

OPERATING_SYSTEM=$(hostnamectl | grep "Operating System" | cut -d ' ' -f5-)
check_command "获取操作系统信息失败"

KERNEL=$(uname -r)
check_command "获取内核版本失败"

ARCHITECTURE=$(arch)
check_command "获取架构信息失败"

PROCESSOR_NAME=$(awk -F':' '/^model name/ {print $2}' /proc/cpuinfo | uniq | sed -e 's/^[ \t]*//')
check_command "获取处理器名称失败"

ACTIVE_USERS=$(w | cut -d ' ' -f1 | grep -v USER | xargs -n1)
check_command "获取活动用户失败"

SYSTEM_MAIN_IP=$(hostname -I)
check_command "获取系统主IP失败"

# CPU/内存使用情况
MEMORY_USAGE=$(free | awk '/Mem/{printf("%.2f%", $3/$2*100)}')
check_command "获取内存使用情况失败"

# 检查交换区是否存在
SWAP_TOTAL=$(free | awk '/Swap/{print $2}')
if [ "$SWAP_TOTAL" -eq 0 ]; then
    SWAP_USAGE="0.00%"  # 如果没有交换区，使用0%
else
    SWAP_USAGE=$(free | awk '/Swap/{printf("%.2f%", $3/$2*100)}')
fi
check_command "获取交换区使用情况失败"

CPU_USAGE=$(awk -v OFMT='%.2f' '/cpu/{printf("%s%%\n", ($2+$4)*100/($2+$4+$5))}' /proc/stat | head -1)
check_command "获取CPU使用情况失败"

# 磁盘使用情况
DISK_USAGE=$(df -Ph | sed s/%//g | awk '{ if($5 > 80) print $0;}')

# 输出结果
echo -e "-------------------------------系统信息----------------------------"
echo -e "主机名:\t\t\t$HOSTNAME"
echo -e "运行时间:\t\t$UPTIME"
echo -e "制造商:\t\t\t$MANUFACTURER"
echo -e "产品名称:\t\t$PRODUCT_NAME"
echo -e "版本:\t\t\t$VERSION"
echo -e "序列号:\t\t\t$SERIAL_NUMBER"
echo -e "机器类型:\t\t$MACHINE_TYPE"
echo -e "操作系统:\t\t$OPERATING_SYSTEM"
echo -e "内核:\t\t\t$KERNEL"
echo -e "架构:\t\t\t$ARCHITECTURE"
echo -e "处理器名称:\t\t$PROCESSOR_NAME"
echo -e "活动用户:\t\t$ACTIVE_USERS"
echo -e "系统主IP:\t\t$SYSTEM_MAIN_IP"
echo ""
echo -e "-------------------------------CPU/内存使用情况------------------------------"
echo -e "内存使用情况:\t\t$MEMORY_USAGE"
echo -e "交换区使用情况:\t\t$SWAP_USAGE"
echo -e "CPU使用情况:\t\t$CPU_USAGE"
echo ""
echo -e "-------------------------------磁盘使用情况 >80%-------------------------------"
echo "$DISK_USAGE"
echo ""
