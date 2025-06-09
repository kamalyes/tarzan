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
  case "$CLOUD_PROVIDER" in
    aliyun)
      log "检测到阿里云 ECS, 切换阿里云内网镜像源"
      MIRROR_ROOT="https://mirrors.cloud.aliyuncs.com"
      ;;
    tencent)
      log "检测到腾讯云 CVM, 切换腾讯云内网镜像源"
      MIRROR_ROOT="https://mirrors.cloud.tencent.com"
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
      status=$(systemctl is-active $service_name)
      if [[ $status == "active" ]]; then
          # 如果服务存活，输出提示信息
          log "$service_name 服务已运行"
          return  # 结束循环和函数
      else
          # 如果服务不存活，输出提示信息
          log "$service_name 服务状态 $status"
          # 尝试重启服务(由外层 while 循环继续心跳检查, 不递归)
          run_command "systemctl restart $service_name"
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

# 全局占位符统一替换(addons 与 components 模板通用; 模板中不存在的占位符替换无副作用,
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