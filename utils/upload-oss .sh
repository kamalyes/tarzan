#!/usr/bin/env bash

# 目录路径
DIRECTORY="/root/docker-images-backup"

# 函数：上传单个文件
upload_file() {
    local FILE_PATH=$1
    local FILE_NAME=$(basename "$FILE_PATH")
        
    # OSS 凭据和终端
    ACCESS_KEY_ID=$2
    ACCESS_KEY_SECRET=$3
    ENDPOINT=$4
    BUCKET_NAME=$5

    echo "Uploading file: $FILE_NAME from path: $FILE_PATH"

    # 资源标识
    RESOURCE="/${BUCKET_NAME}/docker-images-backup/${FILE_NAME}"
    CONTENT_TYPE="application/octet-stream"
    DATE_VALUE="$(date -u +"%a, %d %b %Y %H:%M:%S GMT")"
    STRING_TO_SIGN="PUT\n\n${CONTENT_TYPE}\n${DATE_VALUE}\n${RESOURCE}"
    SIGNATURE=$(echo -en "$STRING_TO_SIGN" | openssl sha1 -hmac "$ACCESS_KEY_SECRET" -binary | base64)

    # 上传文件
    HTTP_RESPONSE=$(curl -w "%{http_code}" -X PUT -T "$FILE_PATH" \
      -H "Host: ${BUCKET_NAME}.${ENDPOINT}" \
      -H "Date: ${DATE_VALUE}" \
      -H "Content-Type: ${CONTENT_TYPE}" \
      -H "Authorization: OSS ${ACCESS_KEY_ID}:${SIGNATURE}" \
      "http://${BUCKET_NAME}.${ENDPOINT}/docker-images-backup/${FILE_NAME}")

    if [[ "$HTTP_RESPONSE" -eq 200 ]]; then
		echo "Upload of $FILE_NAME successful"
	else
		echo "Upload of $FILE_NAME failed"
		# 在这里添加错误处理逻辑，比如重试或记录错误信息
	fi
}

# 遍历指定目录下的所有文件
for FILE_PATH in $DIRECTORY/*; do
    if [ -f "$FILE_PATH" ]; then
        upload_file "$FILE_PATH"
    fi
done
