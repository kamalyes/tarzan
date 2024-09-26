#!/usr/bin/env bash

# 获取当前脚本所在目录
CURRENT_DIR=$(
  cd "$(dirname "$0")"
  pwd
)
COMMON_NAME="Tarzan"
# Tarzan 基础路径及日志文件
TARZAN_BASE=${TARZAN_BASE:-/opt/tarzan}  # 设置 Tarzan 基础路径，如果未定义则使用默认值
TARZAN_INSTALL_LOG="$CURRENT_DIR/install.log"  # Tarzan 安装日志文件路径
TARZAN_INSTALL_LOCK_FILE="$CURRENT_DIR/install.lock"  # Tarzan 安装锁文件路径
TARZAN_OFFLINE_PATH="offline"  # 离线安装路径
TARZAN_ADDONS_PATH="addons" # k8s应用部署文件路径

#######颜色代码########
red="31m"  # 红色
green="32m"  # 绿色
yellow="33m"  # 黄色
blue="36m"  # 蓝色
fuchsia="35m"  # 紫红色
message_title="[$COMMON_NAME Log]: $(date +'%Y-%m-%d %H:%M:%S') -"  # 日志标题，包含当前时间


# -------------------
# 证书信息配置
# -------------------
# 定义变量
OPENSSL_CERT_DIR="certs"          # 指定证书的保存目录
# 证书信息
OPENSSL_COUNTRY="CN"
OPENSSL_STATE="Guangdong"
OPENSSL_CITY="Shenzhen"
OPENSSL_ORGANIZATION="YourOrganization"
OPENSSL_ORGANIZATIONAL_UNIT="YourUnit"
OPENSSL_COMMON_NAME="example.com"  # 请替换为您自己的域名
OPENSSL_EMAIL="example@example.com" # 请替换为您自己的邮箱
# 证书有效期，以天为单位（3 年）
OPENSSL_DAYS=1095
# 生成私钥并将其保存到指定目录
OPENSSL_KEY_PATH="$OPENSSL_CERT_DIR/$OPENSSL_COMMON_NAME.key"
OPENSSL_CRT_PATH="$OPENSSL_CERT_DIR/$OPENSSL_COMMON_NAME.crt"

# -------------------
# 安装路径配置
# -------------------
SYSCTLD_PATH="/etc/sysctl.d"  # sysctl.d 配置文件目录
SYSCTL_CONF="/etc/sysctl.conf"  # sysctl 主配置文件
BACKUP_SYSCTL_CONF="$SYSCTL_CONF.bak.$(date +%Y%m%d%H%M%S)"  # sysctl 配置文件备份路径，包含时间戳
KUBERNETES_CONFIG="$SYSCTLD_PATH/kubernetes.conf"  # Kubernetes 配置文件
VAR_PATH="/var/lib"  # 变量数据路径
KUBELET_IJOIN_PATH="$VAR_PATH/kubelet"  # kubelet 数据路径
KUBERNETES_PATH="/etc/kubernetes"  # Kubernetes 配置路径
KUBERNETES_PKI_PATH="$KUBERNETES_PATH/pki"  # Kubernetes PKI 证书路径
KUBERNETES_ETCD="$VAR_PATH/etcd"  # etcd 数据路径
SELINUX_CONF_PATH="/etc/selinux/config"  # SELinux 配置文件路径
KUBERNETES_MODULES_CONF="/etc/modules-load.d/k8s-modules.conf"  # Kubernetes 模块加载配置文件
SYSTEM_CONFIG_PATH="/etc/systemd/system.conf.d"  # systemd 系统配置目录
KUBERNETES_ACCOUNTING_CONF="$SYSTEM_CONFIG_PATH/kubernetes-accounting"  # Kubernetes 计量配置文件
SECURITY_LIMITS_CONF="/etc/security/limits.conf"  # 安全限制配置文件
CONTAINERD_ETC_PATH="/etc/containerd"  # containerd 配置目录
CONTAINERD_CONF="$CONTAINERD_ETC_PATH/config.toml"  # containerd 主配置文件
CONTAINERD_OCICRYPT_KEYS_CONF="$CONTAINERD_ETC_PATH/ocicrypt/keys"  # containerd OCI 加密密钥配置路径
CONTAINERD_OCICRYPT_KEYPROVIDER_CONF="$CONTAINERD_ETC_PATH/ocicrypt/ocicrypt_keyprovider.conf"  # containerd OCI 加密密钥提供者配置路径
CHRONY_CONF="/etc/chrony.conf"  # Chrony NTP 配置文件路径
KUBERNETES_YUM_REPO_CONF="/etc/yum.repos.d/kubernetes.repo"  # Kubernetes YUM 仓库配置文件
CRICTL_CONF="/etc/crictl.yaml"  # crictl 配置文件路径
CNI_INSTALL_PATH="/opt/cni/bin"  # CNI 插件安装路径
CNI_NET_PATH="/etc/cni/net.d"  # CNI 网络配置路径
KUBE_FLANNEL_CFG_MOUNTPATH="/etc/kube-flannel"  # Flannel 配置挂载路径
KUBE_FLANNEL_RUN_MOUNTPATH="/run/flannel"  # Flannel 运行时挂载路径
CONTAINERD_OPT_PATH="/opt/containerd"  # containerd 选项路径
CONTAINERD_RUN_PATH="/run/containerd"  # containerd 运行时路径
CONTAINERD_DATA_PATH="/data/containerd"  # containerd 数据路径
CONTAINERD_MAX_RECV_MESSAGE_SIZE=16777216  # containerd 最大接收消息大小
CONTAINERD_MAX_SEND_MESSAGE_SIZE=16777216  # containerd 最大发送消息大小
CRI_SOCKET_SOCK_FILE="$CONTAINERD_RUN_PATH/containerd.sock"  # CRI 套接字文件路径
CRI_RUNTIME_ENDPOINT="unix://$CONTAINERD_RUN_PATH/containerd.sock"  # CRI 运行时端点
CRICTL_IMAGE_TAR_PATH="$TARZAN_OFFLINE_PATH/crictl-images"  # crictl 镜像 tar 文件路径
TARGET_FILE="conf/ssh_hosts"  # 目标文件路径
SSH_PATH="~/.ssh"  # SSH 配置路径
SSH_PRIVATE_RAS_FILE="$SSH_PATH/id_rsa"  # SSH 私钥文件路径
SSH_PUBLIC_RAS_FILE="$SSH_PATH/id_rsa.pub"  # SSH 公钥文件路径
SSH_MAX_PORT=65535
KUBE_DASHBOARD_TLS_PATH="$TARZAN_ADDONS_PATH/kube-dashboard"
KUBE_DASHBOARD_TLS_CSR_FILE="$KUBE_DASHBOARD_TLS_PATH/tls.csr"
KUBE_DASHBOARD_TLS_CRT_FILE="$KUBE_DASHBOARD_TLS_PATH/tls.crt"
KUBE_DASHBOARD_TLS_KEY_FILE="$KUBE_DASHBOARD_TLS_PATH/tls.key"

# -------------------
# 初始化系统配置
# -------------------
PERMISSION=755  # 权限设置
DEFAULT_SSH_PORT=22 # 默认端口
DEFAULT_SSH_PASSWORD="you_ssh_password" # 默认SSH密码
DEFAULT_SSH_TARGET_PATH="~/"
IS_MASTER=0  # 是否为主节点，0 表示否
KUBE_VERSION="1.23.3"  # Kubernetes 版本
ONLY_INSTALL_DEPEND="false"  # 是否仅安装依赖
KUBE_ADVERTISE_ADDRESS=$(cat /etc/hosts | grep localhost | awk '{print $1}' | awk 'NR==1{print}')  # 获取主机的广告地址
KUBE_BIND_PORT="6443"  # Kubernetes API 绑定端口
KUBE_TOKEN="tarzan.e6fa0b76a6898af7"  # Kubernetes 令牌
NODE_PACKAGE_PATH="kube_slave"  # 节点包路径
ADDONS_IMAGE_REPOSITORY="registry.cn-shenzhen.aliyuncs.com/isimetra"  # 附加组件镜像仓库
GLOBAL_IMAGE_REPOSITORY="registry.cn-hangzhou.aliyuncs.com/google_containers"  # 全局镜像仓库

# 镜像拉取策略说明
# imagePullPolicy: IfNotPresent 是 Kubernetes 中 Pod 配置的一部分，指定了在创建 Pod 时如何拉取容器镜像。
# Always: 每次启动 Pod 时都会尝试拉取最新的镜像。适用于开发环境或需要确保使用最新镜像的场景。
# IfNotPresent: 只有在本地不存在指定的镜像时，才会从镜像仓库拉取。适用于大多数生产环境，因为它可以减少不必要的网络流量和拉取时间。
# Never: 不会尝试拉取镜像，只会使用本地已有的镜像。如果本地没有指定的镜像，Pod 将无法启动。适用于在本地开发或测试时。
KUBE_IMAGE_PULL_POLICY="IfNotPresent"  # 镜像拉取策略
KUBE_ADMIN_CONFIG_FILE="$KUBERNETES_PATH/admin.conf"  # Kubernetes 管理员配置文件
KUBE_NODE_NAME="k8s-master"  # 节点名称
KUBE_NETWORK="flannel"  # 网络插件
KUBE_PAUSE_VERSION="3.6"  # pause 镜像版本
CONTAINERD_TIME_OUT="4h0m0s"  # containerd 超时时间
KUBE_POD_SUBNET="172.22.0.0/16"  # Pod 子网
KUBE_SERVICE_SUBNET="10.96.0.0/12"  # 服务子网
CALICO_IPV4POOL_CIDR=$KUBE_POD_SUBNET # 配置k8s集群时，设置的pod网络地址段
CALICO_IPV4POOL_IPIP="Never" # 默认配置为Always，配置为Always时使用的时IPIP模式，更改为Never时使用的是bgp模式，使用bgp模式性能更高
KUBE_TIME_ZONE="Asia/Shanghai"  # 时区设置
VIRTUALETH_BACK_PREFIX="eth0:1"  # 虚拟网卡尾缀

# 获取内网 IP 地址
INTRANET_IP=$(hostname -I | awk '{print $1}')

# -------------------
# 版本信息
# -------------------
FLANNEL_VERSION="0.24.0"  # Flannel 版本
CALICO_VERSION="3.24.6"  # Calico 版本
DASHBOARD_VERSION="2.5.1"  # Kubernetes Dashboard 版本
INGRESS_NGINX_VERSION="1.6.3"  # Ingress NGINX 版本
METRICS_VERSION="0.6.4"  # Metrics Server 版本
STATE_METRICS_STANDARD_VERSION="2.10.0"  # State Metrics Standard 版本
CNI_PLUGINS_VERSION="v1.5.1"  # CNI 插件版本

IMAGE_FILE_PATH="$TARZAN_OFFLINE_PATH/images/images.lock"  # 镜像文件路径

# -------------------
# 系统信息
# -------------------
CENTOS_VERSION=$(grep VERSION_ID /etc/os-release | cut -d '=' -f 2 | tr -d '"')  # 获取 CentOS 版本
ARCHITECTURE=$(uname -m)  # 获取系统架构
KERNEL_VERSION=$(uname -r)  # 获取内核版本
# 提取主版本号和次版本号
MAJOR_KERNEL_VERSION=$(echo "$KERNEL_VERSION" | cut -d '.' -f 1)  # 主版本号
MINOR_KERNEL_VERSION=$(echo "$KERNEL_VERSION" | cut -d '.' -f 2)  # 次版本号

# 获取当前内存总量（以MB为单位）
FREE_MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')  # 空闲总内存
TOTAL_MEMORY=$(grep MemTotal /proc/meminfo | awk '{print $2}')  # 总内存
NEW_MAX_MAP_COUNT=$((FREE_MEM_TOTAL / 1024)) # 将总内存转换为MB
CPU_CORES=$(nproc)  # 获取 CPU 核心数

# -------------------
# 根据系统总内存动态计算和设置各个网络和内存参数
# -------------------
# 获取系统总内存（以千字节为单位）
TOTAL_MEMORY=$(grep MemTotal /proc/meminfo | awk '{print $2}')
# fs.file-max: 系统可以打开的最大文件描述符数量
FS_FILE_MAX=$((TOTAL_MEMORY / 16))  # 设置为总内存的 1/16
# netdev_max_backlog: 网络设备的最大等待连接数
NETDEV_MAX_BACKLOG=32768  # 设置为 32768，适用于高并发场景
# somaxconn: 监听队列的最大连接数
SOMAXCONN=32768  # 设置为 32768，适用于高并发场景
# tcp_max_orphans: 最大孤儿连接数
TCP_MAX_ORPHANS=3276800  # 设置为 3276800，防止过多孤儿连接影响性能
# tcp_max_syn_backlog: TCP SYN 队列的最大长度
TCP_MAX_SYN_BACKLOG=16384  # 设置为 16384，适用于高并发场景
# tcp_synack_retries: TCP SYN-ACK 重试次数
TCP_SYNACK_RETRIES=1  # 设置为 1，减少重试次数，加快连接建立
# tcp_syn_retries: TCP SYN 重试次数
TCP_SYN_RETRIES=1  # 设置为 1，减少重试次数，加快连接建立
# ip_local_port_range: 本地端口范围
IP_LOCAL_PORT_RANGE="1024 65000"  # 设置可用的本地端口范围
# tcp_keepalive_intvl: TCP 保活探测间隔，单位为秒
TCP_KEEPALIVE_INTVL=60  # 设置为 60 秒
# tcp_keepalive_probes: TCP 保活探测次数
TCP_KEEPALIVE_PROBES=3  # 设置为 3 次探测
# tcp_keepalive_time: TCP 保活时间，单位为秒
TCP_KEEPALIVE_TIME=1500  # 设置为 1500 秒
# tcp_syn_cookies: 启用 TCP SYN Cookies，以防止 SYN 洪水攻击
TCP_SYN_COOKIES=1  # 启用 SYN Cookies
TCP_IP_FORWARD=1 # 启用ip转发
# tcp_fin_timeout: TCP FIN 连接的超时时间，单位为秒
TCP_FIN_TIMEOUT=30  # 设置为 30 秒
# tcp_max_tw_buckets: TCP TIME_WAIT 桶的最大数量
TCP_MAX_TW_BUCKETS=6000  # 设置为 6000，限制 TIME_WAIT 状态的连接数量
# tcp_timestamps: 启用 TCP 时间戳选项
TCP_TIMESTAMPS=1  # 启用 TCP 时间戳
# tcp_tw_recycle: 禁用 TIME_WAIT 连接的快速回收
TCP_TW_RECYCLE=0  # 禁用快速回收，防止 NAT 问题
# tcp_tw_reuse: 启用 TIME_WAIT 连接的重用
TCP_TW_REUSE=1  # 启用连接重用
# net.core.rmem_default: 默认接收缓冲区大小
RMEM_DEFAULT=$((TOTAL_MEMORY / 1024 * 8))  # 设置为总内存的 8%
# net.core.wmem_default: 默认发送缓冲区大小
WMEM_DEFAULT=$RMEM_DEFAULT  # 设置为与接收缓冲区相同
# net.core.rmem_max: 最大接收缓冲区大小
RMEM_MAX=$((TOTAL_MEMORY / 1024 * 16))  # 设置为总内存的 16%
# net.core.wmem_max: 最大发送缓冲区大小
WMEM_MAX=$RMEM_MAX  # 设置为与接收缓冲区相同
# TCP 接收缓冲区的大小设置，动态调整
TCP_RMEM="10240 87380 $RMEM_MAX"  # 设置为最小 10240，默认 87380，最大 RMEM_MAX
# TCP 发送缓冲区的大小设置，动态调整
TCP_WMEM="10240 87380 $WMEM_MAX"  # 设置为最小 10240，默认 87380，最大 WMEM_MAX
# net.bridge.nf_call_iptables: 启用桥接的 iptables 处理
NET_BRIDGE_NF_CALL_IPTABLES=1  # 启用
# vm.swappiness: 控制内存回收的倾向
VM_SWAPPINESS=0  # 设置为 0，优先使用 RAM，减少 swap 使用
# vm.max_map_count: 最大内存映射数
VM_MAX_MAP_COUNT=$((TOTAL_MEMORY / 64))  # 设置为总内存的 1/64
# disable_ipv6: 禁用ipv6
DISABLE_IPV6=1

# -------------------
# 动态生成 RPM 基础 URL
# -------------------
if (( $(echo "$CENTOS_VERSION > 7" | bc -l) )); then
    echo "centos系统版本>7, centos_version=$CENTOS_VERSION, kernel_version=$KERNEL_VERSION, major_kernel_version=$MAJOR_KERNEL_VERSION, minor_kernel_version=$MINOR_KERNEL_VERSION, 降级使用7"
    CENTOS_VERSION=7  # 如果不是7，降级使用7
fi

RPM_BASE_URL="http://mirrors.aliyun.com/centos/${CENTOS_VERSION}/os/${ARCHITECTURE}/Packages/"  # RPM 基础 URL
RPM_DOCKER_URL="https://mirrors.aliyun.com/docker-ce/linux/centos/${CENTOS_VERSION}/${ARCHITECTURE}/stable/Packages/"  # Docker RPM URL
RPM_KUBERNETES_URL="https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-${ARCHITECTURE}/Packages/"  # Kubernetes RPM URL
GITHUB_CONTAINERNETWORKING_URL="https://github.com/containernetworking/plugins/releases/download"  # Container Networking GitHub URL
