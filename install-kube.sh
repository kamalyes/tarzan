#!/usr/bin/env bash
source ./common.sh

function install_depend(){
    # 云厂商端点自适应(主进程覆盖变量, 供后续 setupconfig 写入正确 repo)
    ensure_cloud_mirrors
    if [[ $OFFLINE_SUPPORTED == 1 ]]; then
        run_command "/bin/bash yum-packages.sh online_download_dependency $KUBE_VERSION $IS_MASTER"
        log "安装所需依赖"
        run_command "/bin/bash yum-packages.sh offline_install_public_dependency"
        if [[ $IS_MASTER == 1 ]]; then
            run_command "/bin/bash yum-packages.sh offline_install_docker"
            run_command "/bin/bash yum-packages.sh offline_install_dockercompose"
        fi
        run_command "/bin/bash yum-packages.sh offline_install_kube $KUBE_VERSION"
    else
        log "当前系统($OS_ID $OS_VERSION)不支持离线包(el7 RPM), 走在线安装"
        run_command "/bin/bash yum-packages.sh online_install_dependency $KUBE_VERSION $IS_MASTER"
    fi
}

function prepare_work() {
	log "初始化k8s所需要环境"
    KUBE_PAUSE_VERSION=$KUBE_PAUSE_VERSION
    if [[ $KUBE_VERSION == "1.28.2" ]]; then
        KUBE_PAUSE_VERSION=3.9
    fi
    # 安装依赖
	run_command "/bin/bash setupconfig.sh source_chrony"
	run_command "/bin/bash setupconfig.sh update_ipvs_conf"
    run_command "/bin/bash setupconfig.sh update_kubernetes_conf"
	run_command "/bin/bash setupconfig.sh rest_firewalld"
	run_command "/bin/bash setupconfig.sh disable_swapoff"
	run_command "/bin/bash setupconfig.sh disabled_selinux"
	run_command "/bin/bash setupconfig.sh update_k8s_module_conf"
	run_command "/bin/bash setupconfig.sh update_limits_conf"
	run_command "/bin/bash setupconfig.sh update_containerd_conf $GLOBAL_IMAGE_REPOSITORY $KUBE_PAUSE_VERSION $CONTAINERD_TIME_OUT"
	run_command "/bin/bash setupconfig.sh check"
}

function upload_hosts {
    local update_host_prompt="Updating hosts file"
    # conf/hosts 由 conf/ssh_hosts 派生(单一清单维护), master 侧每次执行刷新; slave 侧无 ssh_hosts 时用包内副本
    refresh_hosts_file

    # 检查 conf/hosts 文件是否存在
    if [ -f "conf/hosts" ]; then
        log "Processing conf/hosts file"

        # 逐行处理 conf/hosts 文件
        while IFS= read -r line; do
            # 检查是否该行内容在 /etc/hosts 中存在(-x 全行匹配, -F 按字面量避免点号被当通配)
            if ! grep -qxF "$line" /etc/hosts; then
                # 不存在则追加到 /etc/hosts 后面
                echo "$line" >> /etc/hosts
            fi
        done < "conf/hosts"
        # /etc/hosts 修改即时生效, 无需重启网络
        log "${update_host_prompt} OK"
    else
        color_echo ${fuchsia} "conf/hosts file not found. Skipping."
    fi
}

function load_images {
    # 列出所有需要下载的镜像
    log "Listing images for Kubernetes version $KUBE_VERSION..."
    kubeadm config images list --image-repository "$GLOBAL_IMAGE_REPOSITORY"

    # 默认在线拉取; 仅当策略允许离线(IfNotPresent/Never)且离线镜像目录真实存在时才走离线导入
    # (slave 安装包按最小化组装不携带 crictl-images, 若无此兜底会: 跳过导入 -> crictl images 校验失败 -> 安装中断)
    local load_command="online_pull_kube_base_images"
    if [[ "$OFFLINE_SUPPORTED" == 1 ]] && [ -d "$CRICTL_IMAGE_TAR_PATH/$KUBE_VERSION" ]; then
        case "$KUBE_IMAGE_PULL_POLICY" in
            IfNotPresent | Never)
                load_command="offline_load_kube_base_images"
                ;;
        esac
    fi

    # 执行加载镜像的命令(附 IS_MASTER 供 crictl.sh 按节点角色过滤镜像), 列出所有镜像并过滤出指定的镜像仓库
    run_command "/bin/bash crictl.sh $load_command $KUBE_VERSION $GLOBAL_IMAGE_REPOSITORY $IS_MASTER" && \
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

    if [[ "$OS_FAMILY" == "unsupported" ]] || { [[ "$OS_FAMILY" == "rhel" ]] && [[ "$OS_VERSION" != "7" && "$OS_VERSION" != "8" ]]; }; then
        color_echo ${red} "不支持的操作系统(检测到 $OS_ID $OS_VERSION), 仅支持 CentOS 7(离线+在线) / CentOS 8(在线) / Debian(在线)"
        exit 1
    fi
    if [[ $OFFLINE_SUPPORTED == 1 ]]; then
        log "检测到操作系统: $OS_ID $OS_VERSION($OS_FAMILY 家族, 支持离线安装)"
    else
        log "检测到操作系统: $OS_ID $OS_VERSION($OS_FAMILY 家族, 仅在线安装)"
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
    # 渲染副本 + 占位符替换统一走 common.sh 机制(与 addons/components 一致, 模板原件永不修改)
    render_manifest kubeadm-init.yaml conf/kubeadm-init-template.yaml
    replace_manifest_placeholders kubeadm-init.yaml

    cat kubeadm-init.yaml
    # addons 占位符已由 install-addons.sh 在 apply 时渲染为副本(模板原件不被修改), 此处不再预渲染

    log "初始化Kube Master"
    run_command "kubeadm init --config kubeadm-init.yaml --v=5" && \
    bak_kube_config && \
    install_network_plugin && \
    poll_k8s_ready && \
    install_storage_plugin && \
    install_ingress_plugin && \
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

# 存储层安装(longhorn 是集群默认存储类提供者: 业务组件/openobserve/traefik acme 的 PVC 都依赖, 必装)
function install_storage_plugin(){
    log "开始安装存储层 longhorn(版本按集群档位自动选择)"
    run_command "/bin/bash install-addons.sh longhorn"
}

# Ingress Controller 安装(traefik 与 ingress-nginx 二选一, 由 --traefik / --ingress-nginx 指定)
function install_ingress_plugin(){
    if [[ $KUBE_INGRESS_PLUGIN == "traefik" ]]; then
        log "开始安装 traefik ingress controller version: $TRAEFIK_VERSION"
        run_command "/bin/bash install-addons.sh traefik"
    elif [[ $KUBE_INGRESS_PLUGIN == "ingress-nginx" ]]; then
        log "开始安装 ingress-nginx version: $INGRESS_NGINX_VERSION"
        run_command "/bin/bash install-addons.sh ingress-nginx $INGRESS_NGINX_VERSION"
    fi
}

function sub_slave_rely(){
    log "创建Kube Node连接所需要的Token"
    run_command "kubeadm token create --print-join-command --ttl=0"
    log "开始组装slave安装包"
    rm -rf $NODE_PACKAGE_PATH
    mkdir -p $NODE_PACKAGE_PATH/$TARZAN_OFFLINE_PATH
    # 刷新派生的 conf/hosts(用户可能刚调整过 ssh_hosts 的主机名规划, 包内副本取最新)
    refresh_hosts_file
    # 只携带派生出的纯净 conf/hosts(供 slave 同步 /etc/hosts), 带密码的 conf/ssh_hosts 绝不进分发包
    mkdir -p $NODE_PACKAGE_PATH/conf
    cp conf/hosts $NODE_PACKAGE_PATH/conf/ 2>/dev/null || true
    # 仅 CentOS 7 离线模式需要分发 RPM 依赖, 在线模式 slave 自行在线安装, 减小分发包体积
    if [[ $OFFLINE_SUPPORTED == 1 ]]; then
        # 复制指定的目录到 $NODE_PACKAGE_PATH/$TARZAN_OFFLINE_PATH
        cp -R $TARZAN_OFFLINE_PATH/{base-dependence,bash-completion,cni,conntrack,containerd,k8s/$KUBE_VERSION} "$NODE_PACKAGE_PATH/$TARZAN_OFFLINE_PATH"
    else
        mkdir -p $NODE_PACKAGE_PATH/$TARZAN_OFFLINE_PATH
    fi
    # 复制所有的 .sh 文件到 $NODE_PACKAGE_PATH
    cp *.sh "$NODE_PACKAGE_PATH"
    # kubectl 凭证不打包(master 的 admin.conf 是敏感凭证), slave 加入集群后由 group-control.sh install-slaves 统一分发到 ~/.kube/config
    tar -czPf $NODE_PACKAGE_PATH.tar.gz $NODE_PACKAGE_PATH
    # 节点间端口放行提示(云安全组未放行时 slave 加入后将持续 NotReady, 提前告知避免事后排查)
    log "请在云厂商安全组放行节点间端口(源建议设为 VPC 内网网段):"
    echo "  - TCP 6443                 Kubernetes API(slave -> master)"
    echo "  - TCP 10250                kubelet API(节点互访)"
    if [[ $KUBE_NETWORK == "flannel" ]]; then
        echo "  - UDP 8472                 flannel VXLAN(节点间 Pod 网络)"
    elif [[ $KUBE_NETWORK == "calico" ]]; then
        echo "  - TCP 179                  calico BGP(节点间 Pod 路由)"
    fi
    echo "  - TCP/UDP 30000-32767      NodePort(业务需要时)"
    log "组装完成, 在 master 执行 ./group-control.sh install-slaves 一键分发安装(或手动 scp 至slave节点)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)
        KUBE_BIND_PORT=$2
        echo "prepare install k8s bind port: $(color_title $green $KUBE_BIND_PORT)"
        shift
        ;;
        -v | --version)
        KUBE_VERSION=$(echo "$2" | sed 's/v//g')
        echo "prepare install k8s version: $(color_title $green $KUBE_VERSION)"
        shift
        ;;
        -addr | --advertise_address)
        KUBE_ADVERTISE_ADDRESS=$2
        echo "prepare install k8s advertise_address: $(color_title $green $KUBE_ADVERTISE_ADDRESS)"
        shift
        ;;
        -tk|--token)
        KUBE_TOKEN=$2
        echo "prepare install k8s token: $(color_title $green $KUBE_TOKEN)"
        shift
        ;;
        -hname | --hostname)
        KUBE_NODE_NAME=$2
        set_hostname $KUBE_NODE_NAME
        shift
        ;;
        -y | --yes)
        export AUTO_CONFIRM=1
        echo "auto confirm all interactive prompts: $(color_title $green yes)"
        ;;
        --flannel)
        echo "use $(color_title $green flannel ) network, and set this node as master"
        KUBE_NETWORK="flannel"
        IS_MASTER=1
        ;;
        --calico)
        echo "use $(color_title $green calico )  network, and set this node as master"
        KUBE_NETWORK="calico"
        IS_MASTER=1
        ;;
        --traefik)
        if [[ $KUBE_INGRESS_PLUGIN == "ingress-nginx" ]]; then
            color_echo ${red} "--traefik 与 --ingress-nginx 互斥, Ingress Controller 只能二选一"
            exit 1
        fi
        echo "use $(color_title $green traefik ) ingress controller"
        KUBE_INGRESS_PLUGIN="traefik"
        ;;
        --ingress-nginx)
        if [[ $KUBE_INGRESS_PLUGIN == "traefik" ]]; then
            color_echo ${red} "--traefik 与 --ingress-nginx 互斥, Ingress Controller 只能二选一"
            exit 1
        fi
        echo "use $(color_title $green ingress-nginx ) ingress controller"
        KUBE_INGRESS_PLUGIN="ingress-nginx"
        ;;
        --slavepath)
        NODE_PACKAGE_PATH=$2
        echo "slave packaged path: $(color_title $green $NODE_PACKAGE_PATH)"
        ;;
        --image-repository)
        GLOBAL_IMAGE_REPOSITORY=$2
        echo "use image-repository is: $(color_title $green $GLOBAL_IMAGE_REPOSITORY)"
        ;;
        --addons-repository)
        ADDONS_IMAGE_REPOSITORY=$2
        echo "use addons-image-repository is: $(color_title $green $ADDONS_IMAGE_REPOSITORY)"
        ;;
        --image-pull-policy)
        KUBE_IMAGE_PULL_POLICY=$2
        echo "use image-pull-policy is: $(color_title $green $KUBE_IMAGE_PULL_POLICY)"
        ;;
        --containerd-timeout)
        CONTAINERD_TIME_OUT=$2
        echo "containerd-timeout is: $(color_title $green $CONTAINERD_TIME_OUT)"
        ;;
        --pod-subnet)
        KUBE_POD_SUBNET=$2
        echo "pod-subnet is: $(color_title $green $KUBE_POD_SUBNET)"
        ;;
        --serviceSubnet)
        KUBE_SERVICE_SUBNET=$2
        echo "serviceSubnet is: $(color_title $green $KUBE_SERVICE_SUBNET)"
        ;;
        --join)
        KUBE_JOIN_MODE=1
        echo "Joining the Kubernetes cluster"
        ;;
        --pack-slave)
        PACK_SLAVE_ONLY=1
        echo "Rebuild the slave install package only"
        ;;
        --masterip)
        if [[ -z "$2" ]]; then
            color_echo ${red} "Error: --masterip requires an argument"
            exit 1
        fi
        MASTER_IP=$2
        echo "Master IP set to: $(color_title $green $MASTER_IP)"
        shift
        ;;
        --discovery-token-ca-cert-hash)
        if [[ -z "$2" ]]; then
            color_echo ${red} "Error: --discovery-token-ca-cert-hash requires an argument"
            exit 1
        fi
        DISCOVERY_TOKEN_CA_CERT_HASH=$2
        echo "Discovery token CA cert hash set to: $(color_title $green $DISCOVERY_TOKEN_CA_CERT_HASH)"
        shift
        ;;
        -create-vreth|--create-virtualeth)
        add_virtual_ip "$KUBE_ADVERTISE_ADDRESS" $VIRTUALETH_BACK_PREFIX
        ;;
        -h|--help)
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "   -v, --version                               Versions 1.23.3, 1.28.2 are currently supported, default=$KUBE_VERSION"
        echo "   -p, --port                                  Port number for external access, default=$KUBE_BIND_PORT"
        echo "   -addr, --advertise_address                  kubectl access address, default=$KUBE_ADVERTISE_ADDRESS"
        echo "   -tk, --token                                token, default=$KUBE_TOKEN"
        echo "   -hname, --hostname [hostname]               set hostname, default=$KUBE_NODE_NAME"
        echo "   -y, --yes                                   auto confirm all interactive prompts"
        echo "   --flannel                                   use flannel network, and set this node as master"
        echo "   --calico                                    use calico network, and set this node as master"
        echo "   --traefik                                   use traefik ingress controller (conflicts with --ingress-nginx)"
        echo "   --ingress-nginx                             use ingress-nginx ingress controller (conflicts with --traefik)"
        echo "   --slavepath                                 slave packaged path, default=$NODE_PACKAGE_PATH"
        echo "   --image-repository                          default=$GLOBAL_IMAGE_REPOSITORY"
        echo "   --addons-image-repository                   default=$ADDONS_IMAGE_REPOSITORY"
        echo "   --image-pull-policy                         imagePullPolicy (Always, IfNotPresent, Never) are currently supported, default=$KUBE_IMAGE_PULL_POLICY"
        echo "   --containerd-timeout                        default=$CONTAINERD_TIME_OUT"
        echo "   --pod-subnet                                default=$KUBE_POD_SUBNET"
        echo "   --serviceSubnet                             default=$KUBE_SERVICE_SUBNET"
        echo "   --join                                      join the Kubernetes cluster"
        echo "   --pack-slave                                rebuild the slave install package only (for master already installed)"
        echo "   --masterip                                  master node IP address"
        echo "   --discovery-token-ca-cert-hash              discovery token CA cert hash"
        echo "   -create-vreth|--create-virtualeth           default=false"
        echo "   -h, --help                                  find help"
        echo "   Master: sh install-kube.sh -y -v v1.23.3 -addr $INTRANET_IP --flannel"
        echo "   Slave:  sh install-kube.sh "
        echo "   Slave Join:  sh install-kube.sh -y --join --masterip xxxx --token xxx --discovery-token-ca-cert-hash xxxx"
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

# Ingress Controller 插件仅在 master 初始化流程(--flannel/--calico)中生效
if [[ -n "$KUBE_INGRESS_PLUGIN" && $IS_MASTER != 1 ]]; then
    color_echo ${red} "--traefik/--ingress-nginx 需配合 --flannel/--calico 在 master 初始化时使用"
    exit 1
fi

main() {
    check_sys
    # join 幂等: 已在集群中的机器(master/已加入 slave 均有 kubelet.conf)直接跳过, 避免重复执行报 FileAvailable 错误
    if [[ $KUBE_JOIN_MODE == 1 && -f /etc/kubernetes/kubelet.conf ]]; then
        log "本机已在 Kubernetes 集群中(/etc/kubernetes/kubelet.conf 已存在), 跳过加入; 如需重新加入请先执行 clean-residue.sh 清理残留"
        exit 0
    fi
    # 仅重新组装 slave 安装包(master 已就绪, 不重跑安装流程), 用于安装包被清理后补包
    if [[ $PACK_SLAVE_ONLY == 1 ]]; then
        sub_slave_rely
        exit 0
    fi
    upload_hosts
    install_depend
    prepare_work
    load_images
    if [[ $IS_MASTER == 1 ]]; then
        init_master
    fi
    if [[ $KUBE_JOIN_MODE == 1 ]]; then
        # kubectl 凭证(kubeconfig)不再由包内携带, join 完成后由群控统一分发
        run_command "kubeadm join $MASTER_IP --token $KUBE_TOKEN --discovery-token-ca-cert-hash $DISCOVERY_TOKEN_CA_CERT_HASH "
    fi
}

main