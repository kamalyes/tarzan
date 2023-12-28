#!/usr/bin/env bash
source ./common.sh

# cancel centos alias
[[ -f /etc/redhat-release ]] && unalias -a

function install_depend() {
    log "开始安装所需依赖"
    /bin/bash rpm-packages.sh update_yum_repos
    /bin/bash rpm-packages.sh update_kube_repos
    case $INSTALL_MODE in
    of | offline)
        run_command "/bin/bash rpm-packages.sh offline_install_all_packages"
        ;;
    online)
        run_command "/bin/bash rpm-packages.sh online_install_all_packages"
        ;;
    *)
        log "-mode 使用错误"
        exit
        ;;
    esac
    if [[ $ONLY_INSTALL_DEPEND == 'true' ]]; then
        log "所需依赖已全部执行安装，由于设置仅安装依赖、即跳出程序"
        exit
    fi
}

function prepare_work() {
    /bin/bash setupconfig.sh all
    /bin/bash docker.sh login_docker $DOCKER_USERNAME $DOCKER_PASSWORD $DOCKER_REGISTER_URL &&
    /bin/bash docker.sh pull_images
}

function run_k8s() {
    if [[ $IS_MASTER == 1 ]]; then
        log "修改Kubeadm-init配置"
        rm -rf kubeadm-init.yaml && cp conf/kubeadm-init-template.yaml kubeadm-init.yaml
        sed -i "s/{{KUBE_ADVERTISE_ADDRESS}}/${KUBE_ADVERTISE_ADDRESS}/g" kubeadm-init.yaml
        sed -i "s/{{KUBE_BIND_PORT}}/${KUBE_BIND_PORT}/g" kubeadm-init.yaml
        sed -i "s/{{KUBE_TOKEN}}/${KUBE_TOKEN}/g" kubeadm-init.yaml
        sed -i "s/{{KUBE_NODE_NAME}}/${KUBE_NODE_NAME}/g" kubeadm-init.yaml
        sed -i "s/{{KUBE_VERSION}}/${KUBE_VERSION}/g" kubeadm-init.yaml
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
        kube_admin_config_file="/etc/kubernetes/admin.conf"
        cp -i $kube_admin_config_file $HOME/.kube/config
        chown $(id -u):$(id -g) $HOME/.kube/config
        [[ -z $(grep $kube_admin_config_file ~/.bashrc) ]] && echo "export KUBECONFIG=$kube_admin_config_file" >>$HOME/.bashrc
        source ~/.bashrc
        log "开始组装slave安装包"
        NODE_PACKAGE_PATH="kube_slave"
        rm -rf $NODE_PACKAGE_PATH
        mkdir -p $NODE_PACKAGE_PATH
        cp -R offline/ docker.sh install-addons.sh install-kube.sh rpm-packages.sh setupconfig.sh $NODE_PACKAGE_PATH
        tar -czPf $NODE_PACKAGE_PATH.tar.gz $NODE_PACKAGE_PATH
        log "组装完成、请scp $NODE_PACKAGE_PATH.tar.gz 至slave节点"
    else
        echo "this node is slave, please manual run 'kubeadm join' command. if forget join command, please run $(color_echo $green "kubeadm token create --print-join-command") in master node"
    fi
    if [[ $NETWORK == "flannel" ]]; then
        run_command "/bin/bash install-addons.sh flannel"
    elif [[ $NETWORK == "calico" ]]; then
        run_command "/bin/bash install-addons.sh calico"
    fi
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

while [[ $# > 0 ]]; do
    case "$1" in
    -mode | --install_mode)
        INSTALL_MODE=$2
        
        echo "prepare install k8s install mode: $(color_echo $green $INSTALL_MODE)"
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
    -p | --port)
        KUBE_BIND_PORT=$2
        echo "prepare install k8s bind port: $(color_echo $green $KUBE_BIND_PORT)"
        shift
        ;;
    -tk | --token)
        KUBE_TOKEN=$2
        echo "prepare install k8s token: $(color_echo $green $KUBE_TOKEN)"
        shift
        ;;
    -hname | --hostname)
        KUBE_NODE_NAME=$2
        echo "set hostname: $(color_echo $green $HOST_NAME)"
        hostnamectl set-hostname $KUBE_NODE_NAME
        shift
        ;;
    --docker_username)
        DOCKER_USERNAME=$2
        echo "prepare docker_username is : $(color_echo $green $DOCKER_USERNAME)"
        shift
        ;;
    --docker_password)
        DOCKER_PASSWORD=$2
        echo "prepare docker_password is: $(color_echo $green $DOCKER_PASSWORD)"
        shift
        ;;
    --docker_register_url)
        DOCKER_REGISTER_URL=$2
        echo "prepare docker_register_url is: $(color_echo $green $DOCKER_REGISTER_URL)"
        shift
        ;;
    --flannel)
        echo "use flannel network, and set this node as master"
        NETWORK="flannel"
        IS_MASTER=1
        ;;
    --calico)
        echo "use calico network, and set this node as master"
        NETWORK="calico"
        IS_MASTER=1
        ;;
    --only_install_depend)
        ONLY_INSTALL_DEPEND=$2
        echo "prepare install type is only installed: $(color_echo $green $ONLY_INSTALL_DEPEND)"
        shift
        ;;
    -h | --help)
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "   -mode, --install_mode     		offline is recommended"
        echo "   -v, --version             		online only"
        echo "   -addr, --advertise_address		kubectl access address"
        echo "   -p, --port                		Port number for external access"
        echo "   -tk, --token                  	token, default=tarzan.e6fa0b76a6898af7"
        echo "   --docker_username              docker login username"
        echo "   --docker_password              docker login password"
        echo "   --docker_register_url          docker login registry"
        echo "   --only_install_depend          true,false"
        echo "   --flannel                    	use flannel network, and set this node as master"
        echo "   --calico                     	use calico network, and set this node as master"
        echo "   -h, --help:                  	find help"
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
    check_sys &&
    install_depend &&
    prepare_work &&
    run_k8s
}

main
