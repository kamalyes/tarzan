#!/usr/bin/env bash
source ./common.sh

action=$1

function check_pod_status(){
    component=$1
    while true
    do
      kubectl get pods -n $component |grep -q '0/1'
      if [ $? -ne 0 ];then
          echo -e "${component}安装完成"
          break
      else
        echo "安装${component}进行中..."
      fi
      sleep 1
    done
}

function flannel() {
    echo -e "开始安装网络组件flannel-v${FLANNEL_VERSION}"
    if [ "$1" ];then
      FLANNEL_VERSION=$1
    fi
    del_flannel_prompt="去掉Master污点"
    read -p "是否确认${del_flannel_prompt}? [n/y]" __choice </dev/tty
    case "$__choice" in
    y | Y)
      kubectl taint nodes `hostname` node-role.kubernetes.io/master:NoSchedule- 2>/dev/null
      kubectl taint nodes `hostname` node.kubernetes.io/not-ready:NoSchedule- 2>/dev/null
    ;;
    n | N)
        log "跳过${del_flannel_prompt}..." &
        ;;
    *)
        log "跳过${del_flannel_prompt}..." &
        ;;
    esac
    docker load -i offline/docker-images/kube-flannel-v0.24.0.tar.gz
    kubectl apply -f addons/kube-flannel/${FLANNEL_VERSION}/flannel-init.yaml
    kubectl get all -n kube-flannel
    check_pod_status kube-flannel
}

function calico() {
    echo -e "开始安装网络组件calico-v${CALICO_VERSION}"
    if [ "$1" ];then
      CALICO_VERSION=$1
    fi
    kubectl apply -f addons/kube-calico/${CALICO_VERSION}/calico-init.yaml
    echo -e "网络组件flannel安装完成"
}

function dashboard() {
    echo -e "开始安装k8s-web组件Dashboard-v${DASHBOARD_VERSION}"
    if [ "$1" ];then
      DASHBOARD_VERSION=$1
    fi
    kubectl apply -f addons/kube-dashboard/$DASHBOARD_VERSION/dashboard-init.yaml
    kubectl get all -n kube-dashboard
    check_pod_status kube-dashboard
    kubectl create serviceaccount dashboard-admin -n kube-dashboard
    kubectl create clusterrolebinding dashboard-admin-rb --clusterrole=cluster-admin --serviceaccount=kube-dashboard:dashboard-admin
    ADMIN_SECRET=$(kubectl get secrets -n kube-dashboard | grep dashboard-admin | awk '{print $1}')
    kubectl -n kube-dashboard describe secret $(kubectl -n kube-dashboard get secret | grep dashboard-admin | awk '{print $1}')
    DASHBOARD_LOGIN_TOKEN=$(kubectl describe secret -n kube-dashboard ${ADMIN_SECRET} | grep -E '^token' | awk '{print $2}')
    echo ${DASHBOARD_LOGIN_TOKEN} > kube-dashboard-token.txt
    kubectl create -f dashboard-svc-account.yaml
    echo -e "\033[32m 安装完成,浏览方式: 用firefox 浏览 https://nodes-ip:30001 (要用命令查看pod-dashboard所对应的node节点),跳出不安全提示,然后高级点添加网站到安全例外"
    echo -e "\033[33m 登录token见 安装目录下token.txt "
}

function inginx() {
    echo -e "开始安装k8s-nginx组件ingress-nginx-v${INGRESS_NGINX_VERSION}"
    if [ "$1" ];then
      INGRESS_NGINX_VERSION=$1
    fi
    kubectl apply -f addons/kube-ingress-nginx/$INGRESS_NGINX_VERSION/ingress-nginx-init.yaml
    kubectl get all -n ingress-nginx
    check_pod_status ingress-nginx
    echo -e "k8s-nginx组件ingress-nginx安装完成"
}

function metrics() {
    if [ "$1" ];then
      METRICS_VERSION=$1
    fi
    if [ "$2" ];then
      STATE_METRICS_STANDARD_VERSION=$2
    fi
    echo -e "开始安装监控组件metrics-v${METRICS_VERSION}"
    kubectl apply -f addons/kube-metrics/${METRICS_VERSION}/metrics-init.yaml
    echo -e "开始安装监控组件state-metrics-standard-v${STATE_METRICS_STANDARD_VERSION}"
    kubectl apply -f addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}/cluster-role-binding.yaml
    kubectl apply -f addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}/cluster-role.yaml
    kubectl apply -f addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}/service-account.yaml
    kubectl apply -f addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}/service.yaml
    kubectl apply -f addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}/deployment.yaml
    echo -e "监控组件metrics安装完成"
}

function all(){
  flannel
  dashboard
  inginx
  metrics
}

function main_entrance() {
  case "${action}" in
  flannel)
    flannel
    FLANNEL_VERSION="0.24.0"
    echo "prepare install flannel version $(color_echo $green $FLANNEL_VERSION)"
    ;;
  calico)
    calico
    CALICO_VERSION="3.26.1"
    echo "prepare install calico version $(color_echo $green $CALICO_VERSION)"
    ;;
  dashboard)
    dashboard
    DASHBOARD_VERSION="2.7.0"
    echo "prepare install dashboard version $(color_echo $green $DASHBOARD_VERSION)"
    ;;
  inginx)
    inginx
    INGINX_NGINX_VERSION="1.9.5"
    echo "prepare install inginx version $(color_echo $green $INGINX_NGINX_VERSION)"
    ;;
  metrics)
    metrics
    METRICS_VERSION="0.6.4"
    STATE_METRICS_STANDARD_VERSION="2.10.0"
    echo "prepare install metrics version $(color_echo $green $METRICS_VERSION) and state-metrics-standard version $(color_echo $green $STATE_METRICS_STANDARD_VERSION) "
    ;;
  all)
    all
    ;;
  esac
}
main_entrance $@