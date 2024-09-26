#!/usr/bin/env bash
source ./common.sh

action=$1

function source_chrony() {
  log "配置chrony同步源 $CHRONY_CONF"
  run_command "timedatectl set-timezone $KUBE_TIME_ZONE"
  cat <<EOF >$CHRONY_CONF
server ntp1.aliyun.com iburst
server ntp2.aliyun.com iburst
server ntp3.aliyun.com iburst
server ntp4.aliyun.com iburst
server ntp5.aliyun.com iburst
server ntp6.aliyun.com iburst
server ntp7.aliyun.com iburst
EOF
  run_command "systemctl restart chronyd.service"
  run_command "chronyc sources -v"
}

function update_kubernetes_conf() {
  log "配置Kubernetes镜像源 $KUBERNETES_YUM_REPO_CONF"

  # 创建Kubernetes YUM仓库配置文件
  if ! grep -q "\[kubernetes\]" "$KUBERNETES_YUM_REPO_CONF"; then
    cat <<EOF >"$KUBERNETES_YUM_REPO_CONF"
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg
      https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF
    log "Kubernetes YUM 仓库配置写入成功"
  else
    log "Kubernetes YUM 仓库配置已存在,跳过写入"
  fi
  
  run_command "mkdir -p $SYSCTLD_PATH"
  run_command "chmod 751 -R $SYSCTLD_PATH"

  # 优化系统参数
cat <<EOF > $KUBERNETES_CONFIG

# 基于内存的自定义网络参数

### 系统级别能够打开的文件句柄的数量。直接限制最大并发连接数。
### 是对整个系统的限制,并不是针对用户的。
### 根据内存动态计算的值
fs.file-max = $FS_FILE_MAX

### 当每个网络接口接受数据包的速率比内核处理速率快时,允许发送到队列的数据包的最大数。
net.core.netdev_max_backlog = $NETDEV_MAX_BACKLOG

### 调节系统同时发起的TCP连接数。高并发情况下,该值越小,越容易出现超时情况。
# net.core.somaxconn = $SOMAXCONN

# see details in https://help.aliyun.com/knowledge_detail/41334.html
### 设定系统中最多允许存在多少TCP套接字不被关联到任何一个用户文件句柄上。
net.ipv4.tcp_max_orphans = $TCP_MAX_ORPHANS

### 记录尚未收到客户端确认信息的连接请求的最大值(三次握手建立阶段接受SYN请求)
net.ipv4.tcp_max_syn_backlog = $TCP_MAX_SYN_BACKLOG

### 设置内核放弃TCP连接之前向客户端发送SYN+ACK包的数据(三次握手中的第二次握手)
net.ipv4.tcp_synack_retries = $TCP_SYNACK_RETRIES

### 设置内核放弃建立连接之前向客户端发送SYN包的数据。
net.ipv4.tcp_syn_retries = $TCP_SYN_RETRIES

### 放大本地端口范围。
net.ipv4.ip_local_port_range = $IP_LOCAL_PORT_RANGE

### 表示某个TCP连接在空闲7200秒后,内核才发起探测,探测9次(每次75秒)不成功,内核才发送RST。
net.ipv4.tcp_keepalive_intvl = $TCP_KEEPALIVE_INTVL
net.ipv4.tcp_keepalive_probes = $TCP_KEEPALIVE_PROBES
net.ipv4.tcp_keepalive_time = $TCP_KEEPALIVE_TIME

net.ipv6.conf.all.disable_ipv6 = $DISABLE_IPV6
net.ipv6.conf.default.disable_ipv6 = $DISABLE_IPV6
net.ipv6.conf.lo.disable_ipv6 = $DISABLE_IPV6

### 启用IPV4 转发
net.ipv4.ip_forward = $TCP_IP_FORWARD

### 启用Cookies来处理,可防范部分SYN攻击,当出现SYN等待队列溢出时也可继续连接。
net.ipv4.tcp_syncookies = $TCP_SYN_COOKIES

### 如果socket由服务端要求关闭,则该参数决定了保持在FIN-WAIT-2状态的时间。
net.ipv4.tcp_fin_timeout = $TCP_FIN_TIMEOUT

### timewait的数量,最大值为262144。如果超过这个数字,TIME_WAIT套接字将立刻被清除并打印警告信息。
net.ipv4.tcp_max_tw_buckets = $TCP_MAX_TW_BUCKETS

### 设置时间戳,避免序列号的卷绕。
net.ipv4.tcp_timestamps = $TCP_TIMESTAMPS

### 允许将TIME-WAIT状态的sockets重新用于新的TCP连接
net.ipv4.tcp_tw_reuse = $TCP_TW_REUSE

### 以下4个参数,需要根据业务逻辑和实际的硬件成本来综合考虑
net.core.rmem_default = $RMEM_DEFAULT
net.core.wmem_default = $WMEM_DEFAULT
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX

### TCP接收socket请求缓存的内存最小值、默认值、最大值
net.ipv4.tcp_rmem = $TCP_RMEM

### TCP发送socket请求缓存的内存最小值、默认值、最大值
net.ipv4.tcp_wmem = $TCP_WMEM

# iptables对bridge的数据进行处理
net.bridge.bridge-nf-call-iptables=$NET_BRIDGE_NF_CALL_IPTABLES
net.bridge.bridge-nf-call-ip6tables=$NET_BRIDGE_NF_CALL_IPTABLES
net.bridge.bridge-nf-call-arptables=$NET_BRIDGE_NF_CALL_IPTABLES

# 禁止使用 swap 空间, 只有当系统 OOM 时才允许使用它
vm.swappiness=$VM_SWAPPINESS
# 计算当前的内存映射文件数
vm.max_map_count=$VM_MAX_MAP_COUNT
EOF

  # 检查内核版本,决定是否添加 tcp_tw_recycle
  if [[ $MAJOR_KERNEL_VERSION -lt 4 ]] || { [[ $MAJOR_KERNEL_VERSION -eq 4 ]] && [[ $MINOR_KERNEL_VERSION -le 12 ]]; }; then
    # 原因：linux>4.12内核版本不兼容
    color_echo ${fuchsia} "检测到内核版本 $KERNEL_VERSION,跳过 tcp_tw_recycle 配置。"
  else
    log "添加tcp_tw_recycle配置"
    echo "### TCP连接中TIME-WAIT的sockets快速回收功能" >> "$KUBERNETES_CONFIG"
    echo "net.ipv4.tcp_tw_recycle = $TCP_TW_RECYCLE" >> "$KUBERNETES_CONFIG"
  fi

  log "创建kube所需文件夹、重新加载配置"
  run_command "mkdir -p $KUBELET_IJOIN_PATH"
  run_command "chmod 777 -R $KUBELET_IJOIN_PATH"
  run_command "mkdir -p $KUBERNETES_PATH"
  run_command "chmod 777 -R $KUBERNETES_PATH"
  
  log "应用新的 sysctl 设置"
  run_command "sysctl -p $KUBERNETES_CONFIG"
}

function rest_firewalld() {
  log "关闭防火墙"
  run_command "systemctl stop firewalld"
  run_command "systemctl disable firewalld"

  log "关闭iptables"
  run_command "systemctl stop iptables"
  run_command "systemctl disable iptables"
  
  log "检查防火墙和iptables状态"
  run_command "systemctl status firewalld"
  run_command "systemctl status iptables"

  log "清空iptables规则"
  run_command "iptables -F"
  run_command "iptables -X"
  run_command "iptables -F -t nat"
  run_command "iptables -X -t nat"
  run_command "iptables -P FORWARD ACCEPT"
}

function disable_swapoff() {
  log "关闭swap"
  #(临时的,只针对当前会话起作用,若会话关闭,重开还是会开启内存交换,所以使用下面一行命令即可)
  run_command "swapoff -a"
  # 永久关闭swap
  run_command "sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab"
  # 验证swap状态,输出内存使用情况
  log "验证swap状态"
  run_command "free -g"
}

function disabled_selinux() {
  log "关闭selinux"
  
  # 临时关闭
  run_command "setenforce 0"
  
  # 永久禁用
  run_command "sed -i '/SELINUX/s/enforcing/disabled/g' $SELINUX_CONF_PATH"
  run_command "sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' $SELINUX_CONF_PATH"
  run_command "sed -i 's/SELINUX=permissive/SELINUX=disabled/g' $SELINUX_CONF_PATH"
}

function update_ipvs_conf() {
  log "配置ipvs功能"
  
  # 加载所需的内核模块
  run_command "modprobe ip_vs"
  run_command "modprobe ip_vs_rr"
  run_command "modprobe ip_vs_wrr"
  run_command "modprobe ip_vs_sh"
  run_command "modprobe nf_conntrack"
  # 根据内核版本判断是否加载 nf_conntrack_ipv4
  if [[ $MAJOR_KERNEL_VERSION -lt 4 ]] || { [[ $MAJOR_KERNEL_VERSION -eq 4 ]] && [[ $MINOR_KERNEL_VERSION -le 12 ]]; }; then
      # 仅在内核版本 <= 4.12 时加载模块
      color_echo ${fuchsia} "配置 nf_conntrack_ipv4  br_netfilter "
      echo "modprobe -- nf_conntrack_ipv4"
      echo "modprobe -- br_netfilter"
  else
      # 原因：linux > 4.12内核版本不兼容
      color_echo ${fuchsia} "跳过 modprobe nf_conntrack_ipv4 和 br_netfilter 配置"
  fi
  run_command "modprobe overlay"
}

function update_k8s_module_conf() {
  log "添加需要加载的模块写入脚本文件"
  
  # 写入模块配置到指定文件
  cat <<EOF | run_command "tee $KUBERNETES_MODULES_CONF"
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
overlay
EOF

  if [[ $MAJOR_KERNEL_VERSION -lt 4 ]] || { [[ $MAJOR_KERNEL_VERSION -eq 4 ]] && [[ $MINOR_KERNEL_VERSION -le 12 ]]; }; then
    color_echo ${fuchsia} "配置 nf_conntrack_ipv4 "
    echo "nf_conntrack_ipv4" >> "$KUBERNETES_MODULES_CONF"
    echo "br_netfilter" >> "$KUBERNETES_MODULES_CONF"
  else
    # 原因：linux>4.12内核版本不兼容
    color_echo ${fuchsia} "跳过 modprobe nf_conntrack_ipv4 配置"
  fi

  run_command "systemctl enable systemd-modules-load"
  run_command "systemctl restart systemd-modules-load"
  
  log "设置kubernetes-accounting"
  mkdir -p "$SYSTEM_CONFIG_PATH"
  
  # 写入kubernetes-accounting配置
  cat <<EOF | run_command "tee $KUBERNETES_ACCOUNTING_CONF"
[Manager]
DefaultCPUAccounting=yes
DefaultMemoryAccounting=yes
EOF

  run_command "systemctl daemon-reload"
  log "重启kubelet"
  run_command "systemctl restart kubelet"
}

function update_limits_conf() {
  log "设置资源配置文件"
  
  run_command "cp $SECURITY_LIMITS_CONF $SECURITY_LIMITS_CONF.bak"

  # 定义要写入的配置行
  local limits=(
    "* soft nofile 65536"
    "* hard nofile 65536"
    "* soft nproc 65536"
    "* hard nproc 65536"
    "* soft memlock unlimited"
    "* hard memlock unlimited"
  )

  # 遍历配置行,检查是否已存在,若不存在则写入
  for limit in "${limits[@]}"; do
    if ! grep -Fxq "$limit" "$SECURITY_LIMITS_CONF"; then
      echo "$limit" | run_command "tee -a $SECURITY_LIMITS_CONF"
      log "添加配置: $limit"
    else
      color_echo ${yellow} "配置已存在: $limit"
    fi
  done
}

function update_containerd_conf() {
  log "配置containerd"
  run_command "cp $CONTAINERD_CONF $CONTAINERD_CONF.bak"
  cat <<EOF | run_command "tee $CONTAINERD_CONF"
disabled_plugins = []
imports = []
oom_score = 0
plugin_dir = ""
required_plugins = []
root = "$CONTAINERD_DATA_PATH"
state = "$CONTAINERD_RUN_PATH"
version = 2

[cgroup]
  path = ""

[debug]
  address = ""
  format = ""
  gid = 0
  level = ""
  uid = 0

[grpc]
  address = "$CRI_SOCKET_SOCK_FILE"
  gid = 0
  max_recv_message_size = $CONTAINERD_MAX_RECV_MESSAGE_SIZE
  max_send_message_size = $CONTAINERD_MAX_SEND_MESSAGE_SIZE
  tcp_address = ""
  tcp_tls_cert = ""
  tcp_tls_key = ""
  uid = 0

[metrics]
  address = ""
  grpc_histogram = false

[plugins]

  [plugins."io.containerd.gc.v1.scheduler"]
    deletion_threshold = 0
    mutation_threshold = 100
    pause_threshold = 0.02
    schedule_delay = "0s"
    startup_delay = "100ms"

  [plugins."io.containerd.grpc.v1.cri"]
    disable_apparmor = false
    disable_cgroup = false
    disable_hugetlb_controller = true
    disable_proc_mount = false
    disable_tcp_service = true
    enable_selinux = false
    enable_tls_streaming = false
    ignore_image_defined_volumes = false
    max_concurrent_downloads = 3
    max_container_log_line_size = 16384
    netns_mounts_under_state_dir = false
    restrict_oom_score_adj = false
    sandbox_image = "$GLOBAL_IMAGE_REPOSITORY/pause:$KUBE_PAUSE_VERSION"
    selinux_category_range = 1024
    stats_collect_period = 10
    stream_idle_timeout = "$CONTAINERD_TIME_OUT"
    stream_server_address = "127.0.0.1"
    stream_server_port = "0"
    systemd_cgroup = false
    tolerate_missing_hugetlb_controller = true
    unset_seccomp_profile = ""

    [plugins."io.containerd.grpc.v1.cri".cni]
      bin_dir = "$CNI_INSTALL_PATH"
      conf_dir = "$CNI_NET_PATH"
      conf_template = ""
      max_conf_num = 1

    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"
      disable_snapshot_annotations = true
      discard_unpacked_layers = false
      no_pivot = false
      snapshotter = "overlayfs"

      [plugins."io.containerd.grpc.v1.cri".containerd.default_runtime]
        base_runtime_spec = ""
        container_annotations = []
        pod_annotations = []
        privileged_without_host_devices = false
        runtime_engine = ""
        runtime_root = ""
        runtime_type = ""

        [plugins."io.containerd.grpc.v1.cri".containerd.default_runtime.options]

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          base_runtime_spec = ""
          container_annotations = []
          pod_annotations = []
          privileged_without_host_devices = false
          runtime_engine = ""
          runtime_root = ""
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            BinaryName = ""
            CriuImagePath = ""
            CriuPath = ""
            CriuWorkPath = ""
            IoGid = 0
            IoUid = 0
            NoNewKeyring = false
            NoPivotRoot = false
            Root = ""
            ShimCgroup = ""
            SystemdCgroup = true

      [plugins."io.containerd.grpc.v1.cri".containerd.untrusted_workload_runtime]
        base_runtime_spec = ""
        container_annotations = []
        pod_annotations = []
        privileged_without_host_devices = false
        runtime_engine = ""
        runtime_root = ""
        runtime_type = ""

        [plugins."io.containerd.grpc.v1.cri".containerd.untrusted_workload_runtime.options]

    [plugins."io.containerd.grpc.v1.cri".image_decryption]
      key_model = "node"

    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = ""

      [plugins."io.containerd.grpc.v1.cri".registry.auths]

      [plugins."io.containerd.grpc.v1.cri".registry.configs]

      [plugins."io.containerd.grpc.v1.cri".registry.headers]

      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."k8s.gcr.io"]
          endpoint = ["https://$GLOBAL_IMAGE_REPOSITORY"]

    [plugins."io.containerd.grpc.v1.cri".x509_key_pair_streaming]
      tls_cert_file = ""
      tls_key_file = ""

  [plugins."io.containerd.internal.v1.opt"]
    path = "$CONTAINERD_OPT_PATH"

  [plugins."io.containerd.internal.v1.restart"]
    interval = "10s"

  [plugins."io.containerd.metadata.v1.bolt"]
    content_sharing_policy = "shared"

  [plugins."io.containerd.monitor.v1.cgroups"]
    no_prometheus = false

  [plugins."io.containerd.runtime.v1.linux"]
    no_shim = false
    runtime = "runc"
    runtime_root = ""
    shim = "containerd-shim"
    shim_debug = false

  [plugins."io.containerd.runtime.v2.task"]
    platforms = ["linux/amd64"]

  [plugins."io.containerd.service.v1.diff-service"]
    default = ["walking"]

  [plugins."io.containerd.snapshotter.v1.aufs"]
    root_path = ""

  [plugins."io.containerd.snapshotter.v1.btrfs"]
    root_path = ""

  [plugins."io.containerd.snapshotter.v1.devmapper"]
    async_remove = false
    base_image_size = ""
    pool_name = ""
    root_path = ""

  [plugins."io.containerd.snapshotter.v1.native"]
    root_path = ""

  [plugins."io.containerd.snapshotter.v1.overlayfs"]
    root_path = ""

  [plugins."io.containerd.snapshotter.v1.zfs"]
    root_path = ""

[proxy_plugins]

[stream_processors]

  [stream_processors."io.containerd.ocicrypt.decoder.v1.tar"]
    accepts = ["application/vnd.oci.image.layer.v1.tar+encrypted"]
    args = ["--decryption-keys-path", "$CONTAINERD_OCICRYPT_KEYS_CONF"]
    env = ["OCICRYPT_KEYPROVIDER_CONFIG=$CONTAINERD_OCICRYPT_KEYPROVIDER_CONF"]
    path = "ctd-decoder"
    returns = "application/vnd.oci.image.layer.v1.tar"

  [stream_processors."io.containerd.ocicrypt.decoder.v1.tar.gzip"]
    accepts = ["application/vnd.oci.image.layer.v1.tar+gzip+encrypted"]
    args = ["--decryption-keys-path", "$CONTAINERD_OCICRYPT_KEYS_CONF"]
    env = ["OCICRYPT_KEYPROVIDER_CONFIG=$CONTAINERD_OCICRYPT_KEYPROVIDER_CONF"]
    path = "ctd-decoder"
    returns = "application/vnd.oci.image.layer.v1.tar+gzip"

[timeouts]
  "io.containerd.timeout.shim.cleanup" = "5s"
  "io.containerd.timeout.shim.load" = "5s"
  "io.containerd.timeout.shim.shutdown" = "3s"
  "io.containerd.timeout.task.state" = "2s"

[ttrpc]
  address = ""
  gid = 0
  uid = 0
EOF

  cat <<EOF | run_command "tee $CRICTL_CONF"
runtime-endpoint: "$CRI_RUNTIME_ENDPOINT"
image-endpoint: ""
timeout: 0
debug: false
pull-image-on-create: false
disable-pull-on-run: false
EOF
  log "重启containerd"
  run_command "systemctl restart containerd"
}

function check() {
  log "检查配置是否生效,如果都正确,表示主机环境初始化均成功"
  
  # 检查防火墙状态
  run_command "systemctl status firewalld"
  
  # 检查 SELinux 状态
  run_command "getenforce"
  
  # 查看内存使用情况
  run_command "free -m"
  
  # 检查网桥过滤模块
  run_command "lsmod | grep br_netfilter"
  
  # 检查 ipvs 和 nf_conntrack 模块
  run_command "lsmod | grep -e ip_vs -e nf_conntrack"
  # journalctl -xe | grep systemd-modules-loa
}


function main_entrance() {
  case "${action}" in
  source_chrony)
    source_chrony
    ;;
  update_kubernetes_conf)
    update_kubernetes_conf
    ;;
  rest_firewalld)
    rest_firewalld
    ;;
  disable_swapoff)
    disable_swapoff
    ;;
  disabled_selinux)
    disabled_selinux
    ;;
  update_ipvs_conf)
    update_ipvs_conf
    ;;
  update_k8s_module_conf)
    update_k8s_module_conf
    ;;
  update_limits_conf)
    update_limits_conf
    ;;
  update_containerd_conf)
    GLOBAL_IMAGE_REPOSITORY=$2
    KUBE_PAUSE_VERSION=$3
    CONTAINERD_TIME_OUT=$4
    log "Update Containerd Conf
        Image Repository: $GLOBAL_IMAGE_REPOSITORY
        pause version: $KUBE_PAUSE_VERSION
        timeout: $CONTAINERD_TIME_OUT
        "
    update_containerd_conf
    ;;
  check)
    check
    ;;
  esac
}
main_entrance $@
