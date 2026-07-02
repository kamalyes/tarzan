#!/usr/bin/env bash
source ./common.sh

# addons 安装器: 只保留各组件的业务编排
# 渲染副本/占位符替换/镜像预拉取/应用等通用机制统一在 common.sh 的 install_rendered

action=$1

function taint() {
    KUBE_NODE_NAME=${1:-$KUBE_NODE_NAME}
    taint_prompt="去掉Master污点"
    if prompt_for_confirmation "" "$taint_prompt"; then
        # 幂等去除污点(污点不存在时 kubectl 报错属正常, 不阻塞)
        run_command "kubectl taint nodes $KUBE_NODE_NAME node-role.kubernetes.io/master:NoSchedule- 2>/dev/null || true"
        run_command "kubectl taint nodes $KUBE_NODE_NAME node.kubernetes.io/not-ready:NoSchedule- 2>/dev/null || true"
    else
        color_echo ${yellow} "跳过${taint_prompt}..."
    fi
}

# addons 组件薄封装: install_rendered 通用机制 + 命名空间资源展示与就绪检测
function install_component() {
    local component_name=$1
    local version=$2
    local yaml_file=$3
    # 第4参数为清单实际所在命名空间(缺省以组件名推断, 如 metrics/descheduler 在 kube-system)
    local namespace=${4:-$component_name}
    install_rendered "${component_name}-v${version}" \
        "$TARZAN_ADDONS_PATH/.rendered-${component_name}.yaml" "$yaml_file"
    kubectl get all -n "$namespace"
    check_pod_status "$namespace"
}

function dashboard() {
    local DASHBOARD_VERSION=$1
    log "开始安装k8s-web组件 Dashboard-v$DASHBOARD_VERSION"
    install_component "kube-dashboard" "$DASHBOARD_VERSION" "addons/kube-dashboard/$DASHBOARD_VERSION"

    # 幂等创建登录凭据(重复执行不报 AlreadyExists)
    run_command "kubectl create serviceaccount dashboard-admin -n kube-dashboard --dry-run=client -o yaml | kubectl apply -f -"
    run_command "kubectl create clusterrolebinding dashboard-admin-rb --clusterrole=cluster-admin --serviceaccount=kube-dashboard:dashboard-admin --dry-run=client -o yaml | kubectl apply -f -"

    local ADMIN_SECRET=$(kubectl get secrets -n kube-dashboard | grep dashboard-admin | awk '{print $1}')
    kubectl -n kube-dashboard describe secret "$ADMIN_SECRET"
    local DASHBOARD_LOGIN_TOKEN=$(kubectl describe secret -n kube-dashboard "${ADMIN_SECRET}" | grep -E '^token' | awk '{print $2}')
    echo "${DASHBOARD_LOGIN_TOKEN}" > kubernetes-dashboard-token.txt
    log "登录token见 安装目录下kubernetes-dashboard-token.txt"
}

function cert_manager() {
    # 清单已入仓: 1.23 集群用兼容版, 1.28+ 集群用新版(环境前缀将档位版本传入占位符替换)
    local version
    version=$(legacy_or_modern "$CERT_MANAGER_LEGACY_VERSION" "$CERT_MANAGER_VERSION")
    CERT_MANAGER_VERSION="$version" install_component "cert-manager" "$version" \
        "$TARZAN_ADDONS_PATH/kube-cert-manager/$version/cert-manager.yaml"
}

function traefik() {
    check_ingress_exclusive traefik nginx
    # deployment 形态的 acme PVC 依赖存储类(前置检测, 与 components 统一)
    if [[ $TRAEFIK_DEPLOY_MODE == "deployment" ]]; then
        check_storage_class
    fi
    local dir="$TARZAN_ADDONS_PATH/kube-traefik"
    # CRD 清单已入仓(traefik 3.x 对 1.23/1.28 双档共用一份), 先注册 CRD 再装主体(与主体一致走渲染副本, 不直接 apply 模板原件)
    install_rendered "traefik-crd" "$TARZAN_ADDONS_PATH/.rendered-traefik-crd.yaml" "$dir/crd-definition-v1.yml"
    # 基础清单按部署形态(deployment/daemonset)渲染
    install_rendered "traefik-${TRAEFIK_DEPLOY_MODE}" "$TARZAN_ADDONS_PATH/.rendered-traefik.yaml" \
        "$dir/namespace.yaml" "$dir/rbac.yaml" "$dir/$TRAEFIK_DEPLOY_MODE.yaml" "$dir/service.yaml" "$dir/ingressclass.yaml"
    kubectl get all -n ingress
}

function openobserve() {
    if ! kubectl get secret "$MONITORING_SECRETS" -n "$MONITORING_NAMESPACE" &>/dev/null; then
        color_echo ${red} "请先执行 install-components.sh secrets 生成监控密钥"
        exit 1
    fi
    # 数据卷依赖存储类(前置检测, 与 components 统一)
    check_storage_class
    local dir="$TARZAN_ADDONS_PATH/kube-openobserve"
    install_rendered "openobserve" "$TARZAN_ADDONS_PATH/.rendered-openobserve.yaml" \
        "$dir"/namespace.yaml "$dir"/statefulset.yaml "$dir"/service.yaml "$dir"/service-nodeport.yaml
    kubectl get all -n monitoring
}

function otel() {
    local dir="$TARZAN_ADDONS_PATH/kube-otel"
    # operator 清单已入仓: 1.23 集群用兼容版, 1.28+ 集群用新版(环境前缀将档位版本传入占位符替换)
    local version
    version=$(legacy_or_modern "$OTEL_OPERATOR_LEGACY_VERSION" "$OTEL_OPERATOR_VERSION")
    OTEL_OPERATOR_VERSION="$version" install_rendered "otel-operator-v${version}" \
        "$TARZAN_ADDONS_PATH/.rendered-otel-operator.yaml" \
        "$dir/$version/opentelemetry-operator.yaml"
    # 等待 operator 的 CRD 完成注册(对齐 longhorn 的 kubectl wait 模式, 带超时上限)
    run_command "kubectl wait --for=condition=Established crd/opentelemetrycollectors.opentelemetry.io --timeout=120s"
    # 采集器所在命名空间先行
    run_command "kubectl create namespace $OTEL_BUSINESS_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"
    run_command "kubectl create namespace $OTEL_OPENAPI_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"
    local collector
    for collector in business-otel.yml openapi-otel.yml; do
        install_rendered "otel-collector-${collector%.yml}" \
            "$TARZAN_ADDONS_PATH/.rendered-${collector%.yml}.yaml" "$dir/$collector"
    done
}

function longhorn() {
    local dir="$TARZAN_ADDONS_PATH/kube-longhorn"
    # install 清单已入仓: 1.23 集群用兼容版, 1.28+ 集群用新版; settings 覆盖默认副本数
    local version
    version=$(legacy_or_modern "$LONGHORN_LEGACY_VERSION" "$LONGHORN_VERSION")
    # 主体(CRD+控制器)与 settings 分两步装: Setting 是 CRD 自定义资源, 与 CRD 同批 apply 时类型尚未注册进集群,
    # kubectl 无法识别(对齐 traefik/otel 的 "CRD 先行等待注册" 模式)
    LONGHORN_VERSION="$version" install_rendered "longhorn-v${version}" \
        "$TARZAN_ADDONS_PATH/.rendered-longhorn.yaml" \
        "$dir/$version/install.yaml"
    run_command "kubectl wait --for=condition=Established crd/settings.longhorn.io --timeout=120s"
    install_rendered "longhorn-settings" \
        "$TARZAN_ADDONS_PATH/.rendered-longhorn-settings.yaml" \
        "$dir/settings.yaml"
    kubectl get all -n longhorn-system
    check_pod_status longhorn-system
}

function main_entrance() {
    case "${action}" in
        flannel)
            # 版本缺省取 variables.sh 默认值
            FLANNEL_VERSION=${2:-$FLANNEL_VERSION}
            install_component "kube-flannel" "$FLANNEL_VERSION" "addons/kube-flannel/${FLANNEL_VERSION}/flannel-init.yaml"
            ;;
        calico)
            CALICO_VERSION=${2:-$CALICO_VERSION}
            install_component "kube-calico" "$CALICO_VERSION" "addons/kube-calico/${CALICO_VERSION}/calico-init.yaml"
            ;;
        descheduler)
            DESCHEDULER_VERSION=${2:-$DESCHEDULER_VERSION}
            install_component "kube-descheduler" "$DESCHEDULER_VERSION" "addons/kube-descheduler/${DESCHEDULER_VERSION}" kube-system
            ;;
        dashboard)
            DASHBOARD_VERSION=${2:-$DASHBOARD_VERSION}
            dashboard $DASHBOARD_VERSION
            ;;
        ingress-nginx)
            INGRESS_NGINX_VERSION=${2:-$INGRESS_NGINX_VERSION}
            check_ingress_exclusive nginx traefik
            install_component "ingress-nginx" "$INGRESS_NGINX_VERSION" "addons/kube-ingress-nginx/$INGRESS_NGINX_VERSION/ingress-nginx-init.yaml"
            ;;
        metrics)
            METRICS_VERSION=${2:-$METRICS_VERSION}
            STATE_METRICS_STANDARD_VERSION=${3:-$STATE_METRICS_STANDARD_VERSION}
            install_component "metrics" "$METRICS_VERSION" "addons/kube-metrics/${METRICS_VERSION}/metrics-init.yaml" kube-system
            install_component "kube-state-metrics" "$STATE_METRICS_STANDARD_VERSION" "addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}" kube-system
            ;;
        taint)
            KUBE_NODE_NAME=$2
            if [ -z "$KUBE_NODE_NAME" ]; then
                log "请提供 KUBE_NODE_NAME"
                exit 1
            fi
            taint "$KUBE_NODE_NAME"
            ;;
        cert-manager)
            cert_manager
            ;;
        traefik)
            traefik
            ;;
        openobserve)
            openobserve
            ;;
        otel)
            otel
            ;;
        longhorn)
            longhorn
            ;;
        all)
            FLANNEL_VERSION=${2:-$FLANNEL_VERSION}
            CALICO_VERSION=${3:-$CALICO_VERSION}
            DASHBOARD_VERSION=${4:-$DASHBOARD_VERSION}
            INGRESS_NGINX_VERSION=${5:-$INGRESS_NGINX_VERSION}
            METRICS_VERSION=${6:-$METRICS_VERSION}
            STATE_METRICS_STANDARD_VERSION=${7:-$STATE_METRICS_STANDARD_VERSION}
            log "准备安装所有组件..."
            # CNI 跟随 KUBE_NETWORK 二选一(两套 CNI 共存会冲突)
            if [[ $KUBE_NETWORK == "calico" ]]; then
                install_component "kube-calico" "$CALICO_VERSION" "addons/kube-calico/${CALICO_VERSION}/calico-init.yaml"
            else
                install_component "kube-flannel" "$FLANNEL_VERSION" "addons/kube-flannel/${FLANNEL_VERSION}/flannel-init.yaml"
            fi
            dashboard $DASHBOARD_VERSION
            check_ingress_exclusive nginx traefik
            install_component "ingress-nginx" "$INGRESS_NGINX_VERSION" "addons/kube-ingress-nginx/$INGRESS_NGINX_VERSION/ingress-nginx-init.yaml"
            install_component "metrics" "$METRICS_VERSION" "addons/kube-metrics/${METRICS_VERSION}/metrics-init.yaml" kube-system
            install_component "kube-state-metrics" "$STATE_METRICS_STANDARD_VERSION" "addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}" kube-system
            ;;
        *)
            echo "Usage: $0 {flannel|calico|dashboard|ingress-nginx|metrics|descheduler|traefik|cert-manager|openobserve|otel|longhorn|taint|all}"
            exit 1
            ;;
    esac
}

main_entrance "$@"
