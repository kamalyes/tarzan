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
    log "开始安装k8s-web组件 Dashboard-v${DASHBOARD_VERSION}"
    install_component "kube-dashboard" "$DASHBOARD_VERSION" "addons/kube-dashboard/$DASHBOARD_VERSION/dashboard-init.yaml"
    
    kubectl create serviceaccount dashboard-admin -n kube-dashboard
    kubectl create clusterrolebinding dashboard-admin-rb --clusterrole=cluster-admin --serviceaccount=kube-dashboard:dashboard-admin
    
    ADMIN_SECRET=$(kubectl get secrets -n kube-dashboard | grep dashboard-admin | awk '{print $1}')
    kubectl -n kube-dashboard describe secret "$ADMIN_SECRET"
    DASHBOARD_LOGIN_TOKEN=$(kubectl describe secret -n kube-dashboard "${ADMIN_SECRET}" | grep -E '^token' | awk '{print $2}')
    echo "${DASHBOARD_LOGIN_TOKEN}" > kube-dashboard-token.txt
    
    log "安装完成,浏览方式: 用firefox 浏览 https://nodes-ip:30001 (要用命令查看pod-dashboard所对应的node节点),跳出不安全提示,然后高级点添加网站到安全例外"
    log "登录token见 安装目录下token.txt"
}

function all() {
    install_component "kube-flannel" "$FLANNEL_VERSION" "addons/kube-flannel/${FLANNEL_VERSION}/flannel-init.yaml"
    dashboard
    install_component "ingress-nginx" "$INGRESS_NGINX_VERSION" "addons/kube-ingress-nginx/$INGRESS_NGINX_VERSION/ingress-nginx-init.yaml"
    install_component "metrics" "$METRICS_VERSION" "addons/kube-metrics/${METRICS_VERSION}/metrics-init.yaml"
    install_component "kube-state-metrics-standard" "$STATE_METRICS_STANDARD_VERSION" "addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}/deployment.yaml"
}

function main_entrance() {
    case "${action}" in
        flannel)
            FLANNEL_VERSION=$2
            log "准备安装 flannel 版本 $FLANNEL_VERSION"
            install_component "kube-flannel" "$FLANNEL_VERSION" "addons/kube-flannel/${FLANNEL_VERSION}/flannel-init.yaml"
            ;;
        calico)
            CALICO_VERSION=$2
            log "准备安装 calico 版本 $CALICO_VERSION"
            install_component "kube-calico" "$CALICO_VERSION" "addons/kube-calico/${CALICO_VERSION}/calico-init.yaml"
            ;;
        dashboard)
            DASHBOARD_VERSION=$2
            log "准备安装 dashboard 版本 $DASHBOARD_VERSION"
            dashboard
            ;;
        inginx)
            INGINX_NGINX_VERSION=$2
            log "准备安装 inginx 版本 $INGINX_NGINX_VERSION"
            install_component "ingress-nginx" "$INGRESS_NGINX_VERSION" "addons/kube-ingress-nginx/$INGRESS_NGINX_VERSION/ingress-nginx-init.yaml"
            ;;
        metrics)
            METRICS_VERSION=$2
            STATE_METRICS_STANDARD_VERSION=$3
            log "准备安装 metrics 版本 $METRICS_VERSION 和 state-metrics-standard 版本 $STATE_METRICS_STANDARD_VERSION"
            all
            ;;
        taint)
            KUBE_NODE_NAME=$2
            taint "$KUBE_NODE_NAME"
            ;;
        all)
            all
            ;;
        *)
            log "无效的操作: $action"
            exit 1
            ;;
    esac
}

main_entrance "$@"
