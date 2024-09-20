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
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/$TARZAN_OFFLINE_PATH/base-dependence ipset ipvsadm vim wget tree curl bash-completion jq vim net-tools telnet git unzip lrzsz bridge-utils telnet iputils chrony ntpdate
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/$TARZAN_OFFLINE_PATH/bash-completion bash-completion
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/$TARZAN_OFFLINE_PATH/docker-before yum-utils device-mapper-persistent-data lvm2 oniguruma
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/$TARZAN_OFFLINE_PATH/docker docker-ce docker-ce-cli
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/$TARZAN_OFFLINE_PATH/conntrack crictl conntrack
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/$TARZAN_OFFLINE_PATH/containerd containerd containerd.io
  yum -y install --disableexcludes=kubernetes --nogpgcheck --downloadonly --downloaddir=${TZ_BASE}/$TARZAN_OFFLINE_PATH/k8s kubelet kubeadm kubectl
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
      log "离线安装kubelet kubeadm kubectl OK,k8s version: $(color_echo $green $new_k8s_version)"
      log "开始离线安装bash-completion命令补全工具"
      rpm -ivhU $TARZAN_OFFLINE_PATH/bash-completion/*.rpm --nodeps --force
      log "写入bash-completion环境变量"
      [[ -z $(grep kubectl ~/.bashrc) ]] && echo "source /usr/share/bash-completion/bash_completion && kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null"
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
    log "Online download rpm depend packages k8s version $KUBE_VERSION"
    online_download_dependency
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
