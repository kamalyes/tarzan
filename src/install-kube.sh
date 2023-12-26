#!/bin/bash
__current_dir=$(
        cd "$(dirname "$0")"
        pwd
)
function log() {
        message="[Tarzan Log]: $1 "
        echo -e "\033[32m## ${message} \033[0m\n" 2>&1 | tee -a ${__current_dir}/install.log
}

cat <<EOF >/etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=http://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=http://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg
        http://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF

mkdir /opt/cni/bin -p
tar zxvf offline/cni/cni-plugins-linux-amd64-v1.4.0.tgz -C /opt/cni/bin

log "打包kubeadm给到其它Node使用"
tar -czPf kubeadm.tar.gz /usr/bin/kubeadm
# 设置为开机自启并现在立刻启动服务 --now：立刻启动服务
systemctl enable --now kubelet 2>&1 | tee -a ${__current_dir}/install.log
# 查看状态
log "检查kubelet服务是否正常运行"
kubelet --version 1>/dev/null 2>/dev/null
if [ $? != 0 ]; then
        log "kubelet 未正常安装，请先安装并启动 kubelet 后再次执行本脚本"
        exit
        systemctl status kubelet
fi

kubeadm config images pull --image-repository registry.aliyuncs.com/google_containers

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

DOCKER_CGROUPS=$(docker info | grep 'Cgroup' | cut -d' ' -f3)
log $DOCKER_CGROUPS
cat >/etc/default/kubelet <<EOF
KUBELET_KUBEADM_EXTRA_ARGS=--cgroup-driver=$DOCKER_CGROUPS
EOF

mkdir -p /var/lib/kubelet/
chmod 777 -R /var/lib/kubelet

# 配置命令参数自动补全功能
log "开始配置命令参数自动补全功能"
echo 'source <(kubectl completion bash)' >>$HOME/.bashrc
echo 'source <(kubeadm completion bash)' >>$HOME/.bashrc
source $HOME/.bashrc
log "配置命令参数自动补全功能成功"