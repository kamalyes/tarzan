#!/bin/bash

# 确保用户传入了新的仓库地址作为参数
if [ -z "$1" ]; then
    echo "Usage: $0 <new_repo>"
    exit 1
fi

# 获取所有 images 列表
images=$(crictl images | awk '{if(NR>1) print $1}')

# 新仓库地址
new_repo=$1

# 循环处理每个 image
for image in $images
do
    # 为每个 image 执行 re-tag 操作
    docker tag $image $new_repo/$(echo $image | awk -F/ '{print $NF}') >/dev/null
done

# 显示更新后的 images 列表
echo "Images after retagging:"
crictl images
