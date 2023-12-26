#!/bin/bash
action=$1

NameSpace="default"

function flannel() {
    FLANNEL_VERSION="0.24.0"
    echo -e "开始安装网络组件flannel-v${FLANNEL_VERSION}"
    if [ "$1" ];then
      FLANNEL_VERSION=$1
    fi
    kubectl apply -f addons/kube-flannel/${FLANNEL_VERSION}/flannel-init.yaml
    echo -e "网络组件flannel安装完成"
}

function dashboard() {
    DASHBOARD_VERSION="2.7.0"
    echo -e "开始安装k8s-web组件Dashboard-v${DASHBOARD_VERSION}"
    if [ "$1" ];then
      DASHBOARD_VERSION=$1
    fi
    kubectl apply -f addons/kube-dashboard/$DASHBOARD_VERSION/dashboard-init.yaml
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
    INGINX_NGINX_VERSION="1.9.5"
    echo -e "开始安装k8s-nginx组件ingress-nginx-v${INGINX_NGINX_VERSION}"
    if [ "$1" ];then
      INGINX_NGINX_VERSION=$1
    fi
    kubectl apply -f addons/kube-ingress-nginx/$INGINX_NGINX_VERSION/ingress-nginx-init.yaml
    echo -e "k8s-nginx组件ingress-nginx安装完成"
}

function metrics() {
    METRICS_VERSION="0.6.4"
    STATE_METRICS_STANDARD_VERSION="2.10.0"
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
    ;;
  dashboard)
    dashboard
    ;;
  inginx)
    inginx
    ;;
  metrics)
    metrics
    ;;
  all)
    all
    ;;
  esac
}
main_entrance $@