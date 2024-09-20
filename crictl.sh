#!/usr/bin/env bash
source ./common.sh

action=$1

function pull_images() {
  for image in "$@"; do
    log "Pulling image: $GLOBAL_IMAGE_REPOSITORY/$image"
    if ! run_command "crictl pull '$GLOBAL_IMAGE_REPOSITORY/$image'"; then
      log "Failed to pull image: $GLOBAL_IMAGE_REPOSITORY/$image"
    fi
  done
}

function online_pull_kube_base_images() {
  # 根据K8s版本，定义特定镜像
  declare -A images_map
  images_map["$KUBE_VERSION"]="kube-apiserver:v$KUBE_VERSION kube-controller-manager:v$KUBE_VERSION kube-scheduler:v$KUBE_VERSION kube-proxy:v$KUBE_VERSION"

  # 定义公共镜像
  declare -A common_images_map
  common_images_map["1.23.3"]="pause:3.6 etcd:3.5.1-0 coredns:v1.8.6"
  common_images_map["1.28.2"]="pause:3.9 etcd:3.5.9-0 coredns:v1.10.1"

  # 获取对应版本的镜像
  local images=(${images_map[$KUBE_VERSION]})

  # 根据K8s版本合并公共镜像
  if [[ -n "${common_images_map[$KUBE_VERSION]}" ]]; then
    # 将字符串转换为数组
    local common_images=(${common_images_map[$KUBE_VERSION]})
    images+=("${common_images[@]}")
  else
    color_echo ${red} "No common images defined for Kubernetes version $KUBE_VERSION."
    return 0 # 先返回OK、不做下面操作
  fi

  # 下载所有镜像
  pull_images "${images[@]}"
}

function offline_load_kube_base_images() {
  # 检查目录是否存在
  if [ ! -d "$CRICTL_IMAGE_TAR_PATH/$KUBE_VERSION" ]; then
    color_echo ${fuchsia} "Directory $CRICTL_IMAGE_TAR_PATH/$KUBE_VERSION does not exist, SKipling Importing"
    return 0  # 目录不存在，跳过导入返回 OK
  fi

  # 使用 find 命令获取目录中所有 .tar.gz 文件  
  files=($(find "$CRICTL_IMAGE_TAR_PATH/$KUBE_VERSION" -type f -name "*.tar.gz"))

  # 检查是否找到了任何 .tar.gz 文件
  if [ ${#files[@]} -eq 0 ]; then
    color_echo ${fuchsia} "No .tar.gz files found in $CRICTL_IMAGE_TAR_PATH/$KUBE_VERSION"
    return 0  # 返回 OK，表示没有错误
  fi

  # 遍历数组中的每个文件，并导入到 K8s 中
  for file in "${files[@]}"; do
    log "Importing $file..."
    if ! run_command "ctr -n=k8s.io image import '$file'"; then
      color_echo ${red} "Failed to import image from $file"
      return 1  # 导入失败，返回错误
    fi
  done

  return 0  # 如果所有操作成功，返回 OK
}

function main_entrance() {
  case "${action}" in
  online_pull_kube_base_images)
    KUBE_VERSION=$2
    GLOBAL_IMAGE_REPOSITORY=$3
    log "Online Downloading images required 
        K8s Version $KUBE_VERSION
        Image Repository $GLOBAL_IMAGE_REPOSITORY
        "
    online_pull_kube_base_images
    ;;
  offline_load_kube_base_images)
    KUBE_VERSION=$2
    GLOBAL_IMAGE_REPOSITORY=$3
    log "Offline Load images required 
        K8s Version $KUBE_VERSION
        Image Repository $GLOBAL_IMAGE_REPOSITORY
        "
    offline_load_kube_base_images
    ;;
  esac
}
main_entrance $@