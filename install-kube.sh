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
    echo "set hostname: $(color_echo $green $hostname)"
    run_command "hostnamectl set-hostname $hostname"
}

function install_depend(){
    run_command "/bin/bash yum-packages.sh online_download_dependency $KUBE_VERSION"
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
    # 设置hostname
    set_hostname $KUBE_NODE_NAME
    # 安装依赖
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
        log "Processing conf/hosts file"

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
        color_echo ${fuchsia} "conf/hosts file not found. Skipping."
    fi
}

function load_images {
    # 列出所有需要下载的镜像
    log "Listing images for Kubernetes version $KUBE_VERSION..."
    kubeadm config images list --image-repository "$GLOBAL_IMAGE_REPOSITORY"

    # 定义不需要在线拉取的策略
    local -a offline_policies=("IfNotPresent" "Never")
    local load_command="online_pull_kube_base_images"  # 默认使用在线拉取

    # 检查 KUBE_IMAGE_PULL_POLICY 是否在不需要在线拉取的策略中
    for policy in "${offline_policies[@]}"; do
        if [[ "$policy" == "$KUBE_IMAGE_PULL_POLICY" ]]; then
            load_command="offline_load_kube_base_images"
            break
        fi
    done

    # 执行加载镜像的命令, 列出所有镜像并过滤出指定的镜像仓库
    run_command "/bin/bash crictl.sh $load_command $KUBE_VERSION $GLOBAL_IMAGE_REPOSITORY" && \
    run_command "crictl images | grep $GLOBAL_IMAGE_REPOSITORY"
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
        color_echo ${red} "不支持的操作系统,该脚本只适用于CentOS 7.x  x86_64 操作系统"
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
        color_echo ${red} "超过 $MAX_ATTEMPTS 次尝试, Kubernetes 集群未就绪，退出程序。"
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
    sed -i "s|{{KUBE_IMAGE_PULL_POLICY}}|$KUBE_IMAGE_PULL_POLICY|g" kubeadm-init.yaml
    sed -i "s|{{KUBERNETES_PKI_PATH}}|$KUBERNETES_PKI_PATH|g" kubeadm-init.yaml
    sed -i "s|{{KUBERNETES_ETCD}}|$KUBERNETES_ETCD|g" kubeadm-init.yaml
    sed -i "s|{{CRI_SOCKET_SOCK_FILE}}|$CRI_SOCKET_SOCK_FILE|g" kubeadm-init.yaml
    
    cat kubeadm-init.yaml
    log "全局修改addons-image-repository"
    find addons -name "*.yaml" -exec sed -i.bak 's|{{KUBE_POD_SUBNET}}|'"$KUBE_POD_SUBNET"'|g' {} \;    
    find addons -name "*.yaml" -exec sed -i.bak 's|{{ADDONS_IMAGE_REPOSITORY}}|'"$ADDONS_IMAGE_REPOSITORY"'|g' {} \;
    find addons -name "*.yaml" -exec sed -i.bak 's|{{GLOBAL_IMAGE_REPOSITORY}}|'"$GLOBAL_IMAGE_REPOSITORY"'|g' {} \;
    find addons -name "*.yaml" -exec sed -i.bak 's|{{CNI_INSTALL_PATH}}|'"$CNI_INSTALL_PATH"'|g' {} \;
    find addons -name "*.yaml" -exec sed -i.bak 's|{{CNI_NET_PATH}}|'"$CNI_NET_PATH"'|g' {} \;
    find addons -name "*.yaml" -exec sed -i.bak 's|{{KUBE_FLANNEL_CFG_MOUNTPATH}}|'"$KUBE_FLANNEL_CFG_MOUNTPATH"'|g' {} \;
    find addons -name "*.yaml" -exec sed -i.bak 's|{{KUBE_FLANNEL_RUN_MOUNTPATH}}|'"$KUBE_FLANNEL_RUN_MOUNTPATH"'|g' {} \;

    log "初始化Kube Master"
    kubeadm init --config kubeadm-init.yaml --v=5 2>&1 | tee -a ${__current_dir}/install.log && \
    bak_kube_config && \
    install_network_plugin && \
    poll_k8s_ready && \
    sub_slave_rely
}

function bak_kube_config() {
    log "备份原有 kube admin 配置"
    
    kube_admin_path="$HOME/.kube/config"
    backup_path="$HOME/.kube/config.bak"

    # 确保目标目录存在
    mkdir -p "$HOME/.kube"

    # 备份原有配置
    if [ -f "$kube_admin_path" ]; then
        mv "$kube_admin_path" "$backup_path"
        log "原有 kube admin 配置已备份到 $backup_path"
    fi

    # 复制新的配置文件
    if [ -f "$KUBE_ADMIN_CONFIG_FILE" ]; then
        cp -i "$KUBE_ADMIN_CONFIG_FILE" "$kube_admin_path"
        chown $(id -u):$(id -g) "$kube_admin_path"
        log "新的 kube admin 配置已复制到 $kube_admin_path"
    else
        color_echo $yellow "错误: 配置文件 $KUBE_ADMIN_CONFIG_FILE 不存在"
        return 1
    fi

    # 更新 .bashrc
    if ! grep -q "export KUBECONFIG=$KUBE_ADMIN_CONFIG_FILE" "$HOME/.bashrc"; then
        echo "export KUBECONFIG=$KUBE_ADMIN_CONFIG_FILE" >> "$HOME/.bashrc"
        log "已将 KUBECONFIG 环境变量添加到 .bashrc"
    fi

    # 重新加载 .bashrc
    source "$HOME/.bashrc"
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
    mkdir -p $NODE_PACKAGE_PATH/$TARZAN_OFFLINE_PATH
    cp -R conf/ $NODE_PACKAGE_PATH/conf
    # 复制指定的目录到 $NODE_PACKAGE_PATH/$TARZAN_OFFLINE_PATH
    cp -R $TARZAN_OFFLINE_PATH/{base-dependence,bash-completion,cni,conntrack,containerd,k8s/$KUBE_VERSION} "$NODE_PACKAGE_PATH/$TARZAN_OFFLINE_PATH"
    # 复制所有的 .sh 文件到 $NODE_PACKAGE_PATH
    cp *.sh "$NODE_PACKAGE_PATH"
    cp -i $KUBE_ADMIN_CONFIG_FILE $NODE_PACKAGE_PATH/kubernetes-admin.config
    tar -czPf $NODE_PACKAGE_PATH.tar.gz $NODE_PACKAGE_PATH
    log "组装完成、请scp $NODE_PACKAGE_PATH.tar.gz 至slave节点"
}

while [[ $# -gt 0 ]]; do
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
        --image-pull-policy)
        KUBE_IMAGE_PULL_POLICY=$2
        echo "use image-pull-policy is: $(color_echo $green $KUBE_IMAGE_PULL_POLICY)"
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
        --join)
        KUBE_JOIN_MODE=1
        echo "Joining the Kubernetes cluster"
        ;;
        --masterip)
        if [[ -z "$2" ]]; then
            color_echo ${red} "Error: --masterip requires an argument"
            exit 1
        fi
        MASTER_IP=$2
        echo "Master IP set to: $(color_echo $green $MASTER_IP)"
        shift
        ;;
        --discovery-token-ca-cert-hash)
        if [[ -z "$2" ]]; then
            color_echo ${red} "Error: --discovery-token-ca-cert-hash requires an argument"
            exit 1
        fi
        DISCOVERY_TOKEN_CA_CERT_HASH=$2
        echo "Discovery token CA cert hash set to: $(color_echo $green $DISCOVERY_TOKEN_CA_CERT_HASH)"
        shift
        ;;
        -h|--help)
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "   -v, --version                               Versions 1.23.3, 1.28.2 are currently supported, default=$KUBE_VERSION"
        echo "   -p, --port                                  Port number for external access, default=$KUBE_BIND_PORT"
        echo "   -addr, --advertise_address                  kubectl access address, default=$KUBE_ADVERTISE_ADDRESS"
        echo "   -tk, --token                                token, default=$KUBE_TOKEN"
        echo "   -hname, --hostname [hostname]               set hostname, default=$KUBE_NODE_NAME"
        echo "   --flannel                                   use flannel network, and set this node as master"
        echo "   --calico                                    use calico network, and set this node as master"
        echo "   --slavepath                                 slave packaged path, default=$NODE_PACKAGE_PATH"
        echo "   --image-repository                          default=$GLOBAL_IMAGE_REPOSITORY"
        echo "   --addons-image-repository                   default=$ADDONS_IMAGE_REPOSITORY"
        echo "   --image-pull-policy                         imagePullPolicy (Always, IfNotPresent, Never) are currently supported, default=$KUBE_IMAGE_PULL_POLICY"
        echo "   --containerd-timeout                        default=$CONTAINERD_TIME_OUT"
        echo "   --pod-subnet                                default=$KUBE_POD_SUBNET"
        echo "   --serviceSubnet                             default=$KUBE_SERVICE_SUBNET"
        echo "   --join                                      join the Kubernetes cluster"
        echo "   --masterip                                  master node IP address"
        echo "   --discovery-token-ca-cert-hash              discovery token CA cert hash"
        echo "   -h, --help                                  find help"
        echo "   Master: sh install-kube.sh -v v1.23.3 -addr $INTRANET_IP --flannel"
        echo "   Slave:  sh install-kube.sh "
        echo "   Slave Join:  sh install-kube.sh --join --masterip xxxx --token xxx --discovery-token-ca-cert-hash xxxx"
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
    if [[ $KUBE_JOIN_MODE == 1 ]]; then
        slave_join
        run_command "kubeadm join $MASTER_IP --token $KUBE_TOKEN --discovery-token-ca-cert-hash $DISCOVERY_TOKEN_CA_CERT_HASH "
    fi
}

main