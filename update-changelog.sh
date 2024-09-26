#!/bin/bash

# 定义 changelog 文件
CHANGELOG_FILE="CHANGELOG.md"

# 获取当前日期
CURRENT_DATE=$(date +"%Y-%m-%d")

# 获取最近的提交信息
COMMIT_LOG=$(git log --pretty=format:"- **%h**: %s" --abbrev-commit)

# 检查 CHANGELOG.md 文件是否存在，如果不存在则创建
if [ ! -f "$CHANGELOG_FILE" ]; then
    echo "# 变更日志" > "$CHANGELOG_FILE"
    echo >> "$CHANGELOG_FILE"
fi

# 检查是否已经存在相同的信息
EXISTING_ENTRIES=$(grep -F "$CURRENT_DATE" "$CHANGELOG_FILE")

# 如果没有相同的日期条目，则添加新的条目
if [[ -z "$EXISTING_ENTRIES" ]]; then
    {
        echo "#### [$CURRENT_DATE]"
        echo "$COMMIT_LOG"
        echo
    } >> "$CHANGELOG_FILE"
    echo "变更日志已更新到 $CHANGELOG_FILE"
else
    echo "变更日志中已存在相同日期的信息，未进行更新。"
fi

