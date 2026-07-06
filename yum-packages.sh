#!/usr/bin/env bash
source ./common.sh

action=$1

function update_repos() {
  install_prompt="更新CentoSBase Repo地址"
  if prompt_for_confirmation "$which_prompt" "$install_prompt"; then
    mkdir /etc/yum.repos.d/bak && mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/bak
    wget -O /etc/yum.repos.d/CentOS-Base.repo http://mirrors.cloud.tencent.com/repo/centos7_base.repo
    wget -O /etc/yum.repos.d/epel.repo http://mirrors.cloud.tencent.com/repo/epel-7.repo
    yum clean all && yum makecache
    log "更新CentoSBase Repo地址成功"
  fi
}

function download_all_packages() {
  log "开始提取Yum Rpm包"
  log "传递到函数的参数总数：$#个"
  if [ "$1" ]; then
    log "接收到传递的第一个参数为$1, 原值：${TZ_BASE}将被该入参替换,即TZ_BASE=$1"
    TZ_BASE = $1
  else
    log "没有带参数,故下载到的依赖可前往${TZ_BASE}进行查看"
  fi
  log "开始下载依赖包"
  yum -y install --downloadonly --downloaddir=$TARZAN_OFFLINE_PATH/base-dependence ipset ipvsadm  wget tree curl jq vim net-tools unzip telnet iputils chrony
  yum -y install --downloadonly --downloaddir=$TARZAN_OFFLINE_PATH/bash-completion bash-completion
  yum -y install --downloadonly --downloaddir=$TARZAN_OFFLINE_PATH/docker-before device-mapper-persistent-data lvm2 yum-utils
  yum -y install --downloadonly --downloaddir=$TARZAN_OFFLINE_PATH/docker docker-ce docker-ce-cli docker-compose
  yum -y install --downloadonly --downloaddir=$TARZAN_OFFLINE_PATH/conntrack  conntrack
  yum -y install --downloadonly --downloaddir=$TARZAN_OFFLINE_PATH/containerd crictl containerd.io
  yum -y install --disableexcludes=kubernetes --nogpgcheck --downloadonly --downloaddir=$TARZAN_OFFLINE_PATH/k8s kubelet kubeadm kubectl
  log "Download Yum Rpm 依赖包下载完成"
}

function offline_install_dependent() {
  yum_install_template "$TARZAN_OFFLINE_PATH/base-dependence" "base-dependence"
  check_components "unzip" "chronyd" "telnet" "vim" "wget" "curl" "ntpdate"
}

function offline_install_conntrack() {
  yum_install_template "$TARZAN_OFFLINE_PATH/conntrack" conntrack
  check_components conntrack
}

function offline_install_containerd() {
  yum_install_template "$TARZAN_OFFLINE_PATH/containerd" "containerd"
  check_components containerd
  systemctl enable containerd --now
}

function offline_install_docker() {
  yum_install_template "$TARZAN_OFFLINE_PATH/docker-before" "docker-before"
  yum_install_template "$TARZAN_OFFLINE_PATH/docker" "docker"
  enable_service "docker"
}

function offline_install_kube(){
  log "接收到传递的KUBE_VERSION参数为$KUBE_VERSION"
  if which kubectl >/dev/null; then
    old_k8s_version=$(kubectl version --output=yaml|grep gitVersion|awk 'NR==1{print $2}')
    which_prompt="检测到本地已安装kubectl-$old_k8s_version"
    install_prompt="离线覆盖安装"
  else
    install_prompt="离线安装kubectl"
  fi
  if prompt_for_confirmation "$which_prompt" "$install_prompt"; then
      log "开始离线安装kubelet kubeadm kubectl"
      rpm -ivhU $TARZAN_OFFLINE_PATH/k8s/$KUBE_VERSION/*.rpm --nodeps --force
      new_k8s_version=$(kubectl version --output=yaml|grep gitVersion|awk 'NR==1{print $2}')
      log "离线安装kubelet kubeadm kubectl OK,k8s version: $(color_title $green $new_k8s_version)"
      log "开始离线安装bash-completion命令补全工具"
      rpm -ivhU $TARZAN_OFFLINE_PATH/bash-completion/*.rpm --nodeps --force
      # kubectl 补全脚本落到系统补全目录(与在线安装路径统一; bash-completion 包的 profile.d 脚本登录时自动加载该目录)
      kubectl completion bash > /etc/bash_completion.d/kubectl
      log "离线安装bash命令补全工具 OK"
  fi
  enable_service "kubelet"
}

function offline_install_cni_plugins(){
    install_prompt="离线安装cni"
    if prompt_for_confirmation "$which_prompt" "$install_prompt"; then
      log "开始${install_prompt}-$CNI_PLUGINS_VERSION"
      rm -rf  $CNI_INSTALL_PATH  && mkdir -p $CNI_INSTALL_PATH && tar zxvf $TARZAN_OFFLINE_PATH/cni/cni-plugins-linux-amd64-$CNI_PLUGINS_VERSION.tgz -C $CNI_INSTALL_PATH
      log "${install_prompt}-${CNI_PLUGINS_VERSION} OK"
    fi
}

function offline_install_dockercompose() {
  if which docker-compose >/dev/null; then
      which_prompt="检测到本地已安装DockerCompose"
      install_prompt="离线覆盖安装"
  else
      install_prompt="离线安装DockerCompose"
  fi
  if prompt_for_confirmation "$which_prompt" "$install_prompt"; then
    DOCKER_COMPOSE_VERSION=$(echo $(uname -s)-$(uname -m) | tr '[A-Z]' '[a-z]') 
    cp $TARZAN_OFFLINE_PATH/docker-compose/docker-compose-${DOCKER_COMPOSE_VERSION} /usr/local/bin/docker-compose
    #给他一个执行权限
    chmod +x /usr/local/bin/docker-compose
    log "检查DockerCompose是否正常安装"
    docker-compose version 1>/dev/null 2>/dev/null
    if [ $? != 0 ]; then
      color_echo ${red} "${install_prompt}失败"
    else
      log "${install_prompt}完成"
    fi
  fi
  check_components docker-compose
}


function online_download_dependency() {
  ensure_cloud_mirrors
  # 创建 offline 目录结构
  directories=(
      "base-dependence"
      "bash-completion"
      "cni"
      "conntrack"
      "containerd"
      "docker"
      "docker-before"
      "docker-compose"
      "k8s/$KUBE_VERSION"
  )

  for dir in "${directories[@]}"; do
      mkdir -p "$TARZAN_OFFLINE_PATH/$dir"
  done

  # 下载 base-dependence 包
  download_packages base-dependence "$RPM_BASE_URL" \
      bridge-utils-1.5-9.el7.$ARCHITECTURE.rpm \
      chrony-3.4-1.el7.$ARCHITECTURE.rpm \
      curl-7.29.0-59.el7.$ARCHITECTURE.rpm \
      iputils-20160308-10.el7.$ARCHITECTURE.rpm \
      libcurl-7.29.0-59.el7.$ARCHITECTURE.rpm \
      ntpdate-4.2.6p5-29.el7.centos.2.$ARCHITECTURE.rpm \
      telnet-0.17-65.el7_8.$ARCHITECTURE.rpm \
      unzip-6.0-21.el7.$ARCHITECTURE.rpm \
      vim-enhanced-7.4.629-7.el7.$ARCHITECTURE.rpm \
      wget-1.14-18.el7_6.1.$ARCHITECTURE.rpm

  # 下载 bash-completion 包
  download_packages bash-completion "$RPM_BASE_URL" \
      bash-completion-2.1-8.el7.noarch.rpm

  # 下载CNI包
  # download_packages cni "$GITHUB_CONTAINERNETWORKING_URL" \
  #     /$CNI_PLUGINS_VERSION/cni-plugins-linux-amd64-$CNI_PLUGINS_VERSION.tgz

  # 下载 conntrack 包
  download_packages conntrack "$RPM_BASE_URL" \
      conntrack-tools-1.4.4-7.el7.$ARCHITECTURE.rpm \
      libnetfilter_cthelper-1.0.0-11.el7.$ARCHITECTURE.rpm \
      libnetfilter_cttimeout-1.0.0-7.el7.$ARCHITECTURE.rpm \
      libnetfilter_queue-1.0.2-2.el7_2.$ARCHITECTURE.rpm \
      socat-1.7.3.2-2.el7.$ARCHITECTURE.rpm

  # 下载 containerd 包
  download_packages containerd "$RPM_DOCKER_URL" \
      containerd.io-1.6.26-3.1.el7.$ARCHITECTURE.rpm

  download_packages containerd "$RPM_KUBERNETES_URL" \
    3f5ba2b53701ac9102ea7c7ab2ca6616a8cd5966591a77577585fde1c434ef74-cri-tools-1.26.0-0.$ARCHITECTURE.rpm

  # 下载 docker 包
  if [[ $IS_MASTER == 1 ]]; then
    download_packages docker "$RPM_DOCKER_URL" \
        docker-ce-24.0.7-1.el7.$ARCHITECTURE.rpm \
        docker-ce-cli-24.0.7-1.el7.$ARCHITECTURE.rpm \
        docker-ce-rootless-extras-24.0.7-1.el7.$ARCHITECTURE.rpm \
        docker-compose-plugin-2.21.0-1.el7.$ARCHITECTURE.rpm

    # 下载 docker-before 包
    download_packages docker-before "$RPM_BASE_URL" \
        device-mapper-persistent-data-0.8.5-3.el7.$ARCHITECTURE.rpm \
        lvm2-2.02.187-6.el7.$ARCHITECTURE.rpm \
        yum-utils-1.1.31-54.el7_8.noarch.rpm
  fi
  
  # 下载 docker-compose包
  # download_packages docker-compose "$GITHUB_CONTAINERNETWORKING_URL" \
  #     /v2.23.2/docker-compose-linux-x86_64

  if [[ $KUBE_VERSION == "1.28.2" ]]; then
    download_packages k8s/$KUBE_VERSION "$RPM_KUBERNETES_URL" \
        e1cae938e231bffa3618f5934a096bd85372ee9b1293081f5682a22fe873add8-kubelet-1.28.2-0.$ARCHITECTURE.rpm \
        a24e42254b5a14b67b58c4633d29c27370c28ed6796a80c455a65acc813ff374-kubectl-1.28.2-0.$ARCHITECTURE.rpm \
        cee73f8035d734e86f722f77f1bf4e7d643e78d36646fd000148deb8af98b61c-kubeadm-1.28.2-0.$ARCHITECTURE.rpm
  else
    download_packages k8s/$KUBE_VERSION "$RPM_KUBERNETES_URL" \
        46a9ff25eb06635b698cf7cb1ba8f13650a067835682279a4c50c755a0661298-kubeadm-1.23.3-0.$ARCHITECTURE.rpm \
        c56fc5650bdb3e0234886533f16a5d5f9ef0ab1cbb2c7c9981f05ba67958cccd-kubectl-1.23.3-0.$ARCHITECTURE.rpm \
        b12353b679d428c5f36937a7071a68eb82a0abadd6ab03a2a3435e73b05acfda-kubelet-1.23.3-0.$ARCHITECTURE.rpm
  fi
  
  log "所有包已下载完成！"
}

# -------------------
# 在线安装(CentOS 8 / Debian 专用, CentOS 7 默认走离线流程)
# -------------------

# 统一在线包安装入口: rhel 家族走 dnf, debian 家族走 apt-get
function pkg_online_install() {
  if [[ "$OS_FAMILY" == "debian" ]]; then
    run_command "apt-get install -y $*"
  else
    run_command "dnf install -y $*"
  fi
}

# 配置在线软件源(CentOS 8: vault 归档 + epel-archive + docker-ce + kubernetes el8; Debian: docker-ce + kubernetes apt)
function config_online_repos() {
  ensure_cloud_mirrors
  if [[ "$OS_FAMILY" == "debian" ]]; then
    log "配置 Debian 在线软件源(镜像根: $MIRROR_ROOT)"
    local codename
    codename=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d '=' -f 2 | tr -d '"')
    cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb [trusted=yes] ${KUBERNETES_APT_BASE}/ kubernetes-xenial main
EOF
    cat <<EOF > /etc/apt/sources.list.d/docker-ce.list
deb [trusted=yes] ${DOCKER_CE_APT_BASE}/ ${codename} stable
EOF
    run_command "apt-get update"
  else
    log "配置 CentOS 8 在线软件源(系统已 EOL, 切换阿里云 vault 归档源)"
    mkdir -p /etc/yum.repos.d/bak
    mv -f /etc/yum.repos.d/CentOS-*.repo /etc/yum.repos.d/bak/ 2>/dev/null || true
    cat <<EOF > /etc/yum.repos.d/CentOS-Vault.repo
[BaseOS]
name=CentOS-8.5.2111 - BaseOS
baseurl=${CENTOS8_VAULT_BASE}/BaseOS/${ARCHITECTURE}/os/
gpgcheck=0

[AppStream]
name=CentOS-8.5.2111 - AppStream
baseurl=${CENTOS8_VAULT_BASE}/AppStream/${ARCHITECTURE}/os/
gpgcheck=0
EOF
    cat <<EOF > /etc/yum.repos.d/epel-archive.repo
[epel-archive]
name=CentOS-8 EPEL Archive
baseurl=${EPEL8_ARCHIVE_URL}
gpgcheck=0
EOF
    cat <<EOF > /etc/yum.repos.d/docker-ce.repo
[docker-ce-stable]
name=Docker CE Stable
baseurl=${DOCKER_CE_YUM_BASE}/8/${ARCHITECTURE}/stable
gpgcheck=0
EOF
    cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=${KUBERNETES_YUM_BASE}/repos/kubernetes-el8-${ARCHITECTURE}
gpgcheck=0
EOF
    run_command "dnf clean all"
    run_command "dnf makecache"
  fi
}

# 在线安装基础依赖(含 sshpass / chrony / conntrack / socat 等, 包名按家族对照)
function online_install_base() {
  log "在线安装基础依赖"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    pkg_online_install ipset ipvsadm conntrack socat chrony sshpass wget tree curl jq vim net-tools unzip telnet iputils-ping bash-completion iptables
  else
    pkg_online_install ipset ipvsadm conntrack-tools socat chrony sshpass wget tree curl jq vim net-tools unzip telnet iputils bash-completion iptables-nft
  fi
}

# 在线安装 containerd 与 cri-tools
function online_install_containerd() {
  log "在线安装 containerd 与 cri-tools"
  pkg_online_install containerd.io cri-tools
  enable_service containerd
}

# 在线安装 docker 与 compose 插件(仅 master)
function online_install_docker() {
  log "在线安装 docker 与 docker-compose 插件"
  pkg_online_install docker-ce docker-ce-cli docker-compose-plugin
  enable_service docker
}

# 在线安装 kubelet kubeadm kubectl(锁版本)
function online_install_kube() {
  log "在线安装 kubelet kubeadm kubectl, 版本 $KUBE_VERSION"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    run_command "apt-get install -y kubelet=$KUBE_VERSION-00 kubeadm=$KUBE_VERSION-00 kubectl=$KUBE_VERSION-00"
  else
    run_command "dnf install -y --disableexcludes=kubernetes kubelet-$KUBE_VERSION kubeadm-$KUBE_VERSION kubectl-$KUBE_VERSION"
  fi
  log "写入 kubectl 命令补全"
  # 直接重定向落盘(不走 run_command+tee: 补全脚本数百行, 经日志管道会全量灌进安装日志)
  kubectl completion bash > /etc/bash_completion.d/kubectl
  enable_service kubelet
}

function online_install_dependency() {
  log "当前系统 $OS_ID $OS_VERSION($OS_FAMILY 家族)在线安装, K8s 版本 $KUBE_VERSION, 是否 master: $IS_MASTER"
  config_online_repos
  online_install_base
  online_install_containerd
  # CNI 插件为通用 tgz, 在线下载后复用离线解压逻辑
  download_packages cni "$GITHUB_CONTAINERNETWORKING_URL" "/v$CNI_PLUGINS_VERSION/cni-plugins-linux-amd64-$CNI_PLUGINS_VERSION.tgz"
  offline_install_cni_plugins
  if [[ $IS_MASTER == 1 ]]; then
    online_install_docker
  fi
  online_install_kube
  log "在线安装依赖完成"
}

function offline_install_public_dependency() {
  offline_install_dependent
  log "Dependent installed successfully."

  offline_install_containerd
  log "Containerd installed successfully."

  offline_install_conntrack
  log "Conntrack installed successfully."

  offline_install_cni_plugins
  log "CNI installed successfully."
}

function main_entrance() {
  case "${action}" in
  update_repos)
    update_repos
    ;;
  offline_install_dependent)
    offline_install_dependent
    ;;
  offline_install_public_dependency)
    offline_install_public_dependency
    ;;
  offline_install_containerd)
    offline_install_containerd
    ;;
  offline_install_conntrack)
    offline_install_conntrack
    ;;
  offline_install_docker)
    offline_install_docker
    ;;
  offline_install_dockercompose)
    offline_install_dockercompose
    ;;
  offline_install_kube)
    KUBE_VERSION=$2
    log "Offline install Kube K8s Version $KUBE_VERSION"
    offline_install_kube
    ;;
  online_download_dependency)
    KUBE_VERSION=$2
    IS_MASTER=$3
    log "Online download rpm depend packages k8s version $KUBE_VERSION"
    log "Online download rpm depend packages is k8s master $IS_MASTER"
    online_download_dependency
    ;;
  online_install_dependency)
    KUBE_VERSION=$2
    IS_MASTER=$3
    log "Online install depend packages k8s version $KUBE_VERSION"
    log "Online install depend packages is k8s master $IS_MASTER"
    online_install_dependency
    ;;
  offline_install_cni_plugins)
    offline_install_cni_plugins
    ;;
  download_all_packages)
    download_all_packages
    ;;
  esac
}
main_entrance $@
