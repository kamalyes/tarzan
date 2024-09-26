#!/usr/bin/env bash
source ./common.sh

action=$1

function check_pod_status() {
    component=$1
    while true; do
        if kubectl get pods -n "$component" | grep -q '0/1'; then
            log "安装${component}进行中..."
        else
            log "${component}安装完成"
            break
        fi
        sleep 1
    done
}

function taint() {
    KUBE_NODE_NAME=${1:-$KUBE_NODE_NAME}
    taint_prompt="去掉Master污点"
    read -p "是否确认${taint_prompt}? [n/y] " __choice </dev/tty
    case "$__choice" in
        y | Y)
            run_command "kubectl taint nodes $KUBE_NODE_NAME node-role.kubernetes.io/master:NoSchedule- 2>/dev/null"
            run_command "kubectl taint nodes $KUBE_NODE_NAME node.kubernetes.io/not-ready:NoSchedule- 2>/dev/null"
            ;;
        n | N | *)
            color_echo ${yellow} "跳过${taint_prompt}..."
            ;;
    esac
}

function install_component() {
    local component_name=$1
    local version=$2
    local yaml_file=$3

    log "开始安装组件 ${component_name}-v${version}"
    run_command "kubectl apply -f ${yaml_file}"
    kubectl get all -n "$component_name"
    check_pod_status "$component_name"
}

function dashboard() {
    local DASHBOARD_VERSION=$1
    log "开始安装k8s-web组件 Dashboard-v$DASHBOARD_VERSION"
    result=$(generate_self_signed_cert "$KUBE_DASHBOARD_TLS_KEY_FILE" "$KUBE_DASHBOARD_TLS_CSR_FILE" "$KUBE_DASHBOARD_TLS_CRT_FILE" "$COMMON_NAME")
    # 将结果分割为证书和私钥
    IFS=' ' read -r base64_encoded_cert base64_encoded_key <<< "$result"
    find addons -name "*.yaml" -exec sed -i.bak 's|{{KUBE_DASHBOARD_BASE64_ENCODED_CERT}}|'"$base64_encoded_cert"'|g' {} \;
    find addons -name "*.yaml" -exec sed -i.bak 's|{{KUBE_DASHBOARD_BASE64_ENCODED_KEY}}|'"$base64_encoded_key"'|g' {} \;

    install_component "kube-dashboard" "$DASHBOARD_VERSION" "addons/kube-dashboard/$DASHBOARD_VERSION"

    kubectl create serviceaccount dashboard-admin -n kube-dashboard
    kubectl create clusterrolebinding dashboard-admin-rb --clusterrole=cluster-admin --serviceaccount=kube-dashboard:dashboard-admin
    
    local ADMIN_SECRET=$(kubectl get secrets -n kube-dashboard | grep dashboard-admin | awk '{print $1}')
    kubectl -n kube-dashboard describe secret "$ADMIN_SECRET"
    local DASHBOARD_LOGIN_TOKEN=$(kubectl describe secret -n kube-dashboard "${ADMIN_SECRET}" | grep -E '^token' | awk '{print $2}')
    echo "${DASHBOARD_LOGIN_TOKEN}" > kubernetes-dashboard-token.txt
    log "登录token见 安装目录下token.txt"
}

function main_entrance() {
    case "${action}" in
        flannel)
            FLANNEL_VERSION=$2
            if [ -z "$FLANNEL_VERSION" ]; then
                log "请提供 flannel 版本号"
                exit 1
            fi
            log "准备安装 flannel 版本 $FLANNEL_VERSION"
            install_component "kube-flannel" "$FLANNEL_VERSION" "addons/kube-flannel/${FLANNEL_VERSION}/flannel-init.yaml"
            ;;
        calico)
            CALICO_VERSION=$2
            if [ -z "$CALICO_VERSION" ]; then
                log "请提供 calico 版本号"
                exit 1
            fi
            log "准备安装 calico 版本 $CALICO_VERSION"
            install_component "kube-calico" "$CALICO_VERSION" "addons/kube-calico/${CALICO_VERSION}/calico-init.yaml"
            ;;
        dashboard)
            DASHBOARD_VERSION=$2
            if [ -z "$DASHBOARD_VERSION" ]; then
                log "请提供 dashboard 版本号"
                exit 1
            fi
            log "准备安装 dashboard 版本 $DASHBOARD_VERSION"
            dashboard $DASHBOARD_VERSION
            ;;
        ingress-nginx)
            INGRESS_NGINX_VERSION=$2
            if [ -z "$INGRESS_NGINX_VERSION" ]; then
                log "请提供 ingress-nginx 版本号"
                exit 1
            fi
            log "准备安装 ingress-nginx 版本 $INGRESS_NGINX_VERSION"
            install_component "ingress-nginx" "$INGRESS_NGINX_VERSION" "addons/kube-ingress-nginx/$INGRESS_NGINX_VERSION/ingress-nginx-init.yaml"
            ;;
        metrics)
            METRICS_VERSION=$2
            STATE_METRICS_STANDARD_VERSION=$3
            if [ -z "$METRICS_VERSION" ] || [ -z "$STATE_METRICS_STANDARD_VERSION" ]; then
                log "请提供 metrics 和 state-metrics-standard 版本号"
                exit 1
            fi
            log "准备安装 metrics 版本 $METRICS_VERSION 和 state-metrics-standard 版本 $STATE_METRICS_STANDARD_VERSION"
            install_component "metrics" "$METRICS_VERSION" "addons/kube-metrics/${METRICS_VERSION}/metrics-init.yaml"
            install_component "kube-state-metrics" "$STATE_METRICS_STANDARD_VERSION" "addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}"
            ;;
        taint)
            KUBE_NODE_NAME=$2
            if [ -z "$KUBE_NODE_NAME" ]; then
                log "请提供 KUBE_NODE_NAME"
                exit 1
            fi
            taint "$KUBE_NODE_NAME"
            ;;
        all)
            FLANNEL_VERSION=$2
            CALICO_VERSION=$3
            DASHBOARD_VERSION=$4
            INGRESS_NGINX_VERSION=$5
            METRICS_VERSION=$6
            STATE_METRICS_STANDARD_VERSION=$7
            # 检查所有版本参数是否提供
            if [ -z "$FLANNEL_VERSION" ] || [ -z "$CALICO_VERSION" ] || [ -z "$DASHBOARD_VERSION" ] || \
               [ -z "$INGRESS_NGINX_VERSION" ] || [ -z "$METRICS_VERSION" ] || [ -z "$STATE_METRICS_STANDARD_VERSION" ]; then
                log "请提供所有组件的版本号: flannel, calico, dashboard, ingress-nginx, metrics, state-metrics-standard"
                exit 1
            fi
            
            log "准备安装所有组件..."
            install_component "kube-flannel" "$FLANNEL_VERSION" "addons/kube-flannel/${FLANNEL_VERSION}/flannel-init.yaml"
            install_component "kube-calico" "$CALICO_VERSION" "addons/kube-calico/${CALICO_VERSION}/calico-init.yaml"
            dashboard $DASHBOARD_VERSION
            install_component "ingress-nginx" "$INGRESS_NGINX_VERSION" "addons/kube-ingress-nginx/$INGRESS_NGINX_VERSION/ingress-nginx-init.yaml"
            install_component "metrics" "$METRICS_VERSION" "addons/kube-metrics/${METRICS_VERSION}/metrics-init.yaml"
            install_component "kube-state-metrics" "$STATE_METRICS_STANDARD_VERSION" "addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}"
            ;;
    esac
}

main_entrance "$@"
