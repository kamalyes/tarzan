#!/usr/bin/env bash
action=$1
set -e  # 如果任何命令失败，退出脚本
trap 'echo "An error occurred. Exiting."; exit 1;' ERR

__CURRENT_DIR=$(
  cd "$(dirname "$0")"
  pwd
)

TZ_BASE=${TZ_BASE:-/opt/tarzan}

#######color code########
red="31m"  
green="32m"
yellow="33m" 
blue="36m"
fuchsia="35m"
message_title="[Tarzan Log]: $(date +'%Y-%m-%d %H:%M:%S') -"

function log() {
    message="$message_title $1 "
    echo -e "\033[32m## ${message} \033[0m\n" 2>&1 | tee -a ${__CURRENT_DIR}/install.log
}

function color_echo() {
  # 输出带颜色的文本，并同时记录到日志文件
  message="$message_title $2 "
  echo -e "\033[$1## ${message} \033[0m\n" 2>&1 | tee -a ${__CURRENT_DIR}/install.log
}

function run_command() {
    local command="$1"
    
    # 使用 color_echo 输出命令
    color_echo ${green} "Executing: $command"  # 使用绿色输出命令
    
    # 执行命令并捕获输出和错误
    { 
      eval "$command" 2>&1 | tee -a "${__CURRENT_DIR}/install.log"
    } || {
      color_echo ${red} "Error executing: $command"  # 使用红色输出错误
      return 1  # 返回错误代码
    }
}

# 安装路径
SYSCTLD_PATH="/etc/sysctl.d"
KUBERNETES_CONFIG="$SYSCTLD_PATH/kubernetes.conf"
VAR_PATH="/var/lib"
KUBELET_IJOIN_PATH="$VAR_PATH/kubelet"
KUBERNETES_PATH="/etc/kubernetes"
KUBERNETES_PKI_PATH="$KUBERNETES_PATH/pki"
KUBERNETES_ETCD="$VAR_PATH/etcd"
SELINUX_CONF_PATH="/etc/selinux/config"
KUBERNETES_MODULES_CONF="/etc/modules-load.d/k8s-modules.conf"
SYSTEM_CONFIG_PATH="/etc/systemd/system.conf.d"
KUBERNETES_ACCOUNTING_CONF=$SYSTEM_CONFIG_PATH/kubernetes-accounting
SECURITY_LIMITS_CONF="/etc/security/limits.conf"
CONTAINERD_ETC_PATH="/etc/containerd"
CONTAINERD_CONF="$CONTAINERD_ETC_PATH/config.toml"
CONTAINERD_OCICRYPT_KEYS_CONF="$CONTAINERD_ETC_PATH/ocicrypt/keys"
CONTAINERD_OCICRYPT_KEYPROVIDER_CONF="$CONTAINERD_ETC_PATH/ocicrypt/ocicrypt_keyprovider.conf"
CHRONY_CONF="/etc/chrony.conf"
KUBERNETES_YUM_REPO_CONF="/etc/yum.repos.d/kubernetes.repo"
CRICTL_CONF="/etc/crictl.yaml"
CNI_INSTALL_PATH="/opt/cni/bin"
CNI_NET_PATH="/etc/cni/net.d"
KUBE_FLANNEL_CFG_MOUNTPATH="/etc/kube-flannel"
KUBE_FLANNEL_RUN_MOUNTPATH="/run/flannel"
CONTAINERD_OPT_PATH="/opt/containerd"
CONTAINERD_RUN_PATH="/run/containerd"
CONTAINERD_DATA_PATH="/data/containerd"
CONTAINERD_MAX_RECV_MESSAGE_SIZE=16777216
CONTAINERD_MAX_SEND_MESSAGE_SIZE=16777216
CRI_SOCKET_SOCK_FILE="$CONTAINERD_RUN_PATH/containerd.sock"
CRI_RUNTIME_ENDPOINT="unix://$CONTAINERD_RUN_PATH/containerd.sock"
TARZAN_OFFLINE_PATH="offline"
CRICTL_IMAGE_TAR_PATH="$TARZAN_OFFLINE_PATH/crictl-images"

# 初始化系统  必须使用root或者具备sudo权限帐号运行

PERMISSION=755
IS_MASTER=0
KUBE_VERSION="1.23.3"
ONLY_INSTALL_DEPEND="false"
KUBE_ADVERTISE_ADDRESS=$(cat /etc/hosts | grep localhost | awk '{print $1}' | awk 'NR==1{print}')
KUBE_BIND_PORT="6443"
KUBE_TOKEN="tarzan.e6fa0b76a6898af7"
NODE_PACKAGE_PATH="kube_slave"
ADDONS_IMAGE_REPOSITORY="registry.cn-shenzhen.aliyuncs.com/isimetra"
GLOBAL_IMAGE_REPOSITORY="registry.cn-hangzhou.aliyuncs.com/google_containers"
# imagePullPolicy: IfNotPresent 是 Kubernetes 中 Pod 配置的一部分，指定了在创建 Pod 时如何拉取容器镜像。以下是 imagePullPolicy 的三种主要策略的简要说明：
# Always: 每次启动 Pod 时都会尝试拉取最新的镜像。适用于开发环境或需要确保使用最新镜像的场景。
# IfNotPresent: 只有在本地不存在指定的镜像时，才会从镜像仓库拉取。适用于大多数生产环境，因为它可以减少不必要的网络流量和拉取时间。
# Never: 不会尝试拉取镜像，只会使用本地已有的镜像。如果本地没有指定的镜像，Pod 将无法启动。适用于在本地开发或测试时。
KUBE_IMAGE_PULL_POLICY="IfNotPresent"
KUBE_ADMIN_CONFIG_FILE="$KUBERNETES_PATH/admin.conf"
KUBE_NODE_NAME="k8s-master"
KUBE_NETWORK="flannel"
KUBE_PAUSE_VERSION="3.6"
CONTAINERD_TIME_OUT="4h0m0s"
KUBE_POD_SUBNET="172.22.0.0/16"
KUBE_SERVICE_SUBNET="10.96.0.0/12"
KUBE_TIME_ZONE="Asia/Shanghai"
# 获取内网 IP 地址
INTRANET_IP=$(hostname -I | awk '{print $1}')

FLANNEL_VERSION="0.24.0"
CALICO_VERSION="3.26.1"
DASHBOARD_VERSION="2.5.1"
INGRESS_NGINX_VERSION="1.6.3"
METRICS_VERSION="0.6.4"
STATE_METRICS_STANDARD_VERSION="2.10.0"
CNI_PLUGINS_VERSION="v1.5.1"

IMAGE_FILE_PATH="$TARZAN_OFFLINE_PATH/images/images.lock"

# 获取系统版本和架构
CENTOS_VERSION=$(rpm -E '%{centos}')
ARCHITECTURE=$(uname -m)
KERNEL_VERSION=$(uname -r)
# 提取主版本号和次版本号
MAJOR_KERNEL_VERSION=$(echo "$KERNEL_VERSION" | cut -d '.' -f 1)
MINOR_KERNEL_VERSION=$(echo "$KERNEL_VERSION" | cut -d '.' -f 2)

# 处理下如果不是7的，直接复用7
if [[ $CENTOS_VERSION -ne 7 ]]; then
    color_echo ${fuchsia} "centos系统版本>7,centos_version=$CENTOS_VERSION, kernel_version=$KERNEL_VERSION, major_kernel_version=$MAJOR_KERNEL_VERSION, minor_kernel_version=$MINOR_KERNEL_VERSION, 降级使用7"
    CENTOS_VERSION=7
fi

# 动态生成 RPM 基础 URL
RPM_BASE_URL="http://mirrors.aliyun.com/centos/${CENTOS_VERSION}/os/${ARCHITECTURE}/Packages/"
RPM_DOCKER_URL="https://mirrors.aliyun.com/docker-ce/linux/centos/${CENTOS_VERSION}/${ARCHITECTURE}/stable/Packages/"
RPM_KUBERNETES_URL="https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-${ARCHITECTURE}/Packages/"
GITHUB_CONTAINERNETWORKING_URL="https://github.com/containernetworking/plugins/releases/download"

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

function main_entrance() {
  case "${action}" in
  enable_service)
    enable_service
    ;;
  esac
}
main_entrance $@