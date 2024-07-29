#!/usr/bin/env bash
source ./common.sh

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

FLANNEL_VERSION="0.24.0"
CALICO_VERSION="3.26.1"
DASHBOARD_VERSION="2.7.0"
INGRESS_NGINX_VERSION="1.9.5"
METRICS_VERSION="0.6.4"
STATE_METRICS_STANDARD_VERSION="2.10.0"

# cancel centos alias
[[ -f /etc/redhat-release ]] && unalias -a

function set_hostname(){
    local hostname=$1
    if [[ $hostname =~ '_' ]];then
        color_echo $yellow "hostname can't contain '_' character, auto change to '-'.."
        hostname=`echo $hostname|sed 's/_/-/g'`
    fi
    run_command "hostnamectl --static set-hostname $hostname"
}

function install_depend(){
    log "安装所需依赖"
    run_command "/bin/bash yum-packages.sh offline_install_public_dependency"
    if [[ $IS_MASTER == 1 ]]; then
        run_command "/bin/bash yum-packages.sh offline_install_docker"
        run_command "/bin/bash yum-packages.sh offline_install_dockercompose"
    fi
    if [[ $IMAGE_LOAD_TYPE == "offline" ]]; then
        run_command "/bin/bash crictl.sh offline_load_images"
    else
        # kubeadm config images pull --image-repository $GLOBAL_IMAGE_REPOSITORY
        run_command "/bin/bash crictl.sh online_pull_images"
    fi
    crictl images | grep $GLOBAL_IMAGE_REPOSITORY
    run_command "/bin/bash yum-packages.sh offline_install_kube"
}

function prepare_work() {
	log "初始化k8s所需要环境"
	run_command "/bin/bash setupconfig.sh"
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

mkdir -p /var/lib/kubelet
chmod 777 -R /var/lib/kubelet

mkdir -p /etc/kubernetes
chmod 777 -R /etc/kubernetes
}

check_sys() {
    log "当前操作用户权限检查是否为Root"
    [ $(id -u) != "0" ] && {
        color_echo ${red} "Error: You must be root to run this script"
        exit 1
    }
    chmod $PERMISSION -R ./

    physical_id=$(grep "physical id" /proc/cpuinfo | uniq | wc -l)
    cpuinfo=$(grep ^processor /proc/cpuinfo | wc -l)
    log "当前机器有$physical_id个cpu,$cpuinfo核心数"
    [[ $cpuinfo == 1 && $IS_MASTER == 1 ]] && {
        color_echo ${red} "master node cpu number should be >= 2!"
        exit 1
    }

    cat /etc/redhat-release | grep -i centos | grep '7.[[:digit:]]' & >/dev/null
    if [[ $? != 0 ]]; then
        log "不支持的操作系统,该脚本只适用于CentOS 7.x  x86_64 操作系统"
        exit 1
    fi
    
    df_t=$(df -h | grep /$ | awk '{print $2}')
    df_s=$(df -h | grep /$ | awk '{print $4}')
    log "当前机器磁盘总容量为: $df_t,剩余容量为: $df_s"

    mem_t=$(free -h | grep ^Mem | awk '{print $2}')
    mem_s=$(free -h | grep ^Mem | awk '{print $4}')
    log "当前机器内存总值为: $mem_t,空闲内存为: $mem_s"
}


function init_master() {
    log "修改Kubeadm-init配置"
    rm -rf kubeadm-init.yaml && cp conf/kubeadm-init-template.yaml kubeadm-init.yaml
    sed -i "s|{{GLOBAL_IMAGE_REPOSITORY}}|$GLOBAL_IMAGE_REPOSITORY|g" kubeadm-init.yaml
    sed -i "s/{{KUBE_ADVERTISE_ADDRESS}}/${KUBE_ADVERTISE_ADDRESS}/g" kubeadm-init.yaml
    sed -i "s/{{KUBE_BIND_PORT}}/${KUBE_BIND_PORT}/g" kubeadm-init.yaml
    sed -i "s/{{KUBE_TOKEN}}/${KUBE_TOKEN}/g" kubeadm-init.yaml
    sed -i "s/{{KUBE_NODE_NAME}}/${KUBE_NODE_NAME}/g" kubeadm-init.yaml
    sed -i "s/{{KUBE_VERSION}}/${KUBE_VERSION}/g" kubeadm-init.yaml
    cat kubeadm-init.yaml
    log "全局修改image-repository"
    sed -i "s/{{GLOBAL_IMAGE_REPOSITORY}}/${GLOBAL_IMAGE_REPOSITORY}/g" addons/*.yaml
    update_host_prompt="更新Host,并重启网络"
    read -p "确认是否${update_host_prompt}? [n/y]" __choice </dev/tty
    case "$__choice" in
    y | Y)
        echo "$KUBE_ADVERTISE_ADDRESS k8s-master" >>/etc/hosts
        for line in $(cat conf/hosts); do
            sed -i "/$line/d" /etc/hosts
        done
        cat conf/hosts >>/etc/hosts
        service network restart
        log "${update_host_prompt} OK"
        ;;
    n | N)
        echo "退出${update_host_prompt}" &
        ;;
    *)
        echo "退出${update_host_prompt}" &
        ;;
    esac
    log "初始化Kube Master"
    kubeadm init --config kubeadm-init.yaml --v=5 2>&1 | tee -a ${__current_dir}/install.log
    log "备份原有kube admin配置"
    kube_admin_path=" $HOME/.kube/config"
    if [ -f $kube_admin_path ]; then
        mv $HOME/.kube/config $HOME/.kube/config.bak
    else
        mkdir -p $HOME/.kube
    fi
    cp -i $KUBE_ADMIN_CONFIG_FILE $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    [[ -z $(grep $KUBE_ADMIN_CONFIG_FILE ~/.bashrc) ]] && echo "export KUBECONFIG=$KUBE_ADMIN_CONFIG_FILE" >>$HOME/.bashrc
    source ~/.bashrc
    log "开始安装$KUBE_NETWORK"
    if [[ $KUBE_NETWORK == "flannel" ]]; then
        run_command "/bin/bash install-addons.sh flannel"
    elif [[ $KUBE_NETWORK == "calico" ]]; then
        run_command "/bin/bash install-addons.sh calico"
    fi
    log "创建Kube Node连接所需要的Token"
    kubeadm token create --print-join-command --ttl=0 2>&1 | tee -a ${__current_dir}/install.log
    sub_slave_rely
}

function slave_join(){
    log "配置slave节点kubernetes admin.config"
    kube_admin_path=" $HOME/.kube/config"
    if [ -f $kube_admin_path ]; then
        mv $HOME/.kube/config $HOME/.kube/config.bak
    else
        mkdir -p $HOME/.kube
    fi
    cp -i ./kubernetes-admin.config $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    [[ -z $(grep $KUBE_ADMIN_CONFIG_FILE ~/.bashrc) ]] && echo "export KUBECONFIG=$KUBE_ADMIN_CONFIG_FILE" >>$HOME/.bashrc
}

function sub_slave_rely(){
    log "开始组装slave安装包"
    rm -rf $NODE_PACKAGE_PATH
    mkdir -p $NODE_PACKAGE_PATH
    cp -R offline/{base-dependence,bash-completion,cni,conntrack,containerd,images,k8s/$KUBE_VERSION} *.sh $NODE_PACKAGE_PATH
    cp -i $KUBE_ADMIN_CONFIG_FILE $NODE_PACKAGE_PATH/kubernetes-admin.config
    tar -czPf $NODE_PACKAGE_PATH.tar.gz $NODE_PACKAGE_PATH
    log "组装完成、请scp $NODE_PACKAGE_PATH.tar.gz 至slave节点"
}

while [[ $# > 0 ]];do
    case "$1" in
        -p|--port)
        KUBE_BIND_PORT=$2
        echo "prepare install k8s bind port: $(color_echo $green $KUBE_BIND_PORT)"
        shift
        ;;
        -v | --version)
        KUBE_VERSION=$(echo "$2" | sed 's/v//g')
        echo "prepare install k8s version: $(color_echo $green $KUBE_VERSION)"
        shift
        ;;
        -addr | --advertise_address)
        KUBE_ADVERTISE_ADDRESS=$2
        echo "prepare install k8s advertise_address: $(color_echo $green $KUBE_ADVERTISE_ADDRESS)"
        shift
        ;;
        -tk|--token)
        KUBE_TOKEN=$2
        echo "prepare install k8s token: $(color_echo $green $KUBE_TOKEN)"
        shift
        ;;
        -hname | --hostname)
        KUBE_NODE_NAME=$2
        echo "set hostname: $(color_echo $green $KUBE_NODE_NAME)"
        hostnamectl set-hostname $KUBE_NODE_NAME
        shift
        ;;
        --flannel)
        echo "use $(color_echo $green flannel ) network, and set this node as master"
        KUBE_NETWORK="flannel"
        IS_MASTER=1
        ;;
        --calico)
        echo "use $(color_echo $green calico )  network, and set this node as master"
        KUBE_NETWORK="calico"
        IS_MASTER=1
        ;;
        --slavepath)
        NODE_PACKAGE_PATH=$2
        echo "slave packaged path: $(color_echo $green $NODE_PACKAGE_PATH)"
        ;;
        --image-repository)
        GLOBAL_IMAGE_REPOSITORY=$2
        echo "use image-repository is: $(color_echo $green $GLOBAL_IMAGE_REPOSITORY)"
        ;;
        --image-load-type)
        IMAGE_LOAD_TYPE=$2
        echo "use image-load-type is: $(color_echo $green $IMAGE_LOAD_TYPE)"
        ;;
        -h|--help)
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "   -v, --version             		Versions 1.23.3, 1.28.2 are currently supported,default=$KUBE_VERSION"
        echo "   -p, --port                		Port number for external access, default=$KUBE_BIND_PORT"
        echo "   -addr, --advertise_address		kubectl access address"
        echo "   -tk, --token                  	token, default=$KUBE_TOKEN"
        echo "   --hostname [hostname]          set hostname"
        echo "   --flannel                    	use flannel network, and set this node as master"
        echo "   --calico                     	use calico network, and set this node as master"
        echo "   --slavepath                    slave packaged path, default=$NODE_PACKAGE_PATH"
        echo "   --image-repository             default=$GLOBAL_IMAGE_REPOSITORY"
        echo "   --image-load-type              default=$IMAGE_LOAD_TYPE"
        echo "   -h, --help:                  	find help"
        echo "   Master: sh install-kube.sh -v v1.23.3 -addr ${Change You Intranet Ip} --flannel"
        echo "   Slave:  sh install-kube.sh "
        echo ""
        exit 0
        shift # past argument
        ;; 
        *)
            # unknown option
        ;;
    esac
    shift # past argument or value
done

main() {
    check_sys && \
    install_depend  && \
    prepare_work  && \
    if [[ $IS_MASTER == 1 ]]; then
        init_master
    fi
}

main