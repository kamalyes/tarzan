#!/usr/bin/env bash
source ./variables.sh

# cancel centos alias
[[ -f /etc/redhat-release ]] && unalias -a

# 本机主机名: 群控场景下本地与远程(slave 流式回显)日志混合输出, 每行日志标注来源机器
LOCAL_HOSTNAME=$(hostname)

action=$1
set -e  # 如果任何命令失败，退出脚本
trap 'echo "An error occurred. Exiting."; exit 1;' ERR

function log() {
    # 时间戳实时生成(若在 source 时求值会固定为脚本启动时刻, 长流程日志无法判断实际耗时)
    message="[$COMMON_NAME Log@$LOCAL_HOSTNAME]: $(date +'%Y-%m-%d %H:%M:%S') - $1 "
    echo -e "\033[32m## ${message} \033[0m\n" 2>&1 | tee -a ${TARZAN_INSTALL_LOG}
}

function color_title() {
  echo -e "\033[$1$2 \033[0m\n" 2>&1 | tee -a ${TARZAN_INSTALL_LOG}
}

function color_echo() {
  # 输出带颜色的文本，并同时记录到日志文件(时间戳实时生成, 同 log)
  message="[$COMMON_NAME Log@$LOCAL_HOSTNAME]: $(date +'%Y-%m-%d %H:%M:%S') - $2 "
  echo -e "\033[$1## ${message} \033[0m\n" 2>&1 | tee -a ${TARZAN_INSTALL_LOG}
}

function run_command() {
    local command="$1"

    color_echo ${green} "Executing command: $command"  # 使用绿色输出命令

    # 执行命令并捕获输出和错误(PIPESTATUS[0] 取真实退出码, 避免管道 tee 掩盖失败)
    eval "$command" 2>&1 | tee -a "${TARZAN_INSTALL_LOG}"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
      color_echo ${red} "Error executing: $command"  # 使用红色输出错误
      return 1  # 返回错误代码
    fi
}

# 通过云厂商 metadata 服务探测运行环境(内网链路地址, 非云环境自动跳过)
function detect_cloud_provider() {
  if curl -s --connect-timeout 3 http://100.100.100.200/latest/meta-data/instance-id >/dev/null 2>&1; then
    CLOUD_PROVIDER="aliyun"      # 阿里云 ECS
  elif curl -s --connect-timeout 3 http://metadata.tencentyun.com/latest/meta-data/instance-id >/dev/null 2>&1; then
    CLOUD_PROVIDER="tencent"    # 腾讯云 CVM
  else
    # AWS EC2 兼容 IMDSv1/IMDSv2(新账号默认强制 token)
    local imds_token
    imds_token=$(curl -s -X PUT --connect-timeout 3 -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.123/latest/api/token 2>/dev/null)
    if [[ -n "$imds_token" ]] && curl -s --connect-timeout 3 -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.123/latest/meta-data/instance-id >/dev/null 2>&1; then
      CLOUD_PROVIDER="aws"      # AWS EC2
    else
      CLOUD_PROVIDER="other"    # 裸机/其他云, 保持默认公网镜像
    fi
  fi
}

# 云厂商软件源端点自适应(阿里云/腾讯云切换内网镜像域名, AWS 切换官方源), 依赖 KUBE_VERSION 已赋值
function ensure_cloud_mirrors() {
  detect_cloud_provider
  # docker.io 加速段缺省为空(直连), 腾讯云分支覆写; 供 update_containerd_conf 嵌入 config.toml 的 mirrors 段
  DOCKER_IO_MIRROR_CONF=""
  case "$CLOUD_PROVIDER" in
    aliyun)
      log "检测到阿里云 ECS, 切换阿里云内网镜像源"
      MIRROR_ROOT="https://mirrors.cloud.aliyuncs.com"
      ;;
    tencent)
      log "检测到腾讯云 CVM, 切换腾讯云内网镜像源"
      MIRROR_ROOT="https://mirrors.cloud.tencent.com"
      # 腾讯云内网 mirror 全量代理 docker.io 免公网流量(longhorn 等社区镜像直连 docker.io 会超时);
      # 阿里云个人加速已停 / AWS 海外直连快, 其他云保持直连
      DOCKER_IO_MIRROR_CONF='      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
        endpoint = ["https://mirror.ccs.tencentyun.com"]'
      ;;
    aws)
      log "检测到 AWS EC2, 切换海外可达的官方源"
      ;;
  esac

  if [[ "$CLOUD_PROVIDER" == "aws" ]]; then
    # AWS 官方源布局(CentOS 7 已 EOL 进 vault, k8s 源按 minor 版本路由)
    local k8s_minor=${KUBE_VERSION%.*}
    RPM_BASE_URL="https://vault.centos.org/7.9.2009/os/${ARCHITECTURE}/Packages/"
    RPM_DOCKER_URL="https://download.docker.com/linux/centos/${CENTOS_VERSION}/${ARCHITECTURE}/stable/Packages/"
    RPM_KUBERNETES_URL="https://pkgs.k8s.io/core:/stable:/v${k8s_minor}/rpm/Packages/"
    CENTOS8_VAULT_BASE="https://vault.centos.org/8.5.2111"
    EPEL8_ARCHIVE_URL="https://archive.fedoraproject.org/pub/archive/epel/8/Everything/${ARCHITECTURE}"
    DOCKER_CE_YUM_BASE="https://download.docker.com/linux/centos"
    DOCKER_CE_APT_BASE="https://download.docker.com/linux/debian"
    KUBERNETES_YUM_REPO_URL="https://pkgs.k8s.io/core:/stable:/v${k8s_minor}/rpm"
    KUBERNETES_APT_BASE="https://pkgs.k8s.io/core:/stable:/v${k8s_minor}/deb"
  else
    # 国内云与裸机统一基于镜像根拼装(目录布局同构)
    RPM_BASE_URL="${MIRROR_ROOT}/centos/${CENTOS_VERSION}/os/${ARCHITECTURE}/Packages/"
    RPM_DOCKER_URL="${MIRROR_ROOT}/docker-ce/linux/centos/${CENTOS_VERSION}/${ARCHITECTURE}/stable/Packages/"
    RPM_KUBERNETES_URL="${MIRROR_ROOT}/kubernetes/yum/repos/kubernetes-el7-${ARCHITECTURE}/Packages/"
    CENTOS8_VAULT_BASE="${MIRROR_ROOT}/centos-vault/8.5.2111"
    EPEL8_ARCHIVE_URL="${MIRROR_ROOT}/epel-archive/epel/8/Everything/${ARCHITECTURE}"
    DOCKER_CE_YUM_BASE="${MIRROR_ROOT}/docker-ce/linux/centos"
    DOCKER_CE_APT_BASE="${MIRROR_ROOT}/docker-ce/linux/debian"
    KUBERNETES_YUM_REPO_URL="${MIRROR_ROOT}/kubernetes/yum/repos/kubernetes-el${OS_VERSION}-${ARCHITECTURE}"
    KUBERNETES_APT_BASE="${MIRROR_ROOT}/kubernetes/apt"
  fi
}

function restart_network(){
    # 按发行版选择网络服务(CentOS 7: network / Debian: networking / CentOS 8: NetworkManager)
    # 尽力刷新网络即可, 失败不阻塞安装(网卡配置已落盘, 重启后仍会生效)
    if systemctl list-unit-files 2>/dev/null | grep -q "^network\.service"; then
        run_command "systemctl restart network || true"
    elif systemctl list-unit-files 2>/dev/null | grep -q "^networking\.service"; then
        run_command "systemctl restart networking || true"
    else
        run_command "systemctl restart NetworkManager || true"
    fi
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


# 函数用于询问确认(全局 AUTO_CONFIRM=1 时自动放行, 免交互)
function prompt_for_confirmation() {
    if [[ "$AUTO_CONFIRM" == 1 ]]; then
        log "(-y) 自动确认: $2"
        return 0
    fi
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
  # 心跳检测最大重试次数(kubelet 在集群初始化前 crash-loop 属预期状态, 不应无限等待)
  local max_attempts=5
  local attempt=0
  check_components "$service_name"
  while true; do
      # log "所有已启用的服务："
      # systemctl list-unit-files | grep enabled
      log "检查 $service_name 服务是否已设置为开机自启"
      if systemctl list-unit-files | grep enabled | grep -q $service_name; then
        log "$service_name 服务已设置为开机自启"
      else
        color_echo ${yellow} "$service_name 未设置为开机自启，正在设置..."
        run_command "systemctl enable $service_name --now || true"
        log "$service_name 开机自启设置完成"
      fi
      # 检查服务是否存活
      log "检查 $service_name 服务是否为运行状态"
      # is-active 对 activating/failed 状态返回退出码 3, 加 || true 防止 set -e 误杀宿主脚本
      status=$(systemctl is-active $service_name || true)
      if [[ $status == "active" ]]; then
          # 如果服务存活，输出提示信息
          log "$service_name 服务已运行"
          return  # 结束循环和函数
      else
          # 如果服务不存活，输出提示信息
          log "$service_name 服务状态 $status"
          attempt=$((attempt + 1))
          if [[ $attempt -ge $max_attempts ]]; then
              color_echo ${yellow} "$service_name 服务在 $max_attempts 次心跳检测后仍未运行, 跳过等待"
              return 0
          fi
          # 尝试重启服务(由外层 while 循环继续心跳检查, 不递归)
          run_command "systemctl restart $service_name || true"
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

        # 检查输出中是否包含独立的 "Ready"(NotReady 不应误判为就绪)
        if echo "$OUTPUT" | grep -qw "Ready"; then
            return 0  # 成功，返回0
        fi

        # 增加计数器(算术展开赋值, 避免 ((count++)) 首次取值 0 时返回非零触发 set -e)
        count=$((count + 1))
        log "第 $count 次尝试, 等待 $interval 秒后重试..."
        sleep $interval
    done

    # 超过最大尝试次数后返回1
    return 1
}

# 存储类存在性检测(组件 PVC 依赖, 缺失时仅提示不阻塞, 装好 longhorn 后 PVC 自动绑定)
function check_storage_class() {
    if ! kubectl get storageclass 2>/dev/null | awk '{print $1}' | grep -qx "$LONGHORN_STORAGE_CLASS"; then
        color_echo ${yellow} "存储类 $LONGHORN_STORAGE_CLASS 不存在, 相关 PVC 将处于 Pending, 请先执行 install-addons.sh longhorn"
    fi
}

# 等待命名空间内所有 Pod 就绪(兼容多副本/多容器的 READY 列, 跳过已完成Job, 超时退出)
function check_pod_status() {
    local namespace=$1
    local max_attempts=120  # 120次 * 5s = 10分钟上限
    local count=0
    while true; do
        local pods not_ready
        pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null)
        not_ready=$(echo "$pods" | awk '$3!="Completed" && $3!="Succeeded" {split($2,a,"/"); if (a[1]!=a[2]) print $1}')
        # 至少存在 Pod 且无未就绪才算完成(避免控制器建 Pod 前的空列表误判)
        if [ -n "$pods" ] && [ -z "$not_ready" ]; then
            log "${namespace} 全部 Pod 就绪, 安装完成"
            return 0
        fi
        count=$((count + 1))
        if [ $count -ge $max_attempts ]; then
            color_echo ${yellow} "${namespace} 等待 Pod 就绪超时, 未就绪: $(echo $not_ready)"
            return 1
        fi
        log "安装${namespace}进行中, 未就绪: $(echo $not_ready)"
        sleep 5
    done
}

# --- Kubernetes 清单渲染与安装通用机制(addons 与 components 安装器共用) ---

# NATS 集群路由列表, 数量随 NATS_REPLICAS 动态计算(\n 由 sed 渲染时转为换行)
function nats_routes() {
    local routes=""
    for i in $(seq 0 $((NATS_REPLICAS - 1))); do
        routes="${routes}        nats://nats-${i}.nats.${COMPONENT_NAMESPACE}.svc.cluster.local:6222\\n"
    done
    printf '%s' "${routes%\\n}"
}

# CockroachDB 集群 join 列表, 数量随 COCKROACHDB_REPLICAS 动态计算
function cockroach_join() {
    local joins=""
    for i in $(seq 0 $((COCKROACHDB_REPLICAS - 1))); do
        joins="${joins}cockroachdb-${i}.cockroachdb.${COMPONENT_NAMESPACE}.svc.cluster.local:26257,"
    done
    echo "${joins%,}"
}

# OpenObserve Basic Auth 凭据(从运行时密钥文件动态计算, 不写死)
function generate_openobserve_basic_auth() {
    if [ ! -f "$COMPONENT_SECRETS_ENV_FILE" ]; then
        color_echo ${red} "请先执行 install-components.sh secrets 生成密钥"
        exit 1
    fi
    local user password
    user=$(grep '^OPENOBSERVE_ROOT_USER=' "$COMPONENT_SECRETS_ENV_FILE" | cut -d= -f2-)
    password=$(grep '^OPENOBSERVE_ROOT_PASSWORD=' "$COMPONENT_SECRETS_ENV_FILE" | cut -d= -f2-)
    printf '%s:%s' "$user" "$password" | base64 -w 0
}

# 全局占位符统一替换(addons/components/kubeadm init 模板通用; 模板中不存在的占位符替换无副作用,
# 多实例差异量(VALKEY_NAME 等)与档位版本由调用方以环境前缀临时注入)
function replace_manifest_placeholders() {
    local file=$1
    sed -i -e "s|{{COMPONENT_NAMESPACE}}|$COMPONENT_NAMESPACE|g" \
        -e "s|{{COMPONENT_SECRETS}}|$COMPONENT_SECRETS|g" \
        -e "s|{{MONITORING_SECRETS}}|$MONITORING_SECRETS|g" \
        -e "s|{{KUBE_IMAGE_PULL_POLICY}}|$KUBE_IMAGE_PULL_POLICY|g" \
        -e "s|{{LONGHORN_STORAGE_CLASS}}|$LONGHORN_STORAGE_CLASS|g" \
        -e "s|{{TRAEFIK_IMAGE}}|$TRAEFIK_IMAGE|g" \
        -e "s|{{OPENOBSERVE_IMAGE}}|$OPENOBSERVE_IMAGE|g" \
        -e "s|{{OTEL_COLLECTOR_IMAGE}}|$OTEL_COLLECTOR_IMAGE|g" \
        -e "s|{{CLICKHOUSE_IMAGE}}|$CLICKHOUSE_IMAGE|g" \
        -e "s|{{COCKROACHDB_IMAGE}}|$COCKROACHDB_IMAGE|g" \
        -e "s|{{NATS_IMAGE}}|$NATS_IMAGE|g" \
        -e "s|{{VALKEY_IMAGE}}|$VALKEY_IMAGE|g" \
        -e "s|{{CLICKHOUSE_REPLICAS}}|$CLICKHOUSE_REPLICAS|g" \
        -e "s|{{COCKROACHDB_REPLICAS}}|$COCKROACHDB_REPLICAS|g" \
        -e "s|{{NATS_REPLICAS}}|$NATS_REPLICAS|g" \
        -e "s|{{VALKEY_REPLICAS}}|$VALKEY_REPLICAS|g" \
        -e "s|{{VALKEY_CLUSTER_REPLICAS}}|$VALKEY_CLUSTER_REPLICAS|g" \
        -e "s|{{VALKEY_CLUSTER_SEQ_END}}|$((VALKEY_CLUSTER_REPLICAS - 1))|g" \
        -e "s|{{VALKEY_NAME}}|$VALKEY_NAME|g" \
        -e "s|{{VALKEY_PASSWORD_KEY}}|$VALKEY_PASSWORD_KEY|g" \
        -e "s|{{VALKEY_NODEPORT}}|$VALKEY_NODEPORT|g" \
        -e "s|{{NATS_ROUTES}}|$(nats_routes)|g" \
        -e "s|{{COCKROACHDB_JOIN}}|$(cockroach_join)|g" \
        -e "s|{{OTEL_BUSINESS_NAMESPACE}}|$OTEL_BUSINESS_NAMESPACE|g" \
        -e "s|{{OTEL_OPENAPI_NAMESPACE}}|$OTEL_OPENAPI_NAMESPACE|g" \
        -e "s|{{OTEL_EXCLUDE_LOG_NAMESPACE_1}}|$OTEL_EXCLUDE_LOG_NAMESPACE_1|g" \
        -e "s|{{OTEL_EXCLUDE_LOG_NAMESPACE_2}}|$OTEL_EXCLUDE_LOG_NAMESPACE_2|g" \
        -e "s|{{LONGHORN_VERSION}}|$LONGHORN_VERSION|g" \
        -e "s|{{CERT_MANAGER_VERSION}}|$CERT_MANAGER_VERSION|g" \
        -e "s|{{OTEL_OPERATOR_VERSION}}|$OTEL_OPERATOR_VERSION|g" \
        -e "s|{{TRAEFIK_ACME_EMAIL}}|$TRAEFIK_ACME_EMAIL|g" \
        -e "s|{{KUBE_POD_SUBNET}}|$KUBE_POD_SUBNET|g" \
        -e "s|{{ADDONS_IMAGE_REPOSITORY}}|$ADDONS_IMAGE_REPOSITORY|g" \
        -e "s|{{GLOBAL_IMAGE_REPOSITORY}}|$GLOBAL_IMAGE_REPOSITORY|g" \
        -e "s|{{CNI_INSTALL_PATH}}|$CNI_INSTALL_PATH|g" \
        -e "s|{{CNI_NET_PATH}}|$CNI_NET_PATH|g" \
        -e "s|{{KUBE_FLANNEL_CFG_MOUNTPATH}}|$KUBE_FLANNEL_CFG_MOUNTPATH|g" \
        -e "s|{{KUBE_FLANNEL_RUN_MOUNTPATH}}|$KUBE_FLANNEL_RUN_MOUNTPATH|g" \
        -e "s|{{CALICO_IPV4POOL_CIDR}}|$CALICO_IPV4POOL_CIDR|g" \
        -e "s|{{CALICO_IPV4POOL_IPIP}}|$CALICO_IPV4POOL_IPIP|g" \
        -e "s|{{KUBE_ADVERTISE_ADDRESS}}|$KUBE_ADVERTISE_ADDRESS|g" \
        -e "s|{{KUBE_BIND_PORT}}|$KUBE_BIND_PORT|g" \
        -e "s|{{KUBE_TOKEN}}|$KUBE_TOKEN|g" \
        -e "s|{{KUBE_NODE_NAME}}|$KUBE_NODE_NAME|g" \
        -e "s|{{KUBE_VERSION}}|$KUBE_VERSION|g" \
        -e "s|{{KUBE_SERVICE_SUBNET}}|$KUBE_SERVICE_SUBNET|g" \
        -e "s|{{KUBERNETES_PKI_PATH}}|$KUBERNETES_PKI_PATH|g" \
        -e "s|{{KUBERNETES_ETCD}}|$KUBERNETES_ETCD|g" \
        -e "s|{{CRI_SOCKET_SOCK_FILE}}|$CRI_SOCKET_SOCK_FILE|g" \
        "$file"
    # OpenObserve 凭据仅在模板实际引用时生成(避免无关组件因密钥文件缺失而中断)
    if grep -q '{{OPENOBSERVE_BASIC_AUTH}}' "$file"; then
        sed -i "s|{{OPENOBSERVE_BASIC_AUTH}}|$(generate_openobserve_basic_auth)|g" "$file"
    fi
}

# 渲染副本(模板原件永不修改): 单文件直接拷贝, 目录合并其下 yaml, 多路径按序合并
function render_manifest() {
    local target=$1
    shift
    if [ "$#" -eq 1 ] && [ -f "$1" ]; then
        cp "$1" "$target"
        return
    fi
    : > "$target"
    local src
    for src in "$@"; do
        if [ -d "$src" ]; then
            cat "$src"/*.yaml >> "$target"
        else
            cat "$src" >> "$target"
        fi
    done
}

# 从清单动态提取镜像并预拉取(镜像来自渲染后的清单, 不在脚本内写死)
function pull_manifest_images() {
    local file=$1
    local image
    for image in $(grep -E '^[[:space:]]+image:[[:space:]]' "$file" | awk '{print $2}' | tr -d '"' | sort -u); do
        run_command "crictl pull '$image'"
    done
}

# 通用渲染安装: 渲染副本 -> 占位符替换 -> 镜像预拉取 -> 应用
# 需临时覆盖替换变量时用环境前缀调用(如 CERT_MANAGER_VERSION=x install_rendered ...)
function install_rendered() {
    local name=$1
    local target=$2
    shift 2
    log "开始安装 ${name}"
    render_manifest "$target" "$@"
    replace_manifest_placeholders "$target"
    pull_manifest_images "$target"
    run_command "kubectl apply -f $target"
}

# 探测集群次版本号(如 23/28), 大清单按集群实际版本选择兼容目录
function kube_server_minor() {
    kubectl get -o json /version 2>/dev/null | grep -o '"minor": *"[0-9]*"' | grep -o '[0-9][0-9]*'
}

# 1.23 集群返回兼容版(第1参), 1.28+ 集群返回新版(第2参)
function legacy_or_modern() {
    local minor
    minor=$(kube_server_minor)
    if [ -n "$minor" ] && [ "$minor" -ge 28 ]; then
        echo "${2}"
    else
        echo "${1}"
    fi
}

# Ingress Controller 互斥检测(traefik 与 ingress-nginx 都接管 80/443 与 IngressClass, 只能二选一)
function check_ingress_exclusive() {
    local self=$1
    local other=$2
    if kubectl get ingressclass 2>/dev/null | awk '{print $1}' | grep -qx "$other"; then
        color_echo ${red} "检测到 ${other} IngressClass 已存在, ${self} 与 ${other} 二选一, 退出"
        exit 1
    fi
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
        if [[ "$OS_FAMILY" == "debian" ]]; then
            # Debian: /etc/network/interfaces 持久化配置 + ip addr add 立即生效
            cat >> /etc/network/interfaces <<EOF

auto ${interface}
iface ${interface} inet static
    address $public_ip
    netmask 255.255.255.255
EOF
            run_command "ip addr add $public_ip/32 dev ${interface%%:*}"
            log "Successfully added virtual IP $public_ip."
        else
            # rhel 家族: ifcfg 配置(CentOS 8 由 NetworkManager 接管, CentOS 7 走 ifup)
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
            if [[ "$OS_VERSION" == "8" ]] && command -v nmcli >/dev/null 2>&1; then
                run_command "nmcli connection load /etc/sysconfig/network-scripts/ifcfg-${interface}"
                run_command "nmcli connection up ${interface}"
                log "Successfully added virtual IP $public_ip."
                # 重启网络
                restart_network
            elif ifup ${interface}; then
                log "Successfully added virtual IP $public_ip."
                # 重启网络
                restart_network
            else
                color_echo ${red} "Failed to add virtual IP $public_ip."
            fi
        fi
    fi
}

# --- SSH 群控通用能力(基于 conf/ssh_hosts, group-control.sh 与 setup-ssh-keys.sh 共用) ---
# conf/ssh_hosts 格式: user:host:password[:port][:hostname] 每行一台, 第5列主机名供节点命名与派生 conf/hosts, # 之后内容视为注释
# 连接统一走密钥免密, 密码仅用于首次公钥分发(ensure_passwordless)

# conf/ssh_hosts 存在性校验(群控入口统一调用, 缺失即终止)
function require_hosts_file() {
    if [ ! -f "$TARGET_FILE" ]; then
        color_echo ${red} "配置文件 $TARGET_FILE 不存在, 请创建(格式 user:host:password[:port] 每行一台)"
        exit 1
    fi
}

# 从 conf/ssh_hosts 派生 conf/hosts(用户只维护一份清单: 连接信息与主机名规划都在 ssh_hosts)
# 仅取 IP(第2列)与规划主机名(第5列), 密码等连接信息绝不写入 /etc/hosts; 无主机名列的行跳过
function refresh_hosts_file() {
    [ -f "$TARGET_FILE" ] || return 0
    awk -F: '{sub(/#.*/,"")} NF>=5 && $5!="" {print $2, $5}' "$TARGET_FILE" > conf/hosts
}

# 解析 conf/ssh_hosts 为 "user host password port" 行(剥离注释与空行, 端口缺省补默认值)
function parse_machines() {
    local line user host password port hostname
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[$'\t' ]/}"
        [[ -z "$line" ]] && continue
        # 第5列(规划主机名)由 hostname 变量吸收, 否则 read 会把它并入 port
        IFS=':' read -r user host password port hostname <<< "$line"
        [[ -z "$user" || -z "$host" ]] && continue
        echo "$user $host $password ${port:-$DEFAULT_SSH_PORT}"
    done < "$TARGET_FILE"
}

# 查询机器的规划主机名(conf/ssh_hosts 第5列), 未配置返回空
function get_planned_hostname() {
    local host=$1
    awk -F: -v ip="$host" '{sub(/#.*/,"")} $2==ip && $5!="" {print $5; exit}' "$TARGET_FILE" 2>/dev/null
}

# 探测节点的集群角色: master(admin.conf) / joined(有 kubelet.conf 且集群侧有节点记录) /
# half_joined(机器有 kubelet.conf 残留但集群无此节点: 节点记录被删或加入半途中断, 需清理后才能重新加入) /
# fresh(未加入)
# joined 必须交叉校验集群侧记录, 只看机器文件会把半加入残留误判为已加入;
# 本机直接查文件不发起 SSH, 远端短会话探测(僵死会话由 -k 5 强杀兜底), 探测失败返回空
function probe_node_state() {
    local user=$1 host=$2 port=$3
    local state="fresh"
    if is_local_host "$host"; then
        if [ -f /etc/kubernetes/admin.conf ]; then
            state="master"
        elif [ -f /etc/kubernetes/kubelet.conf ]; then
            state="joined"
        fi
    else
        state=$(timeout -k 5 30 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
            'if [ -f /etc/kubernetes/admin.conf ]; then echo master; elif [ -f /etc/kubernetes/kubelet.conf ]; then echo joined; else echo fresh; fi' 2>/dev/null) || true
    fi
    if [[ "$state" == "joined" ]]; then
        # 节点名与加入时同源: 规划名(ssh_hosts 第5列)优先, 缺失时取实际主机名(本机直接 hostname, 远端短会话获取)
        local node_name=$(get_planned_hostname "$host")
        if is_local_host "$host"; then
            [[ -z "$node_name" ]] && node_name=$(hostname)
        else
            [[ -z "$node_name" ]] && node_name=$(timeout -k 5 15 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" "hostname" 2>/dev/null)
        fi
        # 到集群节点名单精确匹配第一列, 无记录则判半加入残留
        kubectl get nodes --no-headers 2>/dev/null | awk -v n="$node_name" '$1==n{f=1} END{exit !f}' || state="half_joined"
    fi
    echo "$state"
}

# 遍历目标机器执行回调, 回调参数: user host password port ...
# 先读全清单再逐台执行(远程 ssh 会消费 while read 的循环 stdin, 边读边执行会吞掉后续机器)
# 单台失败不中断其余机器, 全部处理完后聚合返回失败状态
function for_each_machine() {
    local exec_fn=$1
    shift
    local line user host password port failed=0
    local machines=()
    require_hosts_file
    mapfile -t machines < <(parse_machines)
    for line in "${machines[@]}"; do
        read -r user host password port <<< "$line"
        if ! "$exec_fn" "$user" "$host" "$password" "$port" "$@"; then
            failed=1
        fi
    done
    return $failed
}

# 判断目标主机是否本机(网卡 IP 命中, 或云 metadata 公网 IP 命中: 云主机公网 IP 不在网卡上)
LOCAL_PUBLIC_IP=""
function is_local_host() {
    local host=$1
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "$host" && return 0
    if [[ -z "$LOCAL_PUBLIC_IP" ]]; then
        LOCAL_PUBLIC_IP=$(curl -s --connect-timeout 2 --max-time 5 http://metadata.tencentyun.com/latest/meta-data/public-ipv4 2>/dev/null || true)
        [[ -z "$LOCAL_PUBLIC_IP" ]] && LOCAL_PUBLIC_IP=$(curl -s --connect-timeout 2 --max-time 5 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null || true)
        [[ -z "$LOCAL_PUBLIC_IP" ]] && LOCAL_PUBLIC_IP="none"
    fi
    [[ "$LOCAL_PUBLIC_IP" != "none" && "$LOCAL_PUBLIC_IP" == "$host" ]]
}

# SSH 免密自举: 逐台探测密钥认证, 未免密的机器用 conf/ssh_hosts 的密码分发一次公钥(本机跳过)
function ensure_passwordless() {
    require_hosts_file
    if [ ! -f "$SSH_PRIVATE_RAS_FILE" ]; then
        log "本机不存在 SSH 密钥, 自动生成 $SSH_PRIVATE_RAS_FILE"
        run_command "ssh-keygen -t rsa -b 4096 -N '' -f $SSH_PRIVATE_RAS_FILE"
    fi
    local line user host password port
    local machines=()
    mapfile -t machines < <(parse_machines)
    for line in "${machines[@]}"; do
        read -r user host password port <<< "$line"
        if is_local_host "$host"; then
            continue
        fi
        if timeout -k 5 15 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" "exit" >/dev/null 2>&1; then
            continue
        fi
        log "[$user@$host] SSH 免密未建立, 自动分发公钥"
        if ! command -v sshpass >/dev/null 2>&1; then
            color_echo ${red} "[$user@$host] 缺少 sshpass, 请先安装后重试(yum install -y sshpass)"
            continue
        fi
        # 此处必须走密码认证, 不能带 BatchMode(会禁掉密码认证导致 sshpass 失效)
        # 先自动规范化远端 .ssh 权限(旧机残留的宽松权限会被 sshd StrictModes 拒读, 公钥写入成功也认证不过)
        timeout -k 5 30 sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$port" "$user@$host" \
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" || true
        # stderr 不吞掉: 密码认证失败的真实原因(Permission denied=密码错误, timeout/refused=网络或端口)必须可见
        if ! timeout -k 5 30 sshpass -p "$password" ssh-copy-id -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$port" "$user@$host"; then
            color_echo ${red} "[$user@$host] 公钥分发失败, 请检查 conf/ssh_hosts 的密码与端口"
        fi
    done
}

# 单台远程执行命令(for_each_machine 回调)
function batch_exec() {
    local user=$1 host=$2 password=$3 port=$4
    local command="$5"
    log "[$user@$host] 执行: $command"
    if timeout -k 5 $SSH_EXEC_TIMEOUT ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" "$command"; then
        log "[$user@$host] 执行成功"
    else
        color_echo ${red} "[$user@$host] 执行失败"
        return 1
    fi
}

# 远程分发文件: 优先 rsync(断点续传, 中断后重跑只补传差量), 任一端未装 rsync 时降级 scp
# 注1: 最小化安装的 CentOS/Debian 默认无 rsync, 不能假设目标机可用
# 注2: rsync --info=progress2 与 scp 自带进度条在脚本非交互输出下均不实时刷新(只在结束汇总一行), 统一用并行监控远端已传字节保障过程可见
function remote_copy() {
    local user=$1 host=$2 port=$3 local_file=$4 remote_path=$5
    # 先探测通道: 两端都有 rsync 走断点续传, 否则降级 scp
    local use_rsync=0
    if command -v rsync >/dev/null 2>&1 \
        && timeout -k 5 15 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" "command -v rsync" >/dev/null 2>&1; then
        use_rsync=1
    fi
    # 并行监控: rsync/scp 传输中远端写 .文件名.随机后缀 的临时文件, 周期回显已传字节与百分比
    local local_size=$(stat -c %s "$local_file" 2>/dev/null || echo 0)
    local remote_dir remote_base
    case "$remote_path" in
        */) remote_dir="${remote_path%/}"; remote_base=$(basename "$local_file") ;;
        *)  remote_dir=$(dirname "$remote_path"); remote_base=$(basename "$remote_path") ;;
    esac
    (
        while true; do
            sleep 15
            # set -e 下命令替换失败会杀掉本监控子 shell, 必须兜底; 临时文件查不到时查正式名(传完 rename 的瞬间)
            sent=$(timeout -k 5 15 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
                "stat -c %s $remote_dir/.$remote_base* 2>/dev/null || stat -c %s $remote_dir/$remote_base 2>/dev/null" 2>/dev/null | head -1 || true)
            if [ -n "$sent" ] && [ "$local_size" -gt 0 ]; then
                echo "  [$user@$host] 传输进度: $((sent/1024/1024))MB/$((local_size/1024/1024))MB ($((sent*100/local_size))%)"
            fi
        done
    ) &
    local monitor_pid=$!
    # 传输进程放后台由主循环轮询: 前台运行遇 ssh 会话僵死时 ^C 会卡在 socket 清理上杀不掉;
    # 后台异步进程按 POSIX 忽略 SIGINT, 必须由 trap 显式强杀
    if [[ "$use_rsync" == 1 ]]; then
        # --timeout=60: IO 空闲 60s 自动断开(链路僵死时自杀, 不用等外层 600s)
        rsync --partial --info=progress2 --timeout=60 \
            -e "ssh $SSH_OPTS $SSH_ALIVE_OPTS -p $port" "$local_file" "$user@$host:$remote_path" &
    else
        scp $SSH_OPTS $SSH_ALIVE_OPTS -P "$port" "$local_file" "$user@$host:$remote_path" &
    fi
    local copy_pid=$!
    # ^C 即时响应: 强杀传输与监控进程后退出
    trap "kill -9 $copy_pid $monitor_pid 2>/dev/null; exit 130" INT
    local deadline=$(( $(date +%s) + SSH_COPY_TIMEOUT ))
    local copy_rc=0
    while kill -0 $copy_pid 2>/dev/null; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            copy_rc=1
            break
        fi
        sleep 5
    done
    # 正常完成(进程已退出)先收割退出码; 超时路径进程还活着, 跳过 wait 直接强杀
    if [ "$copy_rc" -eq 0 ]; then
        wait $copy_pid 2>/dev/null || copy_rc=1
    fi
    # 先 disown 再杀: 避免 bash 打印进程终止报告(Terminated/Killed)刷屏
    disown $copy_pid 2>/dev/null || true
    kill -9 $copy_pid 2>/dev/null || true
    trap - INT
    disown $monitor_pid 2>/dev/null || true
    kill -9 $monitor_pid 2>/dev/null || true
    return $copy_rc
}

# 单台远程分发文件(for_each_machine 回调)
function batch_copy() {
    local user=$1 host=$2 password=$3 port=$4
    local local_file=$5 remote_path=$6
    if [ ! -f "$local_file" ]; then
        color_echo ${red} "本地文件 $local_file 不存在"
        return 1
    fi
    log "[$user@$host] 分发: $local_file -> $remote_path"
    if remote_copy "$user" "$host" "$port" "$local_file" "$remote_path"; then
        log "[$user@$host] 分发成功"
    else
        color_echo ${red} "[$user@$host] 分发失败"
        return 1
    fi
}

# 批量执行命令(自动免密自举)
function run_command_on_machines() {
    local command="$1"
    if [ -z "$command" ]; then
        color_echo ${red} "请提供要执行的命令"
        exit 1
    fi
    ensure_passwordless
    for_each_machine batch_exec "$command"
}

# 批量分发文件(自动免密自举)
function copy_file_to_machines() {
    local local_file=$1
    local remote_path=${2:-$DEFAULT_SSH_TARGET_PATH}
    if [ -z "$local_file" ]; then
        color_echo ${red} "请提供要分发的本地文件"
        exit 1
    fi
    ensure_passwordless
    for_each_machine batch_copy "$local_file" "$remote_path"
}

# 打印目标机器清单
function list_machines() {
    require_hosts_file
    log "目标机器清单($TARGET_FILE):"
    parse_machines | awk '{printf "  %s@%s:%s\n", $1, $2, $4}'
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