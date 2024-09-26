#!/usr/bin/env bash
source ./common.sh

# 创建证书目录（如果尚不存在）
mkdir -p "$OPENSSL_CERT_DIR"

if ! openssl genrsa -out "$OPENSSL_KEY_PATH" 2048; then
    color_echo ${red} "Error generating private key."
    exit 1
fi

# 生成自签名证书
if ! openssl req -new -x509 -days "$OPENSSL_DAYS" -key "$OPENSSL_KEY_PATH" \
    -out "$OPENSSL_CRT_PATH" \
    -subj "/C=$OPENSSL_COUNTRY/ST=$OPENSSL_STATE/L=$OPENSSL_CITY/O=$OPENSSL_ORGANIZATION/OU=$OPENSSL_ORGANIZATIONAL_UNIT/CN=$OPENSSL_COMMON_NAME/emailAddress=$OPENSSL_EMAIL"; then
    color_echo ${red} "Error generating self-signed certificate."
    exit 1
fi

# 输出证书创建成功的消息，并显示证书路径
log "SSL Certificate created at: $OPENSSL_CRT_PATH"
