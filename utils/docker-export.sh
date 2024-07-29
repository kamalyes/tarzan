#!/usr/bin/env bash

# 检查是否提供了目录作为参数
if [ $# -eq 0 ]; then
    echo "Usage: $0 <import_directory>"
    exit 1
fi

# 设置包含要导出镜像的 .tar 文件的目录
EXPORT_DIR=$1

# 确保导出目录存在
mkdir -p "$EXPORT_DIR"

# 获取所有的镜像并导出
IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}')

# 遍历所有的镜像
for IMAGE in $IMAGES; do
    # 分割镜像仓库名和标签
    IFS=":" read -r REPOSITORY TAG <<< "$IMAGE"
    
    # 将仓库名中的斜杠替换为下划线
    SAFE_REPOSITORY=${REPOSITORY//\//_}
    
    # 构造导出文件的名称
    EXPORT_FILE="${SAFE_REPOSITORY}_${TAG}.tar"
    EXPORT_PATH="$EXPORT_DIR/$EXPORT_FILE"
    
    # 检查镜像是否存在，如果存在则导出
    if docker image inspect "${REPOSITORY}:${TAG}" >/dev/null 2>&1; then
        docker save -o "$EXPORT_PATH" "${REPOSITORY}:${TAG}"
        echo "Exported ${REPOSITORY}:${TAG} to $EXPORT_PATH"
    else
        echo "Error: ${REPOSITORY}:${TAG} does not exist"
    fi
done

echo "Export process completed."

