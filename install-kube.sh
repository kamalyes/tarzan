#!/usr/bin/env bash
source ./common.sh

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
    run_command "/bin/bash yum-packages.sh offline_install_kube $KUBE_VERSION"
}

function prepare_work() {
	log "初始化k8s所需要环境"
    KUBE_PAUSE_VERSION=$KUBE_PAUSE_VERSION
    if [[ $KUBE_VERSION == "1.28.2" ]]; then
        KUBE_PAUSE_VERSION=3.9
    fi
	run_command "/bin/bash setupconfig.sh source_chrony"
    run_command "/bin/bash setupconfig.sh update_kubernetes_conf"
	run_command "/bin/bash setupconfig.sh rest_firewalld"
	run_command "/bin/bash setupconfig.sh disable_swapoff"
	run_command "/bin/bash setupconfig.sh disabled_selinux"
	run_command "/bin/bash setupconfig.sh update_ipvs_conf"
	run_command "/bin/bash setupconfig.sh update_k8s_module_conf"
	run_command "/bin/bash setupconfig.sh update_limits_conf"
	run_command "/bin/bash setupconfig.sh update_containerd_conf $GLOBAL_IMAGE_REPOSITORY $KUBE_PAUSE_VERSION $CONTAINERD_TIME_OUT"
	run_command "/bin/bash setupconfig.sh check"
}

function upload_hosts {
    local update_host_prompt="Updating hosts file"
    echo "$KUBE_ADVERTISE_ADDRESS k8s-master" >>/etc/hosts

    # 检查 conf/hosts 文件是否存在
    if [ -f "conf/hosts" ]; then
        echo "Processing conf/hosts file"

        # 逐行处理 conf/hosts 文件
        while IFS= read -r line; do
            # 检查是否该行内容在 /etc/hosts 中存在
            if ! grep -q "$line" /etc/hosts; then
                # 不存在则追加到 /etc/hosts 后面
                echo "$line" >> /etc/hosts
            fi
        done < "conf/hosts"

        service network restart
        log "${update_host_prompt} OK"
    else
        echo "conf/hosts file not found. Skipping."
    fi
}


function load_images {
    crictl images | grep $GLOBAL_IMAGE_REPOSITORY
    if [[ $IMAGE_LOAD_TYPE == "offline" ]]; then
        run_command "/bin/bash crictl.sh offline_load_images $KUBE_VERSION $KUBE_NETWORK $GLOBAL_IMAGE_REPOSITORY"
    else
        # kubeadm config images pull --image-repository $GLOBAL_IMAGE_REPOSITORY
        run_command "/bin/bash crictl.sh online_pull_images $KUBE_VERSION $GLOBAL_IMAGE_REPOSITORY"
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

function poll_k8s_ready() {
    # 轮询间隔时间（秒）
    local INTERVAL=3
    # 检查 Kubernetes 集群是否安装成功的命令示例
    local CHECK_COMMAND="kubectl get nodes"
    # 最大尝试次数
    local MAX_ATTEMPTS=10

    # 调用 retry 函数
    if retry "$CHECK_COMMAND" "$MAX_ATTEMPTS" "$INTERVAL"; then
        log "Kubernetes 集群安装成功！停止轮询。"
    else
        log "超过 $MAX_ATTEMPTS 次尝试, Kubernetes 集群未就绪，退出程序。"
        exit 1
    fi
}


function init_master() {
    log "初始化kubeadm-init配置"
    rm -rf kubeadm-init.yaml && cp conf/kubeadm-init-template.yaml kubeadm-init.yaml
    sed -i "s|{{GLOBAL_IMAGE_REPOSITORY}}|$GLOBAL_IMAGE_REPOSITORY|g" kubeadm-init.yaml
    sed -i "s/{{KUBE_ADVERTISE_ADDRESS}}/$KUBE_ADVERTISE_ADDRESS/g" kubeadm-init.yaml
    sed -i "s/{{KUBE_BIND_PORT}}/$KUBE_BIND_PORT/g" kubeadm-init.yaml
    sed -i "s/{{KUBE_TOKEN}}/$KUBE_TOKEN/g" kubeadm-init.yaml
    sed -i "s/{{KUBE_NODE_NAME}}/$KUBE_NODE_NAME/g" kubeadm-init.yaml
    sed -i "s/{{KUBE_VERSION}}/$KUBE_VERSION/g" kubeadm-init.yaml
    sed -i "s|{{KUBE_POD_SUBNET}}|$KUBE_POD_SUBNET|g" kubeadm-init.yaml
    sed -i "s|{{KUBE_SERVICE_SUBNET}}|$KUBE_SERVICE_SUBNET|g" kubeadm-init.yaml
    cat kubeadm-init.yaml
    log "全局修改addons-image-repository"
    find addons -name "*.yaml" -exec sed -i.bak 's|{{KUBE_POD_SUBNET}}|'"$KUBE_POD_SUBNET"'|g' {} \;    
    find addons -name "*.yaml" -exec sed -i.bak 's|{{ADDONS_IMAGE_REPOSITORY}}|'"$ADDONS_IMAGE_REPOSITORY"'|g' {} \;
    find addons -name "*.yaml" -exec sed -i.bak 's|{{GLOBAL_IMAGE_REPOSITORY}}|'"$GLOBAL_IMAGE_REPOSITORY"'|g' {} \;
    log "初始化Kube Master"
    kubeadm init --config kubeadm-init.yaml --kubelet-extra-args 'timezone=Asia/Shanghai' --v=5 2>&1 | tee -a ${__current_dir}/install.log && \
    bak_kube_config && \
    install_network_plugin && \
    poll_k8s_ready && \
    sub_slave_rely
}

function bak_kube_config(){
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
}

function install_network_plugin(){
    if [[ $KUBE_NETWORK == "flannel" ]]; then
        log "开始安装$KUBE_NETWORK version: $FLANNEL_VERSION"
        run_command "/bin/bash install-addons.sh flannel $FLANNEL_VERSION"
    elif [[ $KUBE_NETWORK == "calico" ]]; then
        log "开始安装$KUBE_NETWORK version: $CALICO_VERSION"
        run_command "/bin/bash install-addons.sh calico $CALICO_VERSION"
    fi
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
    log "创建Kube Node连接所需要的Token"
    kubeadm token create --print-join-command --ttl=0 2>&1 | tee -a ${__current_dir}/install.log
    log "开始组装slave安装包"
    rm -rf $NODE_PACKAGE_PATH
    mkdir -p $NODE_PACKAGE_PATH/offline
    cp -R conf/ $NODE_PACKAGE_PATH/conf
    # 复制指定的目录到 $NODE_PACKAGE_PATH/offline
    cp -R offline/{base-dependence,bash-completion,cni,conntrack,containerd,k8s/$KUBE_VERSION} "$NODE_PACKAGE_PATH/offline"
    # 复制所有的 .sh 文件到 $NODE_PACKAGE_PATH
    cp *.sh "$NODE_PACKAGE_PATH"
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
        --addons-repository)
        ADDONS_IMAGE_REPOSITORY=$2
        echo "use addons-image-repository is: $(color_echo $green $ADDONS_IMAGE_REPOSITORY)"
        ;;
        --image-load-type)
        IMAGE_LOAD_TYPE=$2
        echo "use image-load-type is: $(color_echo $green $IMAGE_LOAD_TYPE)"
        ;;
        --containerd-timeout)
        CONTAINERD_TIME_OUT=$2
        echo "containerd-timeout is: $(color_echo $green $CONTAINERD_TIME_OUT)"
        ;;
        --pod-subnet)
        KUBE_POD_SUBNET=$2
        echo "pod-subnet is: $(color_echo $green $KUBE_POD_SUBNET)"
        ;;
        --serviceSubnet)
        KUBE_SERVICE_SUBNET=$2
        echo "serviceSubnet is: $(color_echo $green $KUBE_SERVICE_SUBNET)"
        ;;
        -h|--help)
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "   -v, --version             		Versions 1.23.3, 1.28.2 are currently supported,default=$KUBE_VERSION"
        echo "   -p, --port                		Port number for external access, default=$KUBE_BIND_PORT"
        echo "   -addr, --advertise_address		kubectl access address, default=$KUBE_ADVERTISE_ADDRESS"
        echo "   -tk, --token                  	token, default=$KUBE_TOKEN"
        echo "   --hostname [hostname]          set hostname, default=$KUBE_NODE_NAME"
        echo "   --flannel                    	use flannel network, and set this node as master"
        echo "   --calico                     	use calico network, and set this node as master"
        echo "   --slavepath                    slave packaged path, default=$NODE_PACKAGE_PATH"
        echo "   --image-repository             default=$GLOBAL_IMAGE_REPOSITORY"
        echo "   --addons-image-repository      default=$ADDONS_IMAGE_REPOSITORY"
        echo "   --image-load-type              default=$IMAGE_LOAD_TYPE"
        echo "   --containerd-timeout           default=$CONTAINERD_TIME_OUT"
        echo "   --pod-subnet                   default=$KUBE_POD_SUBNET"
        echo "   --serviceSubnet                default=$KUBE_SERVICE_SUBNET"
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
    check_sys
    install_depend
    prepare_work
    upload_hosts
    load_images
    if [[ $IS_MASTER == 1 ]]; then
        init_master
    fi
}

main