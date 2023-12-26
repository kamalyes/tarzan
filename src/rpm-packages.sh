#!/bin/bash
action=$1
__current_dir=$(
  cd "$(dirname "$0")"
  pwd
)

TZ_BASE=${TZ_BASE:-/opt/tarzan}

function log() {
  message="[Tarzan Log]: $1 "
  echo -e "\033[32m## ${message} \033[0m\n" 2>&1 | tee -a ${__current_dir}/install.log
}

function update_centos_repos() {
  log "开始更新CentoSBase Repo地址"
  mkdir /etc/yum.repos.d/bak && mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/bak
  wget -O /etc/yum.repos.d/CentOS-Base.repo http://mirrors.cloud.tencent.com/repo/centos7_base.repo
  wget -O /etc/yum.repos.d/epel.repo http://mirrors.cloud.tencent.com/repo/epel-7.repo
  yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
  yum clean all && yum makecache
  log "更新CentoSBase Repo地址成功"
}

function download_packages() {
  log "开始提取Yum Rpm包"
  log "传递到函数的参数总数：$#个"
  if [ "$1" ]; then
    log "接收到传递的第一个参数为$1, 原值：${TZ_BASE}将被该入参替换,即TZ_BASE=$1"
    TZ_BASE = $1
  else
    log "没有带参数,故下载到的依赖可前往${TZ_BASE}进行查看"
  fi
  log "开始下载依赖包."
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/base-dependence ipset ipvsadm vim wget tree curl bash-completion jq vim net-tools telnet git lrzsz bridge-utils telnet iputils chrony ntpdate
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/bash-completion bash-completion
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/docker-before yum-utils device-mapper-persistent-data lvm2 oniguruma
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/docker docker-ce docker-ce-cli
  yum -y install --downloadonly --downloaddir=${TZ_BASE}/offline/containerd containerd containerd.io
  yum -y install --disableexcludes=kubernetes --nogpgcheck --downloadonly --downloaddir=${TZ_BASE}/offline/k8s kubelet kubeadm kubectl
  log "Download Yum Rpm 依赖包下载完成."
}

function offline_install_depends() {
  log "开始离线安装常用工具包"
  rpm -ivhU offline/base-dependence/*.rpm --nodeps --force
  log "离线安装常用工具包完成"
}

function offline_install_docker() {
  log "开始离线安装docker containerd"
  rpm -ivhU offline/docker-before/*.rpm --nodeps --force
  rpm -ivhU offline/docker/*.rpm --nodeps --force
  rpm -ivhU offline/containerd/*.rpm --nodeps --force
  log "离线安装docker containerd完成"
  offline_install_dockercompose
}

function offline_install_kube(){
    if which kubectl >/dev/null; then
        which_prompt="检测到本地已安装kubectl"
        install_kubectl_prompt="覆盖安装"
    else
        install_kubectl_prompt="离线安装kubectl"
    fi
    read -p "${which_prompt}确认是否${install_kubectl_prompt}? [n/y]" __choice </dev/tty
    case "$__choice" in
        y | Y)
        log "开始离线安装kubelet kubeadm kubectl"
        rpm -ivhU offline/k8s/*.rpm --nodeps --force
        log "离线安装kubelet kubeadm kubectl OK"
        log "开始离线安装bash命令补全工具"
        rpm -ivhU offline/bash-completion/*.rpm --nodeps --force
        log "离线安装bash命令补全工具 OK"
        ;;
        n | N)
        echo "退出${install_kubectl_prompt}" &
        ;;
        *)
        echo "退出${install_kubectl_prompt}" &
        ;;
    esac
}

function offline_install_all_packages() {
  offline_install_depends && \
  offline_install_docker && \
  offline_install_kube
}

function online_install_all_packages() {
  for package in $(cat packages.version); do
    log "开始在线安装常用依赖包：${package}"
    yum -y install ${package}
  done
  # yum -y install containerd.io-1.6.26-3.1.el7.x86_64 \
  #   iputils-20160308-10.el7.x86_64 \
  #   chrony-3.4-1.el7.x86_64 \
  #   ipset-7.1-1.el7.x86_64 \
  #   ipvsadm-1.27-8.el7.x86_64 \
  #   wget-1.14-18.el7_6.1.x86_64 \
  #   net-tools-2.0-0.25.20131004git.el7.x86_64 \
  #   ntpdate-4.2.6p5-29.el7.centos.2.x86_64 \
  #   containerd.io-1.6.26-3.1.el7.x86_64 \
  #   telnet-0.17-66.el7.x86_64 \
  #   bash-completion-2.1-8.el7.noarch \
  #   vim-enhanced-7.4.629-8.el7_9.x86_64 \
  #   lvm2-2.02.187-6.el7_9.5.x86_64 \
  #   yum-utils-1.1.31-54.el7_8.noarch \
  #   device-mapper-persistent-data-0.8.5-3.el7_9.2.x86_64 \
  #   curl-7.29.0-59.el7_9.2.x86_64 \
  #   libcurl-7.29.0-59.el7_9.2.x86_64 \
  #   bridge-utils-1.5-9.el7.x86_64 \
  #   jq-1.6-2.el7.x86_64 \
  #   oniguruma-6.8.2-2.el7.x86_64
  # kubelet-1.25.3-0 kubeadm-1.25.3-0
  online_install_docker
}

function online_install_docker() {
    if which docker >/dev/null; then
      which_prompt="检测到本地已安装Docker"
      install_docker_prompt="覆盖安装"
    else
      install_docker_prompt="在线安装Docker"
    fi
    read -p "${which_prompt}确认是否${install_docker_prompt}? [n/y]" __choice </dev/tty
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
      echo "退出${install_docker_prompt}" &
      ;;
    *)
      echo "退出${install_docker_prompt}" &
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
  read -p "${which_prompt}确认是否${install_dockercompose_prompt}? [n/y]" __choice </dev/tty
  case "$__choice" in
    y | Y)
      DOCKER_COMPOSE_VERSION=$(echo $(uname -s)-$(uname -m) | tr '[A-Z]' '[a-z]') 
      cp offline/docker-compose/docker-compose-${DOCKER_COMPOSE_VERSION} /usr/local/bin/docker-compose
      #给他一个执行权限
      chmod +x /usr/local/bin/docker-compose
      log "检查DockerCompose是否正常安装"
      docker-compose version 1>/dev/null 2>/dev/null
      if [ $? != 0 ]; then
        log "DockerCompose安装失败"
      else
        log "DockerCompose安装完成"
      fi
    ;;
    n | N)
      echo "退出${install_dockercompose_prompt}" &
      ;;
    *)
      echo "退出${install_dockercompose_prompt}" &
      ;;
  esac
}

function offline_install_containerd() {
   if which containerd >/dev/null; then
      which_prompt="检测到本地已安装containerd"
      install_containerd_prompt="覆盖安装"
  else
      install_containerd_prompt="离线安装containerd"
  fi
  read -p "${which_prompt}确认是否${install_containerd_prompt}? [n/y]" __choice </dev/tty
  case "$__choice" in
    y | Y)
      tar Cxzvf /usr/local offline/containerd/containerd-1.7.11-linux-amd64.tar.gz
      mkdir tmp
      tar -xvf offline/containerd/cri-containerd-cni-1.7.11-linux-amd64.tar.gz -C tmp/
      log "使用systemd管理container"
      mkdir -p /usr/local/lib/systemd/system/
      cp tmp/etc/systemd/system/containerd.service /usr/local/lib/systemd/system/
      containerd 1>/dev/null 2>/dev/null
      if [ $? != 0 ]; then
        log "containerd 未正常启动，请先启动 containerd 后再次执行本脚本"
        exit
      fi
      # 重载配置让其生效
      systemctl daemon-reload
      mkdir -p /etc/containerd && containerd config default >/etc/containerd/config.toml.bak
    ;;
    n | N)
      echo "退出${install_containerd_prompt}" &
      ;;
    *)
      echo "退出${install_containerd_prompt}" &
      ;;
  esac
}

function main_entrance() {
  case "${action}" in
  update_centos_repos)
    update_centos_repos
    ;;
  download_packages)
    download_packages
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
  offline_install_containerd)
    offline_install_containerd
    ;;
  offline_install_dockercompose)
    offline_install_dockercompose
    ;;
  esac
}
main_entrance $@