#!/usr/bin/env bash
source ./variables.sh

# cancel centos alias
[[ -f /etc/redhat-release ]] && unalias -a

action=$1
set -e  # 如果任何命令失败，退出脚本
trap 'echo "An error occurred. Exiting."; exit 1;' ERR

function log() {
    message="$message_title $1 "
    echo -e "\033[32m## ${message} \033[0m\n" 2>&1 | tee -a ${TARZAN_INSTALL_LOG}
}

function color_title() {
  echo -e "\033[$1$2 \033[0m\n" 2>&1 | tee -a ${TARZAN_INSTALL_LOG}
}

function color_echo() {
  # 输出带颜色的文本，并同时记录到日志文件
  message="$message_title $2 "
  echo -e "\033[$1## ${message} \033[0m\n" 2>&1 | tee -a ${TARZAN_INSTALL_LOG}
}

function run_command() {
    local command="$1"
    
    color_echo ${green} "Executing command: $command"  # 使用绿色输出命令
    
    # 执行命令并捕获输出和错误
    { 
      eval "$command" 2>&1 | tee -a "${TARZAN_INSTALL_LOG}"
    } || {
      color_echo ${red} "Error executing: $command"  # 使用红色输出错误
      return 1  # 返回错误代码
    }
}

function restart_network(){
    # 对于基于 Systemd 的系统
    run_command "systemctl restart network"
    # 对于某些特殊系统
    run_command "service network restart"
}

# yum安装函数模板
function yum_install_template() {
  rpm_path=$1
  component_name=$2

  if which "$component_name" >/dev/null; then
      which_prompt="检测到本地已安装 $component_name"
      install_prompt="覆盖安装 $component_name"
    else
      install_prompt="安装 $component_name"
    fi

    if prompt_for_confirmation "$which_prompt" "$install_prompt"; then
      log "开始 ${install_prompt}"
      if rpm -ivhU "$rpm_path"/*.rpm --nodeps --force; then
        log "${install_prompt} 完成"
      else
        color_echo ${red} "安装 ${install_prompt} 失败"
        exit 1
      fi
    fi
}


# 函数用于询问确认
function prompt_for_confirmation() {
    read -p "$1 请确认是否$2? [n/y]" __choice </dev/tty
    case "$__choice" in
        y | Y)
            return 0
            ;;
        n | N )
            color_echo ${yellow} "退出$2"
            return 1
            ;;
    esac
}

function check_components() {
    local components=("$@")
    local all_ok=true
    for component in "${components[@]}"; do
        log "检查 $component 是否正常安装"
        if command -v "$component" > /dev/null; then
            log "$component 本地已安装"
        else
            color_echo ${yellow} "本地没有找到 $component 应用"
            all_ok=false
        fi
    done

    # 根据检查结果返回状态
    if [ "$all_ok" = true ]; then
        log "所有组件状态正常"
        return 0
    else
        color_echo ${yellow} "某些组件状态异常"
        return 1
    fi
}

function enable_service() {
  # 设置被检测的服务名称
  local service_name=$1
  # 设置心跳检测的时间间隔（秒）
  heartbeat_interval=3
  check_components "$service_name"
  while true; do
      # log "所有已启用的服务："
      # systemctl list-unit-files | grep enabled
      log "检查 $service_name 服务是否已设置为开机自启"
      if systemctl list-unit-files | grep enabled | grep -q $service_name; then
        log "$service_name 服务已设置为开机自启"
      else
        color_echo ${yellow} "$service_name 未设置为开机自启，正在设置..."
        run_command "systemctl enable "$service_name" --now"
        log "$service_name 开机自启设置完成"
      fi
      # 检查服务是否存活
      log "检查 $service_name 服务是否为运行状态"
      status=$(systemctl is-active $service_name)
      if [[ $status == "active" ]]; then
          # 如果服务存活，输出提示信息
          log "$service_name 服务已运行"
          return  # 结束循环和函数
      else
          # 如果服务不存活，输出提示信息
          log "$service_name 服务状态 $status"
          # 尝试重启服务
          run_command "systemctl restart $service_name"
          enable_service $service_name
      fi
      # 等待心跳检测的时间间隔
      sleep $heartbeat_interval
  done
}


function retry() {
    local command="$1"
    local max_attempts="$2"
    local interval="$3"
    local count=0

    while [ $count -lt $max_attempts ]; do
        # 执行命令并捕获输出
        OUTPUT=$($command 2>&1)

        # 检查输出中是否包含 "Ready"
        if echo "$OUTPUT" | grep -q "Ready"; then
            return 0  # 成功，返回0
        fi

        # 增加计数器
        ((count++))
        log "第 $count 次尝试, 等待 $interval 秒后重试..."
        sleep $interval
    done

    # 超过最大尝试次数后返回1
    return 1
}

# 定义下载函数
function download_packages() {
    local folder="$1"
    local base_url="$2"
    shift 2
    for package in "$@"; do
      local package_path="$TARZAN_OFFLINE_PATH/$folder/$package"
      local package_url="$base_url$package"

      # 检查包是否已存在
      if [ -f "$package_path" ]; then
          color_echo ${yellow} "$package 已存在，跳过下载。"
      else
          # 检查 URL 是否有效
          if wget --spider -q "$package_url"; then
              log "高速下载 $package ..."
              wget -P "$TARZAN_OFFLINE_PATH/$folder" "$package_url"
          else
              color_echo ${red} "$package_url 地址访问错误, 跳过下载。"
          fi
      fi
    done
}

function set_hostname(){
    local hostname=$1
    if [[ $hostname =~ '_' ]];then
        color_echo $yellow "hostname can't contain '_' character, auto change to '-'.."
        hostname=`echo $hostname|sed 's/_/-/g'`
    fi
    echo "set hostname: $(color_title $green $hostname)"
    run_command "hostnamectl set-hostname $hostname"
}

function add_virtual_ip() {
    local public_ip=$1
    local interface=$2
    # 检查公网 IP 是否存在
    echo "add_virtual_ip public_ip: $public_ip interface: $interface"
    if ip a | grep -q "$public_ip"; then
        color_echo ${fuchsia} "IP $public_ip already exists."
    else
        log "IP $public_ip does not exist. Adding virtual IP..."
        # 创建虚拟网卡配置
        cat > /etc/sysconfig/network-scripts/ifcfg-${interface} <<EOF
BOOTPROTO=static
DEVICE=${interface}
IPADDR=$public_ip
PREFIX=32
TYPE=Ethernet
USERCTL=no
ONBOOT=yes
EOF
        # 启用新的虚拟网卡
        if ifup ${interface}; then
            log "Successfully added virtual IP $public_ip."
            # 重启网络
            restart_network
        else
            color_echo ${red} "Failed to add virtual IP $public_ip."
        fi
    fi
}

# 函数：生成自签名证书和私钥，并返回 Base64 编码的证书和私钥
generate_self_signed_cert() {
    local key_file=$1
    local csr_file=$2
    local crt_file=$3
    local common_name=$4
    
    # 生成私钥
    openssl genrsa -out "$key_file" 2048
    
    # 生成证书签名请求 (CSR)
    openssl req -new -out "$csr_file" -key "$key_file" -subj "/CN=$common_name"
    
    # 生成自签名证书
    openssl x509 -req -days 3650 -in "$csr_file" -signkey "$key_file" -out "$crt_file"
    
    # 编码证书
    local base64_encoded_cert=$(cat "$crt_file" | base64 | tr -d '\n')
    
    # 编码私钥
    local base64_encoded_key=$(cat "$key_file" | base64 | tr -d '\n')
    
    # 返回结果
    echo "$base64_encoded_cert" "$base64_encoded_key"
}

function main_entrance() {
  case "${action}" in
    enable_service)
      enable_service "$2"  # 传递服务名称参数
      ;;
    yum_install)
      yum_install_template "$2" "$3"  # 传递 RPM 路径和组件名称
      ;;
    check_components)
      check_components "${@:2}"  # 传递组件列表
      ;;
    set_hostname)
      set_hostname "$2"  # 传递主机名
      ;;
    add_virtual_ip)
      add_virtual_ip "$2" "$3"  # 传递公网 IP 和接口
      ;;
    download_packages)
      download_packages "$2" "$3" "${@:4}"  # 传递文件夹、基础 URL 和包列表
      ;;
    retry_command)
      retry "$2" "$3" "$4"  # 传递命令、最大尝试次数和间隔
      ;;
  esac
}

main_entrance $@