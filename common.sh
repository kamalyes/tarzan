#!/usr/bin/env bash

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