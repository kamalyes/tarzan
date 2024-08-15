#!/usr/bin/env bash
action=$1

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


# 初始化系统  必须使用root或者具备sudo权限帐号运行

PERMISSION=755
IS_MASTER=0
KUBE_VERSION="1.23.3"
ONLY_INSTALL_DEPEND="false"
KUBE_ADVERTISE_ADDRESS=$(cat /etc/hosts | grep localhost | awk '{print $1}' | awk 'NR==1{print}')
KUBE_BIND_PORT="6443"
KUBE_TOKEN="tarzan.e6fa0b76a6898af7"
NODE_PACKAGE_PATH="kube_slave"
GLOBAL_IMAGE_REPOSITORY="registry.cn-hangzhou.aliyuncs.com/google_containers"
IMAGE_LOAD_TYPE="offline"
KUBE_ADMIN_CONFIG_FILE="/etc/kubernetes/admin.conf"
KUBE_NODE_NAME="k8s-master"
KUBE_NETWORK="flannel"
KUBE_PAUSE_VERSION="3.6"

FLANNEL_VERSION="0.24.0"
CALICO_VERSION="3.26.1"
DASHBOARD_VERSION="2.7.0"
INGRESS_NGINX_VERSION="1.9.5"
METRICS_VERSION="0.6.4"
STATE_METRICS_STANDARD_VERSION="2.10.0"

IMAGE_FILE_PATH="offline/images/images.lock"

function log() {
    message="[Tarzan Log]: $1 "
    echo -e "\033[32m## ${message} \033[0m\n" 2>&1 | tee -a ${__CURRENT_DIR}/install.log
}

function color_echo() {
  echo -e "\033[$1${@:2}\033[0m" 2>&1 | tee -a ${__CURRENT_DIR}/install.log
}

function run_command() {
    echo ""
    local command=$1
    color_echo "$command"
    echo $command | bash
}

# 离线安装函数模板
function offline_install_template() {
  rpm_path=$1
  component_name=$2

  if which "$component_name" >/dev/null; then
      which_prompt="检测到本地已安装 $component_name"
      install_prompt="在线覆盖安装 $component_name"
    else
      install_prompt="在线安装 $component_name"
    fi

    if prompt_for_confirmation "$which_prompt" "$install_prompt"; then
      log "开始 ${install_prompt}"
      if rpm -ivhU "$rpm_path"/*.rpm --nodeps --force; then
        log "${install_prompt} 完成"
      else
        log "安装 ${install_prompt} 失败"
        exit 1
      fi
    fi
}


# 函数用于询问确认
function prompt_for_confirmation() {
    read -p "$which_prompt 请确认是否$install_prompt? [n/y]" __choice </dev/tty
    case "$__choice" in
        y | Y)
            return 0
            ;;
        n | N)
            log "退出$2"
            return 1
            ;;
        *)
            log "退出$2"
            return 1
            ;;
    esac
}

function enable_docker_service() {
    check_component docker
    if which systemctl >/dev/null; then
      log "设置Docker开机启动"
      systemctl enable docker --now 2>&1 | tee -a ${__current_dir}/install.log
    fi
    log "检查Docker服务是否正常运行"
    # 检查Docker是否启动
    if ! docker ps -a > /dev/null 2>&1; then
        log "Docker 未正常启动，请先确保已安装并启动 Docker 服务后再次执行本脚本"
        exit 1
    else
        # 重载配置并重启Docker服务
        # journalctl -u docker # 查看运行日志
        systemctl daemon-reload
        systemctl restart docker
        log "Docker服务已重启完成"
    fi
}

function check_components() {
    for component in "$@"; do
        log "检查$component 状态是否正常"
        if which "$component" > /dev/null; then
            log "$component 状态正常"
        else
            log "$component 状态异常"
            return 1
        fi
    done
}


function enable_kube_service() {
    log "设置kubelet为开机自启并现在立刻启动服务"
    systemctl enable kubelet --now 2>&1 | tee -a ${__current_dir}/install.log
    log "设置kubelet自启完成"
    check_component kubectl kubelet kubeadm
}


function main_entrance() {
  case "${action}" in
  enable_kube_service)
    enable_kube_service
    ;;
  esac
}
main_entrance $@