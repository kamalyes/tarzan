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
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/base-dependence ipset ipvsadm vim wget tree curl bash-completion jq vim net-tools telnet git unzip lrzsz bridge-utils telnet iputils chrony ntpdate
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/bash-completion bash-completion
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/docker-before yum-utils device-mapper-persistent-data lvm2 oniguruma
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/docker docker-ce docker-ce-cli
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/conntrack crictl conntrack
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/containerd containerd containerd.io
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/ansible epel-release ansible
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/expect expect
  yum -y install --disableexcludes=kubernetes --nogpgcheck --downloadonly --downloaddir=${TZ_BASE}/offline/k8s kubelet kubeadm kubectl
  log "Download Yum Rpm 依赖包下载完成"
}

function online_install_common_packages() {
    file_path="conf/yum-packages.version"

    if [ ! -f "$file_path" ] || [ ! -s "$file_path" ]; then
        log "错误：文件不存在或内容为空: $file_path"
    fi

    while IFS= read -r package || [ -n "$package" ]; do
        log "开始在线安装常用依赖包：${package}"
        yum -y install "$package"
    done < "$file_path"
}

function offline_install_dependent() {
  offline_install_template "offline/base-dependence" "base-dependence"
  check_components "unzip" "chronyd" "jq" "telnet" "vim" "wget" "curl" "ntpdate"
}

function offline_install_conntrack() {
  offline_install_template "offline/conntrack" conntrack
  check_components conntrack
}

function offline_install_containerd() {
  offline_install_template "offline/containerd" "containerd"
  check_components containerd
  systemctl enable containerd --now
}

function online_install_docker() {
  if which docker >/dev/null; then
    which_prompt="检测到本地已安装Docker"
    install_prompt="在线覆盖安装"
  else
    install_prompt="在线安装Docker"
  fi
  if prompt_for_confirmation "$which_prompt" "$install_prompt"; then
    yum -y remove docker*
    yum -y install docker-ce-24.0.7-1.el7.x86_64 \
      docker-ce-rootless-extras-24.0.7-1.el7.x86_64 \
      docker-ce-cli-24.0.7-1.el7.x86_64
  fi
  enable_docker_service
}

function offline_install_docker() {
  offline_install_template "offline/docker-before" "docker-before"
  offline_install_template "offline/docker" "docker"
  enable_docker_service
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
      rpm -ivhU offline/k8s/$KUBE_VERSION/*.rpm --nodeps --force
      new_k8s_version=$(kubectl version --output=yaml|grep gitVersion|awk 'NR==1{print $2}')
      log "离线安装kubelet kubeadm kubectl OK,k8s version: $(color_echo $green $new_k8s_version)"
      log "开始离线安装bash-completion命令补全工具"
      rpm -ivhU offline/bash-completion/*.rpm --nodeps --force
      log "写入bash-completion环境变量"
      [[ -z $(grep kubectl ~/.bashrc) ]] && echo "source /usr/share/bash-completion/bash_completion && kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null"
      log "离线安装bash命令补全工具 OK"
  fi
  enable_kube_service
}

function offline_install_cni(){
    install_prompt="离线安装cni"
    if prompt_for_confirmation "$which_prompt" "$install_prompt"; then
      cni_install_path="/opt/cni/bin"
      cni_version="v1.4.0"
      log "开始${install_prompt}-$cni_version"
      rm -rf  $cni_install_path  && mkdir -p $cni_install_path && tar zxvf offline/cni/cni-plugins-linux-amd64-$cni_version.tgz -C $cni_install_path
      log "${install_prompt}-${cni_version} OK"
    fi
}

function online_install_docker() {
  if which docker >/dev/null; then
    which_prompt="检测到本地已安装Docker"
    install_prompt="在线覆盖安装"
  else
    install_prompt="在线安装Docker"
  fi
  if prompt_for_confirmation "$which_prompt" "$install_prompt"; then
    yum -y remove docker*
    yum -y install docker-ce-24.0.7-1.el7.x86_64 \
      docker-ce-rootless-extras-24.0.7-1.el7.x86_64 \
      docker-ce-cli-24.0.7-1.el7.x86_64
    log "${install_prompt}完成"
  fi
  enable_docker_service
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
    cp offline/docker-compose/docker-compose-${DOCKER_COMPOSE_VERSION} /usr/local/bin/docker-compose
    #给他一个执行权限
    chmod +x /usr/local/bin/docker-compose
    log "检查DockerCompose是否正常安装"
    docker-compose version 1>/dev/null 2>/dev/null
    if [ $? != 0 ]; then
      log "${install_prompt}失败"
    else
      log "${install_prompt}完成"
    fi
  fi
  check_components docker-compose
}

function offline_install_public_dependency() {
  set -e  # 启用错误检查

  trap 'echo "An error occurred. Exiting."; exit 1;' ERR

  offline_install_dependent
  echo "Dependent installed successfully."

  offline_install_containerd
  echo "Containerd installed successfully."

  offline_install_conntrack
  echo "Conntrack installed successfully."

  offline_install_cni
  echo "CNI installed successfully."
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
  online_install_docker)
    online_install_docker
    ;;
  offline_install_docker)
    offline_install_docker
    ;;
  offline_install_dockercompose)
    offline_install_dockercompose
    ;;
  online_install_common_packages)
    online_install_common_packages
    ;;
  offline_install_kube)
    KUBE_VERSION=$2
    log "Offline install Kube K8s Version $KUBE_VERSION"
    offline_install_kube
    ;;
  offline_install_cni)
    offline_install_cni
    ;;
  download_all_packages)
    download_all_packages
    ;;
  esac
}
main_entrance $@