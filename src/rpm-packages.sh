#!/usr/bin/env bash
source ./common.sh

action=$1

function update_yum_repos() {
  update_yum_repos_prompt="更新CentoSBase Repo地址"
  read -p "请确认是否${update_yum_repos_prompt}? [n/y]" __choice </dev/tty
  case "$__choice" in
      y | Y)
    mkdir /etc/yum.repos.d/bak && mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/bak
    wget -O /etc/yum.repos.d/CentOS-Base.repo http://mirrors.cloud.tencent.com/repo/centos7_base.repo
    wget -O /etc/yum.repos.d/epel.repo http://mirrors.cloud.tencent.com/repo/epel-7.repo
    yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
    yum clean all && yum makecache
    log "更新CentoSBase Repo地址成功"
  ;;
    n | N)
    log "退出${update_yum_repos_prompt}"
  ;;
  *)
    log "退出${update_yum_repos_prompt}"
  ;;
  esac
}

function update_kube_repos() {
  update_kube_repos_prompt="更新Kubernetes Repo地址"
  read -p "请确认是否${update_kube_repos_prompt}? [n/y]" __choice </dev/tty
  case "$__choice" in
  y | Y)
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
    yum clean all && yum makecache
    log "${update_kube_repos_prompt}地址成功"
  ;;
    n | N)
    log "退出${update_kube_repos_prompt}"
  ;;
  *)
    log "退出${update_kube_repos_prompt}"
  ;;
  esac
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

function offline_install_dependent() {
  install_base_depend_prompt="离线安装常用工具包"
  read -p "请确认是否${install_base_depend_prompt}? [n/y]" __choice </dev/tty
  case "$__choice" in
    y | Y)
    rpm -ivhU offline/base-dependence/*.rpm --nodeps --force
    log "${install_base_depend_prompt} OK"
  ;;
  n | N)
    log "退出${install_base_depend_prompt}"
  ;;
  *)
    log "退出${install_base_depend_prompt}"
  ;;
  esac
}

function offline_install_ansible() {
  log "开始离线安装ansible&expect"
  rpm -ivhU offline/ansible/*.rpm --nodeps --force
  rpm -ivhU offline/expect/*.rpm --nodeps --force
  log "离线安装ansible完成"
}

function offline_install_dcni() {
  install_dcni_prompt="离线安装docker&containerd"
  read -p "请确认是否${install_dcni_prompt}? [n/y]" __choice </dev/tty
  case "$__choice" in
      y | Y)
    log "开始${install_dcni_prompt}"
    rpm -ivhU offline/docker-before/*.rpm --nodeps --force
    rpm -ivhU offline/docker/*.rpm --nodeps --force
    rpm -ivhU offline/conntrack/*.rpm --nodeps --force
    rpm -ivhU offline/containerd/*.rpm --nodeps --force
    if which systemctl >/dev/null; then
      log "设置docker开机启动"
      systemctl enable docker --now 2>&1 | tee -a ${__current_dir}/install.log
        log "设置containerd开机启动"
      systemctl enable containerd --now 2>&1 | tee -a ${__current_dir}/install.log
    fi
    log "${install_dcni_prompt}完成"
    offline_install_dockercompose
  ;;
  n | N)
    log "退出${install_dcni_prompt}"
  ;;
  *)
    log "退出${install_dcni_prompt}"
  ;;
  esac
}

function offline_install_kube(){
    if which kubectl >/dev/null; then
        old_k8s_version=$(kubectl version --output=yaml|grep gitVersion|awk 'NR==1{print $2}')
        which_prompt="检测到本地已安装kubectl-$old_k8s_version"
        install_kubectl_prompt="覆盖安装"
    else
        install_kubectl_prompt="离线安装kubectl"
    fi
    read -p "${which_prompt}请确认是否${install_kubectl_prompt}? [n/y]" __choice </dev/tty
    case "$__choice" in
      y | Y)
        log "开始离线安装kubelet kubeadm kubectl"
        rpm -ivhU offline/k8s/*.rpm --nodeps --force
        new_k8s_version=$(kubectl version --output=yaml|grep gitVersion|awk 'NR==1{print $2}')
        log "离线安装kubelet kubeadm kubectl OK,k8s version: $(color_echo $green $new_k8s_version)"
        log "开始离线安装bash命令补全工具"
        rpm -ivhU offline/bash-completion/*.rpm --nodeps --force
        log "命令行补全"
        [[ -z $(grep kubectl ~/.bashrc) ]] && echo "source <(kubectl completion bash)" >> ~/.bashrc
        [[ -z $(grep kubeadm ~/.bashrc) ]] && echo "source <(kubeadm completion bash)" >> ~/.bashrc
        log "离线安装bash命令补全工具 OK"
        cni_install_path="/opt/cni/bin"
        cni_version="v1.4.0"
        log "开始离线安装cni-plugins-$cni_version"
        rm -rf  $cni_install_path  && mkdir -p $cni_install_path && tar zxvf offline/cni/cni-plugins-linux-amd64-$cni_version.tgz -C $cni_install_path
        log "离线安装cni-plugins-${cni_version} OK"
        mkdir -p /var/lib/kubelet
        chmod 777 -R /var/lib/kubelet
        mkdir -p /etc/kubernetes
        chmod 777 -R /etc/kubernetes
        log "设置为开机自启并现在立刻启动服务"
        systemctl enable kubelet --now 2>&1 | tee -a ${__current_dir}/install.log
        log "设置kubectl自启OK"
        DOCKER_CGROUPS=$(docker info | grep 'Cgroup' | cut -d' ' -f3)
        log $DOCKER_CGROUPS
        cat >/etc/default/kubelet <<EOF
KUBELET_KUBEADM_EXTRA_ARGS=--cgroup-driver=$DOCKER_CGROUPS
EOF
      ;;
      n | N)
        log "退出${install_kubectl_prompt}"
      ;;
      *)
        log "退出${install_kubectl_prompt}"
      ;;
    esac
}

function offline_install_all_packages() {
  offline_install_dependent && \
  offline_install_dcni && \
  offline_install_kube
}

function online_install_all_packages() {
  file_path="conf/packages.version"
  for package in $(cat $file_path); do
    log "开始在线安装常用依赖包：${package}"
    yum -y install ${package}
  done
  online_install_docker
}

function online_install_docker() {
    if which docker >/dev/null; then
      which_prompt="检测到本地已安装Docker"
      install_docker_prompt="覆盖安装"
    else
      install_docker_prompt="在线安装Docker"
    fi
    read -p "${which_prompt}请确认是否${install_docker_prompt}? [n/y]" __choice </dev/tty
    case "$__choice" in
    y | Y)
      yum -y remove docker*
      yum -y install docker-ce-24.0.7-1.el7.x86_64 \
        docker-ce-rootless-extras-24.0.7-1.el7.x86_64 \
        docker-ce-cli-24.0.7-1.el7.x86_64
      if which systemctl >/dev/null; then
        log "设置Docker开机启动"
        systemctl enable docker --now 2>&1 | tee -a ${__current_dir}/install.log
      fi
      log "检查Docker服务是否正常运行"
      docker ps -a 1>/dev/null 2>/dev/null
      if [ $? != 0 ]; then
        log "Docker 未正常启动，请先安装并启动 Docker 服务后再次执行本脚本"
        exit
      else
        # journalctl -u docker # 查看运行日志
        # systemctl daemon-reload && systemctl restart docker # 重载配置
        log "Docker安装完成"
      fi
    ;;
    n | N)
      log "退出${install_docker_prompt}"
      ;;
    *)
      log "退出${install_docker_prompt}"
      ;;
    esac
}

function offline_install_dockercompose() {
  if which docker-compose >/dev/null; then
      which_prompt="检测到本地已安装DockerCompose"
      install_dockercompose_prompt="覆盖安装"
  else
      install_dockercompose_prompt="离线安装DockerCompose"
  fi
  read -p "${which_prompt}请确认是否${install_dockercompose_prompt}? [n/y]" __choice </dev/tty
  case "$__choice" in
    y | Y)
      DOCKER_COMPOSE_VERSION=$(echo $(uname -s)-$(uname -m) | tr '[A-Z]' '[a-z]') 
      cp offline/docker-compose/docker-compose-${DOCKER_COMPOSE_VERSION} /usr/local/bin/docker-compose
      #给他一个执行权限
      chmod +x /usr/local/bin/docker-compose
      log "检查DockerCompose是否正常安装"
      docker-compose version 1>/dev/null 2>/dev/null
      if [ $? != 0 ]; then
        log "${install_dockercompose_prompt}失败"
      else
        log "${install_dockercompose_prompt}完成"
      fi
    ;;
    n | N)
      log "退出${install_dockercompose_prompt}"
      ;;
    *)
      log "退出${install_dockercompose_prompt}"
      ;;
  esac
}

function main_entrance() {
  case "${action}" in
  update_yum_repos)
    update_yum_repos
    ;;
  download_all_packages)
    download_all_packages
    ;;
  offline_install_ansible)
    offline_install_ansible
    ;;
  offline_install_dependent)
    offline_install_dependent
    ;;
  offline_install_all_packages)
    offline_install_all_packages
    ;;
  online_install_all_packages)
    online_install_all_packages
    ;;
  online_install_docker)
    online_install_docker
    ;;
  offline_install_dockercompose)
    offline_install_dockercompose
    ;;
  esac
}
main_entrance $@