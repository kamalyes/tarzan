#!/usr/bin/env bash

# 检查是否提供了目录作为参数
if [ $# -eq 0 ]; then
    echo "Usage: $0 <import_directory>"
    exit 1
fi

# 设置包含要导入镜像的 .tar 文件的目录
IMPORT_DIR=$1

# 检查目录是否存在
if [ ! -d "$IMPORT_DIR" ]; then
    echo "Error: Directory $IMPORT_DIR does not exist."
    exit 1
fi

# 遍历目录下的所有 .tar 文件并导入
for TAR_FILE in "$IMPORT_DIR"/*.tar; do
    if [ -f "$TAR_FILE" ]; then
        echo "Importing $TAR_FILE..."
        docker load -i "$TAR_FILE"
        if [ $? -eq 0 ]; then
            echo "Successfully imported $TAR_FILE"
        else
            echo "Failed to import $TAR_FILE"
        fi
    fi
done

echo "Import process completed."
