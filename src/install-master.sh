#!/bin/bash
# 安装master
# cd 到目录中运行 ./install-master.sh 就可以
# 多网卡请输入网卡IP  例如 ./install-master.sh 192.168.1.1
__current_dir=$(
    cd "$(dirname "$0")"
    pwd
)

KUBE_VERSION="1.25.3"
KUBE_ADVERTISE_ADDRESS=$(cat /etc/hosts | grep localhost | awk '{print $1}' | awk 'NR==1{print}')
KUBE_BIND_PORT="6443"
KUBE_TOKEN="tarzan.e6fa0b76a6898af7"

function log() {
    message="[Tarzan Log]: $1 "
    echo -e "\033[32m## ${message} \033[0m\n" 2>&1 | tee -a ${__current_dir}/install.log
}

log "安装所需依赖"
/bin/bash rpm-packages.sh offline_install_all_packages

log "初始化k8s所需要环境."
/bin/bash setupconfig.sh

log "下载kubeadm所需要的镜像."
log "针对国内网络,没科学上网只能老实做镜像引用,各位放心使用,build引自官方镜像 "
log "查Dockerfile网址 https://hub.docker.com/u/thejosan20/  https://github.com/thejosan?tab=repositories "
/bin/bash pull-docker.sh

log "修改Kubeadm-init配置"
if [ "$1" ]; then
    KUBE_ADVERTISE_ADDRESS=$1
fi

if [ "$2" ]; then
    KUBE_BIND_PORT=$2
fi

if [ "$3" ]; then
    KUBE_TOKEN=$3
fi

rm -rf kubeadm-init.yaml && cp kubeadm-init-template.yaml kubeadm-init.yaml
sed -i "s/{{KUBE_ADVERTISE_ADDRESS}}/${KUBE_ADVERTISE_ADDRESS}/g" kubeadm-init.yaml
sed -i "s/{{KUBE_BIND_PORT}}/${KUBE_BIND_PORT}/g" kubeadm-init.yaml
sed -i "s/{{KUBE_TOKEN}}/${KUBE_TOKEN}/g" kubeadm-init.yaml
sed -i "s/{{KUBE_VERSION}}/${KUBE_VERSION}/g" kubeadm-init.yaml
log "初始化Kube Master"
kubeadm init --config kubeadm-init.yaml --v=5 2>&1 | tee -a ${__current_dir}/install.log
journalctl -f -u kubelet 2>&1 | tee -a ${__current_dir}/install.log # 查看运行日志
log "Please wait a few minutes!"

JoinCommand=$(grep "kubeadm join") 2>&1 | tee -a ${__current_dir}/install.log
if [ $? -eq 0 ]; then
    log "k8s-master安装成功,节点加入集群命令如下:"
    echo "$JoinCommand"
    cp node-template.sh install-node.sh
    chmod +x install-node.sh
    echo "$JoinCommand" >>install-node.sh
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    echo 'export KUBECONFIG=/etc/kubernetes/admin.conf' >> $HOME/.bashrc
    source ~/.bashrc

    log "开始安装k8s插件"
    /bin/bash install-addons.sh

    log "生成node节点安装包"
    mkdir -p /tmp/k8s-node-install
    cp setupconfig.sh pull-docker.sh install-kube.sh install-node.sh kubeadm /tmp/k8s-node-install
    cd /tmp
    tar -czf k8s-node-install.tar.gz k8s-node-install
    mv k8s-node-install.tar.gz /root/
    rm -rf /tmp/k8s-node-install
    log "安装包路径在 /root/k8s-node-install.tar.gz scp到你node节点解压后运行./install-node.sh 即可."
else
    log "kubeadm init failed! 初始化失败!"
fi
