#!/usr/bin/env bash
source ./common.sh

action=$1

function online_pull_images() {
  # 列出所有需要下载的镜像
  kubeadm config images list --image-repository $GLOBAL_IMAGE_REPOSITORY
  
  # 根据K8s版本，下载相应的镜像
  case $KUBE_VERSION in
    "1.23.3")
      # 下载v1.23.3版本的镜像
      images=(
        kube-apiserver:v1.23.3
        kube-controller-manager:v1.23.3
        kube-scheduler:v1.23.3
        kube-proxy:v1.23.3
        pause:3.6
        etcd:3.5.1-0
        coredns:v1.8.6
      )
      ;;
    "1.28.2")
      # 下载v1.28.2版本的镜像
      images=(
        kube-apiserver:v1.28.2
        kube-controller-manager:v1.28.2
        kube-scheduler:v1.28.2
        kube-proxy:v1.28.2
        pause:3.9
        etcd:3.5.9-0
        coredns:v1.10.1
      )
      ;;
  esac
  
  # 遍历并下载每个镜像
  for image in "${images[@]}"; do
    crictl pull $GLOBAL_IMAGE_REPOSITORY/$image
  done
  
  # 根据选择的网络插件类型，下载相应的网络插件镜像
  case $KUBE_NETWORK in
    "flannel")
      # 下载Flannel网络插件的镜像
      crictl pull $GLOBAL_IMAGE_REPOSITORY/kube-flannel:v0.24.0
      crictl pull $GLOBAL_IMAGE_REPOSITORY/kube-flannel-cni-plugin:v1.2.0
      ;;
    "calico")
      # 下载Calico网络插件的镜像
      crictl pull $GLOBAL_IMAGE_REPOSITORY/kube-calico-controllers:v3.26.1
      crictl pull $GLOBAL_IMAGE_REPOSITORY/kube-calico-cni:v3.26.1
      crictl pull $GLOBAL_IMAGE_REPOSITORY/kube-calico-node:v3.26.1
      ;;
  esac
  
  # 下载其他常用的K8s相关插件镜像
  other_images=(
    kube-nginx-ingress-controller:v1.9.5
    kube-state-metrics:2.10.0
    kube-webhook-certgen:v20231011-8b53cabe0
    kube-metrics-server:v0.6.4
    kube-metrics-scraper:v1.0.4
    kube-dashboard:v2.7.0
  )
  
  for other_image in "${other_images[@]}"; do
    crictl pull $GLOBAL_IMAGE_REPOSITORY/$other_image
  done
}

function offline_load_images() {
  # 使用 find 命令获取目录中所有 .tar 文件
  CRICTL_IMAGE_TAR_PATH="offline/crictl-images"
  files=($(find "$CRICTL_IMAGE_TAR_PATH/$KUBE_VERSION" -type f -name "*.tar"))

  # 遍历数组中的每个文件，并导入到K8s中
  for file in "${files[@]}"; do
      log "Importing $file..."
      ctr -n=k8s.io image import "$file"
  done

  # 根据选择的网络插件类型，导入相应的网络插件镜像
  case $KUBE_NETWORK in
    "flannel")
      # Flannel网络插件的镜像文件
      network_files=(kube-flannel-cni-plugin_v1.2.0.tar.gz kube-flannel-v0.24.0.tar.gz)
      ;;
    "calico")
      # Calico网络插件的镜像文件
      network_files=(kube-calico-controllers_v3.26.1.tar.gz kube-calico-cni_v3.26.1.tar.gz kube-calico-node_v3.26.1.tar.gz)
      ;;
  esac

  # 如果定义了网络插件镜像文件，则导入它们
  for network_file in "${network_files[@]}"; do
    # 拼接完整路径
    full_path="$CRICTL_IMAGE_TAR_PATH/$network_file"
    # 检查文件是否存在
    if [ -f "$full_path" ]; then
      log "Importing network file $network_file..."
      ctr -n=k8s.io image import "$full_path"
    else
      echo "File $network_file not found."
    fi
  done

  # 其他常用的K8s相关镜像文件
  other_files=(kube-dashboard_v2.7.0.tar.gz kube-metrics-scraper_v1.0.4 kube-metrics-server_v0.6.4.tar.gz kube-nginx-ingress-controller_v1.9.5.tar.gz kube-state-metrics_2.10.0.tar.gz kube-webhook-certgen_v20231011-8b53cabe0.tar.gz)
  
  # 导入其他镜像文件
  for other_file in "${other_files[@]}"; do
      full_path="$CRICTL_IMAGE_TAR_PATH/$other_file"
      # 检查文件是否存在
      if [ -f "$full_path" ]; then
        log "Importing other file $other_file..."
        ctr -n=k8s.io image import "$full_path"
      else
        echo "File $other_file not found."
      fi
  done
}

function main_entrance() {
  case "${action}" in
  online_pull_images)
    KUBE_VERSION=$2
    GLOBAL_IMAGE_REPOSITORY=$3
    log "Online Downloading images required 
        K8s Version $KUBE_VERSION
        Image Repository $GLOBAL_IMAGE_REPOSITORY
        "
    online_pull_images
    ;;
  offline_load_images)
    KUBE_VERSION=$2
    KUBE_NETWORK=$3
    GLOBAL_IMAGE_REPOSITORY=$4
    log "Offline Load images required 
        K8s Version $KUBE_VERSION
        Network Type $KUBE_NETWORK
        Image Repository $GLOBAL_IMAGE_REPOSITORY
        "
    offline_load_images
    ;;
  esac
}
main_entrance $@