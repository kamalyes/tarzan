#!/usr/bin/env bash
source ./common.sh

action=$1

function pull_images() {
  for image in "$@"; do
    log "Pulling image: $GLOBAL_IMAGE_REPOSITORY/$image"
    # timeout: 跨云拉公网 registry 被限速时下载极慢, crictl 无超时保护会无限卡死
    # (Ctrl+C 只能杀客户端, containerd 后台的下载任务仍在跑, 需 restart containerd 清除)
    if ! run_command "timeout -k 5 300 crictl pull '$GLOBAL_IMAGE_REPOSITORY/$image'"; then
      color_echo ${red} "拉取失败或超时(300s): $GLOBAL_IMAGE_REPOSITORY/$image
      若公网限速所致: 在 master 执行 crictl.sh export_slave_base_images 导出镜像副本, 放入本机 $CRICTL_IMAGE_TAR_PATH/$KUBE_VERSION/ 后重跑(自动走离线导入);
      残留的后台下载任务可在本机 systemctl restart containerd 清除"
    fi
  done
}

# 按节点角色列出 K8s 基础镜像清单(在线拉取与 master 导出共用一份映射, 避免两处维护漂移)
# slave 只运行 kube-proxy 与 pause, apiserver/etcd/coredns 等 master 组件镜像不涉及(省流量省时间)
function kube_base_images() {
  local is_master=$1
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
    return 1 # 版本档位无镜像映射, 调用方决定跳过还是中断
  fi

  # slave 角色过滤出 kube-proxy 与 pause
  if [[ "$is_master" != 1 ]]; then
    local -a node_images=()
    for image in "${images[@]}"; do
      case "$image" in
        kube-proxy:* | pause:*) node_images+=("$image") ;;
      esac
    done
    images=("${node_images[@]}")
  fi

  echo "${images[@]}"
}

function online_pull_kube_base_images() {
  # 版本档位无公共镜像映射时先返回OK、不做拉取
  local images
  images=$(kube_base_images "$IS_MASTER") || return 0
  [ -z "$images" ] && return 0

  # 下载所有镜像
  pull_images $images
}

# master 侧: 导出 slave 加入所需基础镜像到离线目录(打包进 slave 分发包, slave 走离线导入免公网拉取)
function export_slave_base_images() {
  local images
  images=$(kube_base_images 0) || return 1
  local target_dir="$CRICTL_IMAGE_TAR_PATH/$KUBE_VERSION"
  mkdir -p "$target_dir"
  local -a refs=()
  for image in $images; do
    local ref="$GLOBAL_IMAGE_REPOSITORY/$image"
    # 导出前校验 master 本地已有(缺镜像时 ctr export 直接报错, 提前给出可定位的提示)
    if ! ctr -n k8s.io images ls | awk '{print $1}' | grep -qx "$ref"; then
      color_echo ${red} "master 本地缺少镜像 $ref, 请确认 master 基础镜像已拉取(init 阶段的 load_images)"
      return 1
    fi
    refs+=("$ref")
  done
  local tar_file="$target_dir/slave-base-images.tar"
  log "导出 slave 基础镜像副本: ${refs[*]}"
  ctr -n k8s.io images export "$tar_file" "${refs[@]}" && gzip -f "$tar_file"
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
    IS_MASTER=${4:-1}
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
  export_slave_base_images)
    KUBE_VERSION=$2
    GLOBAL_IMAGE_REPOSITORY=$3
    log "Export slave base images for packaging
        K8s Version $KUBE_VERSION
        Image Repository $GLOBAL_IMAGE_REPOSITORY
        "
    export_slave_base_images
    ;;
  esac
}
main_entrance $@