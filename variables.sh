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
SSH_PATH="$HOME/.ssh"  # SSH 配置路径
SSH_PRIVATE_RAS_FILE="$SSH_PATH/id_rsa"  # SSH 私钥文件路径
SSH_PUBLIC_RAS_FILE="$SSH_PATH/id_rsa.pub"  # SSH 公钥文件路径
SSH_MAX_PORT=65535
SSH_COPY_TIMEOUT=600  # ssh 远程分发文件超时(秒), 大文件需要长超时
SSH_EXEC_TIMEOUT=3600  # ssh 远程执行命令超时(秒), 安装类命令需要长超时
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"  # ssh/scp 公共参数: 密钥免密 + 自动接受已知主机 + 连接超时(网络黑洞时快速失败而不是长时间无输出)
SSH_ALIVE_OPTS="-o ServerAliveInterval=15 -o ServerAliveCountMax=4"  # 长时操作(传大文件/远程安装)追加保活探测, 链路中断 ~1 分钟内暴露失败

# -------------------
# 初始化系统配置
# -------------------
PERMISSION=755  # 权限设置
DEFAULT_SSH_PORT=22 # 默认端口
DEFAULT_SSH_PASSWORD="you_ssh_password" # 默认SSH密码
DEFAULT_SSH_TARGET_PATH="~/"
AUTO_CONFIRM="${AUTO_CONFIRM:-0}"  # 全局自动确认交互提示(-y 传入); 取环境变量以便父脚本传递给子脚本
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
DESCHEDULER_VERSION="0.24.0"  # Descheduler 版本
CNI_PLUGINS_VERSION="v1.5.1"  # CNI 插件版本

# 业务扩展版本信息(addons), 大清单按集群实际版本自动隔离(1.23 集群用 *_LEGACY_VERSION 兼容版, 1.28+ 集群用新版)
TRAEFIK_VERSION="3.1.2"  # Traefik 版本(CRD 与部署模板双档共用)
CERT_MANAGER_LEGACY_VERSION="1.13.3"  # Cert Manager 兼容版(k8s 1.23)
CERT_MANAGER_VERSION="1.21.0"  # Cert Manager 版本(k8s 1.28+)
LONGHORN_LEGACY_VERSION="1.6.3"  # Longhorn 兼容版(k8s 1.23)
LONGHORN_VERSION="1.12.0"  # Longhorn 版本(k8s 1.28+)
OPENOBSERVE_VERSION="v0.10.5"  # OpenObserve 版本
OTEL_OPERATOR_LEGACY_VERSION="0.96.0"  # OpenTelemetry Operator 兼容版(k8s 1.23)
OTEL_OPERATOR_VERSION="0.156.0"  # OpenTelemetry Operator 版本(k8s 1.28+)
OTEL_COLLECTOR_VERSION="0.96.0"  # OpenTelemetry Collector Contrib 版本

# 业务组件版本信息(components)
CLICKHOUSE_VERSION="23.8.8.24"  # ClickHouse 版本
COCKROACHDB_VERSION="v23.1.28"  # CockroachDB 版本
NATS_VERSION="2.10.11"  # NATS 版本
VALKEY_VERSION="7.2.5"  # Valkey 版本

# 业务镜像清单(默认官方源, 需私有仓库时改写为 <registry>/<name>:<version> 即可)
CLICKHOUSE_IMAGE="clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}"
COCKROACHDB_IMAGE="cockroach/cockroach:${COCKROACHDB_VERSION}"
NATS_IMAGE="nats:${NATS_VERSION}"
VALKEY_IMAGE="valkey/valkey:${VALKEY_VERSION}"
TRAEFIK_IMAGE="traefik:v${TRAEFIK_VERSION}"
# OpenObserve 官方双源发布(ECR/Docker Hub 同 tag), 用 docker.io 源: ECR 国内不可达, docker.io 可走云厂商内网 mirror
OPENOBSERVE_IMAGE="openobserve/openobserve:${OPENOBSERVE_VERSION}"
OTEL_COLLECTOR_IMAGE="otel/opentelemetry-collector-contrib:${OTEL_COLLECTOR_VERSION}"

# 业务组件安装信息(components 由 install-components.sh 动态生成, 不维护静态yaml)
TARZAN_COMPONENTS_PATH="components"  # 业务组件清单动态生成路径
COMPONENT_NAMESPACE="component"  # 业务组件命名空间
COMPONENT_SECRETS="component-secrets"  # 业务组件密钥名称
MONITORING_NAMESPACE="monitoring"  # 监控组件命名空间
MONITORING_SECRETS="monitoring-secrets"  # 监控组件密钥名称
LONGHORN_STORAGE_CLASS="longhorn"  # Longhorn 默认 StorageClass 名称(v1.6.x)
COMPONENT_SECRETS_TEMPLATE_FILE="conf/components.env.template"  # 业务组件密钥模板
COMPONENT_SECRETS_ENV_FILE="conf/components.env"  # 业务组件密钥(运行时生成)

# Ingress Controller 选择(traefik 与 ingress-nginx 二选一, 传参 --traefik / --ingress-nginx)
KUBE_INGRESS_PLUGIN=""
TRAEFIK_DEPLOY_MODE="deployment"  # Traefik 部署形态: deployment(control-plane) / daemonset(每节点)
TRAEFIK_ACME_EMAIL="example@example.com"  # Traefik ACME 证书申请邮箱, 请替换为实际值

# OTel 采集部署命名空间与排除的日志命名空间(避免采集管理面日志)
OTEL_BUSINESS_NAMESPACE="business"
OTEL_OPENAPI_NAMESPACE="openapi"
OTEL_EXCLUDE_LOG_NAMESPACE_1="kube-system"
OTEL_EXCLUDE_LOG_NAMESPACE_2="monitoring"

# 业务组件副本数(routes/join 列表据此动态计算, 改副本数无需改生成逻辑)
CLICKHOUSE_REPLICAS=1
COCKROACHDB_REPLICAS=3
NATS_REPLICAS=3
VALKEY_REPLICAS=2
VALKEY_CLUSTER_REPLICAS=6

# CockroachDB 证书信息(节点证书 SAN 追加的外部域名与公网 IP, 请替换为实际值)
COCKROACHDB_EXTERNAL_DOMAIN="cockroach.example.com"
COCKROACHDB_PUBLIC_IP="192.0.2.10"
COCKROACHDB_CERTS_PATH="conf/cockroachdb-certs"

IMAGE_FILE_PATH="$TARZAN_OFFLINE_PATH/images/images.lock"  # 镜像文件路径

# -------------------
# 系统信息
# -------------------
# 发行版识别: CentOS 7 支持离线+在线安装, CentOS 8 / Debian 仅在线安装
OS_ID=$(grep '^ID=' /etc/os-release | cut -d '=' -f 2 | tr -d '"')
OS_VERSION=$(grep '^VERSION_ID=' /etc/os-release | cut -d '=' -f 2 | tr -d '"' | cut -d '.' -f 1)
case "$OS_ID" in
  centos|rhel|rocky|almalinux)
    OS_FAMILY="rhel" ;;
  debian|ubuntu)
    OS_FAMILY="debian" ;;
  *)
    OS_FAMILY="unsupported" ;;
esac

# 离线包按 el7 RPM 组织, 仅 CentOS 7 支持离线安装
OFFLINE_SUPPORTED=0
if [[ "$OS_FAMILY" == "rhel" && "$OS_VERSION" == "7" ]]; then
  OFFLINE_SUPPORTED=1
fi

CENTOS_VERSION=7  # CentOS 7 离线包(el7)专用版本号
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
# 软件源端点(云厂商自适应: 阿里云/腾讯云走内网镜像, AWS 走官方源, 由 ensure_cloud_mirrors() 按需覆盖)
# -------------------
CLOUD_PROVIDER="other"  # 云厂商: other/aliyun/tencent/aws, 由 detect_cloud_provider() 探测
MIRROR_ROOT="https://mirrors.aliyun.com"  # 镜像根(阿里云/腾讯云内网域名同构, 可整体切换)

# -------------------
# RPM 基础 URL(仅 CentOS 7 离线下载使用)
# -------------------
RPM_BASE_URL="${MIRROR_ROOT}/centos/${CENTOS_VERSION}/os/${ARCHITECTURE}/Packages/"  # RPM 基础 URL
RPM_DOCKER_URL="${MIRROR_ROOT}/docker-ce/linux/centos/${CENTOS_VERSION}/${ARCHITECTURE}/stable/Packages/"  # Docker RPM URL
RPM_KUBERNETES_URL="${MIRROR_ROOT}/kubernetes/yum/repos/kubernetes-el7-${ARCHITECTURE}/Packages/"  # Kubernetes RPM URL
GITHUB_CONTAINERNETWORKING_URL="https://github.com/containernetworking/plugins/releases/download"  # Container Networking GitHub URL

# -------------------
# 在线安装源(CentOS 8 已 EOL 走归档源, Debian 走镜像)
# -------------------
CENTOS8_VAULT_BASE="${MIRROR_ROOT}/centos-vault/8.5.2111"  # CentOS 8 归档源
EPEL8_ARCHIVE_URL="${MIRROR_ROOT}/epel-archive/epel/8/Everything/${ARCHITECTURE}"  # EPEL 8 归档源(sshpass)
DOCKER_CE_YUM_BASE="${MIRROR_ROOT}/docker-ce/linux/centos"  # Docker CE YUM 源(el7/el8)
DOCKER_CE_APT_BASE="${MIRROR_ROOT}/docker-ce/linux/debian"  # Docker CE APT 源
KUBERNETES_YUM_BASE="${MIRROR_ROOT}/kubernetes/yum"  # Kubernetes YUM 源(el7/el8)
KUBERNETES_APT_BASE="${MIRROR_ROOT}/kubernetes/apt"  # Kubernetes APT 源
KUBERNETES_YUM_REPO_URL="${KUBERNETES_YUM_BASE}/repos/kubernetes-el${OS_VERSION}-${ARCHITECTURE}"  # Kubernetes YUM repo 完整 URL
