#!/usr/bin/env bash
source ./common.sh

action=$1

log "初始化k8s所需要环境配置"

function set_chrony_conf() {
  log "配置chrony同步源"
  cat <<EOF >/etc/chrony.conf
server ntp1.aliyun.com iburst
server ntp2.aliyun.com iburst
server ntp3.aliyun.com iburst
server ntp4.aliyun.com iburst
server ntp5.aliyun.com iburst
server ntp6.aliyun.com iburst
server ntp7.aliyun.com iburst
EOF
  systemctl restart chronyd.service
  chronyc sources -v
}

function set_docker_daemon() {
  log "配置Docker镜像源"
  cat <<EOF | tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://ui3fq00k.mirror.aliyuncs.com"
  ]
}
EOF
  systemctl daemon-reload
  systemctl restart docker > /dev/null 2>&1
}

function set_resolv() {
  log "添加DNS地址"
  cat >> /etc/resolv.conf <<-OK
#阿里云DNS
nameserver 223.5.5.5
nameserver 223.6.6.6
#百度DNS
nameserver 180.76.76.76
#腾讯DNS
nameserver 119.29.29.29 
#google DNS
nameserver 8.8.8.8
#114 DNS
nameserver 114.114.114.114
nameserver 114.114.115.115
OK
}

function close_firewalld() {
  log "关闭防火墙"
  systemctl stop firewalld
  systemctl disable firewalld
}

function drop_iptables() {
  log "关闭iptables"
  systemctl stop iptables
  systemctl disable iptables
  systemctl status firewalld
  systemctl status iptables
  log "清空iptables规则"
  iptables -F && iptables -X && iptables -F -t nat && iptables -X -t nat
  iptables -P FORWARD ACCEPT
}

function disable_swap() {
  log "关闭swap"
  #（临时的,只针对当前会话起作用,若会话关闭,重开还是会开启内存交换,所以使用下面一行命令即可）
  swapoff -a
  #（永久关闭）
  sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
  # 验证,swap必须为0;
  free -g
}

function disable_selinux() {
  log "关闭selinux"
  # 临时关闭
  setenforce 0
  # 永久禁用
  sed -i '/SELINUX/s/enforcing/disabled/g' /etc/selinux/config
  # -- 把当前会话的默认安全策略也禁掉（或者重启虚拟机应该也可,我是这样理解的）
  sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
  sed -i "s/SELINUX=permissive/SELINUX=disabled/g" /etc/selinux/config
}


function upgrade_kernel() {
    echo "更新 kernel"
    rpm -ivhU offline/kernel/*.rpm --nodeps --force
    # set default kernel
	  grub2-set-default "$(cat /boot/grub2/grub.cfg  | grep '^menuentry' | sed -n '1,1p' | awk -F "'" '{print $2}')"
}

function load_kernel_module() {
  log "配置kernel_module"
  k8s_modules=(
      "#!/usr/bin/env bash"
      "modprobe -- overlay"
      "modprobe -- ip_vs"
      "modprobe -- ip_vs_rr"
      "modprobe -- ip_vs_wrr"
      "modprobe -- ip_vs_lc"
      "modprobe -- ip_vs_wlc"
      "modprobe -- ip_vs_lblc"
      "modprobe -- ip_vs_lblcr"
      "modprobe -- ip_vs_sh"
      "modprobe -- ip_vs_dh"
      "modprobe -- ip_vs_fo"
      "modprobe -- ip_vs_nq"
      "modprobe -- ip_vs_sed"
      "modprobe -- ip_vs_ftp"
      "modprobe -- br_netfilter"
      "modprobe -- bridge"
      "modprobe -- nf_conntrack"
      "modprobe -- nf_conntrack_ipv4"
      "modprobe -- nf_conntrack_ipv6"
      "modprobe -- ip_tables"
      "modprobe -- ip_set"
      "modprobe -- xt_set"
      "modprobe -- ipt_set"
      "modprobe -- ipt_rpfilter"
      "modprobe -- ipt_REJECT"
      "modprobe -- ipip"
  )
  printf '%s\n' "${k8s_modules[@]}" > /etc/sysconfig/modules/k8s.modules
  chmod u+x /etc/sysconfig/modules/k8s.modules
  systemctl enable systemd-modules-load
  systemctl restart systemd-modules-load
}

function update_security_limits() {
  log "设置linux的最大文件打开数"
  cp /etc/security/limits.conf /etc/security/limits.conf.bak
  echo "* soft nofile 65536" >>/etc/security/limits.conf
  echo "* hard nofile 65536" >>/etc/security/limits.conf
  echo "* soft nproc 65536" >>/etc/security/limits.conf
  echo "* hard nproc 65536" >>/etc/security/limits.conf
  echo "* soft  memlock  unlimited" >>/etc/security/limits.conf
  echo "* hard memlock  unlimited" >>/etc/security/limits.conf
}

function update_containerd_conf(){
  log "配置containerd"
  cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
  cat <<EOF >/etc/containerd/config.toml
disabled_plugins = []
imports = []
oom_score = 0
plugin_dir = ""
required_plugins = []
root = "/approot1/data/containerd"
state = "/run/containerd"
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
  address = "/run/containerd/containerd.sock"
  gid = 0
  max_recv_message_size = 16777216
  max_send_message_size = 16777216
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
    sandbox_image = "kamalyes/kube-pause:3.9"
    selinux_category_range = 1024
    stats_collect_period = 10
    stream_idle_timeout = "4h0m0s"
    stream_server_address = "127.0.0.1"
    stream_server_port = "0"
    systemd_cgroup = false
    tolerate_missing_hugetlb_controller = true
    unset_seccomp_profile = ""

    [plugins."io.containerd.grpc.v1.cri".cni]
      bin_dir = "/opt/cni/bin"
      conf_dir = "/etc/cni/net.d"
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

    [plugins."io.containerd.grpc.v1.cri".x509_key_pair_streaming]
      tls_cert_file = ""
      tls_key_file = ""

  [plugins."io.containerd.internal.v1.opt"]
    path = "/opt/containerd"

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
    args = ["--decryption-keys-path", "/etc/containerd/ocicrypt/keys"]
    env = ["OCICRYPT_KEYPROVIDER_CONFIG=/etc/containerd/ocicrypt/ocicrypt_keyprovider.conf"]
    path = "ctd-decoder"
    returns = "application/vnd.oci.image.layer.v1.tar"

  [stream_processors."io.containerd.ocicrypt.decoder.v1.tar.gzip"]
    accepts = ["application/vnd.oci.image.layer.v1.tar+gzip+encrypted"]
    args = ["--decryption-keys-path", "/etc/containerd/ocicrypt/keys"]
    env = ["OCICRYPT_KEYPROVIDER_CONFIG=/etc/containerd/ocicrypt/ocicrypt_keyprovider.conf"]
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
crictl config runtime-endpoint unix:///run/containerd/containerd.sock
crictl config image-endpoint unix:///run/containerd/containerd.sock
log "重启containerd"
systemctl restart containerd > /dev/null 2>&1
}

function set_kube_config() {
  mkdir -p /etc/sysctl.d
  chmod 751 -R /etc/sysctl.d
  cat <<EOF >/etc/sysctl.d/kubernetes.conf
# 开启数据包转发功能（实现vxlan）
net.ipv4.ip_forward=1
# iptables对bridge的数据进行处理
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.bridge.bridge-nf-call-arptables=1
# 关闭tcp_tw_recycle,否则和NAT冲突,会导致服务不通
net.ipv4.tcp_tw_recycle=0
# 不允许将TIME-WAIT sockets重新用于新的TCP连接
net.ipv4.tcp_tw_reuse=0
# socket监听(listen)的backlog上限
net.core.somaxconn=32768
# 最大跟踪连接数,默认 nf_conntrack_buckets * 4
net.netfilter.nf_conntrack_max=1000000
# 禁止使用 swap 空间,只有当系统 OOM 时才允许使用它
vm.swappiness=0
# 计算当前的内存映射文件数。
vm.max_map_count=655360
# 内核可分配的最大文件数
fs.file-max=6553600
# 持久连接
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=10
EOF
sysctl -p /etc/sysctl.d/kubernetes.conf
}

function show() {
  log "检查配置是否生效,如果都正确,表示主机环境初始化均成功"
  systemctl status firewalld                 # 查看防火墙
  getenforce                                 # 查看selinux
  free -m                                    # 查看selinux
  lsmod | grep br_netfilter                  # 查看网桥过滤模块
  lsmod | grep -e ip_vs -e nf_conntrack_ipv4 # 查看 ipvs 模块
}

function all() {
  set_chrony_conf && \
  set_docker_daemon && \
  set_resolv && \
  close_firewalld && \
  drop_iptables && \
  disable_swap && \ 
  disable_selinux && \
  upgrade_kernel && \
  load_kernel_module && \
  update_security_limits && \
  set_kube_config && \
  update_containerd_conf && \
  show
}

function main_entrance() {
  case "${action}" in
    set_chrony_conf)
      set_chrony_conf
    ;;
    set_docker_daemon)
      set_docker_daemon
    ;;
    set_resolv)
      set_resolv
    ;;
    close_firewalld)
      close_firewalld
    ;;
    drop_iptables)
      drop_iptables
    ;;
    disable_swap)
      disable_swap
    ;;
    disable_selinux)
      disable_selinux
    ;;
    upgrade_kernel)
      upgrade_kernel
    ;;
    load_kernel_module)
      load_kernel_module
    ;;
    update_security_limits)
      update_security_limits
    ;;
    update_containerd_conf)
      update_containerd_conf
    ;;
    set_kube_config)
      set_kube_config
    ;;
    all)
      all
    ;;
  esac
}
main_entrance $@
