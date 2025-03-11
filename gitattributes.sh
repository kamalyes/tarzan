#!/bin/bash

# 定义要查找的目录和大小限制
DIRECTORY="offline"
MAX_SIZE=1
SIZE_LIMIT=$(($MAX_SIZE * 1024 * 1024))  # $MAX_SIZE MB in bytes
GIT_ATTRIBUTES_FILE=".gitattributes"

# 检查目录是否存在
if [[ ! -d "$DIRECTORY" ]]; then
    echo "目录 $DIRECTORY 不存在."
    exit 1
fi

# 仅重新生成 offline 大文件的 LFS 规则, 保留其余规则(如全局 LF 换行规则)
grep -v 'filter=lfs' "$GIT_ATTRIBUTES_FILE" > "${GIT_ATTRIBUTES_FILE}.tmp" 2>/dev/null || true
mv "${GIT_ATTRIBUTES_FILE}.tmp" "$GIT_ATTRIBUTES_FILE"

# 查找大于 $MAX_SIZE MB 的文件并添加到 .gitattributes
find "$DIRECTORY" -type f -size +"$MAX_SIZE"M | while read -r FILE; do
    echo "$FILE filter=lfs diff=lfs merge=lfs -text" >> "$GIT_ATTRIBUTES_FILE"
    echo "已添加文件: $FILE"
done

echo "处理完成，已更新 $GIT_ATTRIBUTES_FILE。"
