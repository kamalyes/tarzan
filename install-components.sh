#!/usr/bin/env bash
source ./common.sh

# 业务组件安装器: 模板治理(components/<name>/*.yaml 带{{}}占位符) + 安装时渲染
# 机制对齐 conf/kubeadm-init-template.yaml -> kubeadm-init.yaml 的既有方式,
# 动态量(路由/join列表/副本数)由变量计算后统一替换, 不维护任何写死的副本清单
# 渲染副本/占位符替换/镜像预拉取/应用等通用机制统一在 common.sh 的 install_rendered

action=$1

# 渲染组件模板(components/<name>/*.yaml)为单清单文件并安装
function render_and_apply() {
    local component=$1
    local rendered=$2
    install_rendered "$component" "$TARZAN_COMPONENTS_PATH/${rendered}.yaml" "$TARZAN_COMPONENTS_PATH/${component}"
    kubectl get all -n "$COMPONENT_NAMESPACE"
}

# 按密钥模板生成 env(空值自动 openssl rand -hex 24, 固定值直接填写), 幂等合并新增key
function generate_secrets_env() {
    if [ ! -f "$COMPONENT_SECRETS_TEMPLATE_FILE" ]; then
        color_echo ${red} "密钥模板 $COMPONENT_SECRETS_TEMPLATE_FILE 不存在"
        exit 1
    fi
    touch "$COMPONENT_SECRETS_ENV_FILE"
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        if grep -q "^${key}=" "$COMPONENT_SECRETS_ENV_FILE"; then
            continue
        fi
        [ -z "$value" ] && value=$(openssl rand -hex 24)
        echo "${key}=${value}" >> "$COMPONENT_SECRETS_ENV_FILE"
        log "生成密钥 ${key}"
    done < "$COMPONENT_SECRETS_TEMPLATE_FILE"
    chmod 600 "$COMPONENT_SECRETS_ENV_FILE"
}

function install_namespace() {
    render_and_apply namespace namespace
    run_command "kubectl get namespace $COMPONENT_NAMESPACE"
}

function install_secrets() {
    generate_secrets_env
    # 命名空间先行(单独执行 secrets 时, secret 依赖命名空间已存在)
    run_command "kubectl create namespace $MONITORING_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"
    run_command "kubectl create namespace $COMPONENT_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"
    # 业务组件密钥(排除监控前缀)
    grep -v '^OPENOBSERVE_' "$COMPONENT_SECRETS_ENV_FILE" > "$TARZAN_COMPONENTS_PATH/.components.env"
    run_command "kubectl create secret generic $COMPONENT_SECRETS --from-env-file=$TARZAN_COMPONENTS_PATH/.components.env -n $COMPONENT_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"
    # 监控组件密钥(OPENOBSERVE_ 前缀)
    grep '^OPENOBSERVE_' "$COMPONENT_SECRETS_ENV_FILE" > "$TARZAN_COMPONENTS_PATH/.monitoring.env"
    run_command "kubectl create secret generic $MONITORING_SECRETS --from-env-file=$TARZAN_COMPONENTS_PATH/.monitoring.env -n $MONITORING_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"
    rm -f "$TARZAN_COMPONENTS_PATH/.components.env" "$TARZAN_COMPONENTS_PATH/.monitoring.env"
    log "密钥 $COMPONENT_SECRETS / $MONITORING_SECRETS 已同步到集群"
}

# 生成 CockroachDB 证书(CA 10年 / 节点+client.root 5年, SAN 含集群FQDN与外部域名)
function generate_cockroachdb_certs() {
    if [ -f "$COCKROACHDB_CERTS_PATH/node.crt" ]; then
        color_echo ${fuchsia} "CockroachDB 证书已存在, 跳过生成"
        return 0
    fi
    mkdir -p "$COCKROACHDB_CERTS_PATH"
    local ns=$COMPONENT_NAMESPACE
    local san="DNS:localhost"
    for svc in cockroachdb cockroachdb-public; do
        san="${san},DNS:${svc},DNS:${svc}.${ns},DNS:${svc}.${ns}.svc,DNS:${svc}.${ns}.svc.cluster.local"
    done
    san="${san},DNS:*.cockroachdb.${ns}.svc.cluster.local,DNS:${COCKROACHDB_EXTERNAL_DOMAIN},IP:127.0.0.1,IP:${COCKROACHDB_PUBLIC_IP}"
    echo "subjectAltName=${san}" > "$COCKROACHDB_CERTS_PATH/node.ext"

    run_command "openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/O=Cockroach/CN=Cockroach CA' -keyout $COCKROACHDB_CERTS_PATH/ca.key -out $COCKROACHDB_CERTS_PATH/ca.crt"
    run_command "openssl req -newkey rsa:2048 -nodes -subj '/O=Cockroach/CN=node' -keyout $COCKROACHDB_CERTS_PATH/node.key -out $COCKROACHDB_CERTS_PATH/node.csr"
    run_command "openssl x509 -req -in $COCKROACHDB_CERTS_PATH/node.csr -CA $COCKROACHDB_CERTS_PATH/ca.crt -CAkey $COCKROACHDB_CERTS_PATH/ca.key -CAcreateserial -days 1825 -extfile $COCKROACHDB_CERTS_PATH/node.ext -out $COCKROACHDB_CERTS_PATH/node.crt"
    run_command "openssl req -newkey rsa:2048 -nodes -subj '/CN=root' -keyout $COCKROACHDB_CERTS_PATH/client.root.key -out $COCKROACHDB_CERTS_PATH/client.root.csr"
    run_command "openssl x509 -req -in $COCKROACHDB_CERTS_PATH/client.root.csr -CA $COCKROACHDB_CERTS_PATH/ca.crt -CAkey $COCKROACHDB_CERTS_PATH/ca.key -CAcreateserial -days 1825 -out $COCKROACHDB_CERTS_PATH/client.root.crt"
    rm -f "$COCKROACHDB_CERTS_PATH"/*.csr "$COCKROACHDB_CERTS_PATH"/*.srl "$COCKROACHDB_CERTS_PATH/node.ext"
}

function install_cockroachdb() {
    generate_cockroachdb_certs
    # 显式列出进 secret 的证书文件(CA 私钥 ca.key 留在 master 本地, 不进集群)
    run_command "kubectl create secret generic cockroachdb-certs \
        --from-file=ca.crt=$COCKROACHDB_CERTS_PATH/ca.crt \
        --from-file=node.crt=$COCKROACHDB_CERTS_PATH/node.crt \
        --from-file=node.key=$COCKROACHDB_CERTS_PATH/node.key \
        --from-file=client.root.crt=$COCKROACHDB_CERTS_PATH/client.root.crt \
        --from-file=client.root.key=$COCKROACHDB_CERTS_PATH/client.root.key \
        -n $COMPONENT_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"
    render_and_apply cockroachdb cockroachdb
    check_pod_status "$COMPONENT_NAMESPACE"
}

function install_clickhouse() {
    render_and_apply clickhouse clickhouse
    check_pod_status "$COMPONENT_NAMESPACE"
}

function install_nats() {
    render_and_apply nats nats
    check_pod_status "$COMPONENT_NAMESPACE"
}

# 单实例 Valkey: default 与 wallet 共用同一模板, 仅名称/密钥key/nodeport不同(环境前缀注入)
function install_valkey() {
    local name=$1
    local password_key=$2
    local nodeport=$3
    VALKEY_NAME="$name" VALKEY_PASSWORD_KEY="$password_key" VALKEY_NODEPORT="$nodeport" \
        install_rendered "valkey-${name}" \
            "$TARZAN_COMPONENTS_PATH/valkey-${name}.yaml" "$TARZAN_COMPONENTS_PATH/valkey"
    kubectl get all -n "$COMPONENT_NAMESPACE"
    check_pod_status "$COMPONENT_NAMESPACE"
}

# Valkey Cluster 模式(3主3从, 自动建群 + nodes.conf 旧IP自愈)
function install_valkey_cluster() {
    render_and_apply valkey-cluster valkey-wallet-cluster
    check_pod_status "$COMPONENT_NAMESPACE"
}

function main_entrance() {
    # 有状态组件的 PVC 依赖存储类(单组件与 all 统一前置检测, 缺失时提示先装 longhorn)
    case "${action}" in
        clickhouse|cockroachdb|nats|valkey|valkey-wallet|valkey-cluster|all)
            check_storage_class
            ;;
    esac
    case "${action}" in
        namespace)
            install_namespace
            ;;
        secrets)
            install_secrets
            ;;
        clickhouse)
            install_clickhouse
            ;;
        cockroachdb)
            install_cockroachdb
            ;;
        nats)
            install_nats
            ;;
        valkey)
            install_valkey default VALKEY_DEFAULT_PASSWORD 30014
            ;;
        valkey-wallet)
            install_valkey wallet VALKEY_WALLET_PASSWORD 30015
            ;;
        valkey-cluster)
            install_valkey_cluster
            ;;
        all)
            log "准备安装所有业务组件..."
            install_namespace
            install_secrets
            install_valkey default VALKEY_DEFAULT_PASSWORD 30014
            install_valkey wallet VALKEY_WALLET_PASSWORD 30015
            install_valkey_cluster
            install_clickhouse
            install_nats
            install_cockroachdb
            ;;
        *)
            echo "Usage: $0 {namespace|secrets|clickhouse|cockroachdb|nats|valkey|valkey-wallet|valkey-cluster|all}"
            exit 1
            ;;
    esac
}

main_entrance "$@"
