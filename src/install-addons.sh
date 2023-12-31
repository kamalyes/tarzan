#!/usr/bin/env bash
source ./common.sh

action=$1

NameSpace="default"

function check_pod_status(){
    component=$1
    while true
    do
      kubectl get pods -n $component |grep -q '0/1'
      if [ $? -ne 0 ];then
        log "${component}安装完成"
        break
      else
        log "安装${component}进行中..."
      fi
      sleep 1
    done
}

function del_no_schedule() {
  del_no_schedule_prompt="去掉Master污点"
  read -p "是否确认${del_no_schedule_prompt}? [n/y]" __choice </dev/tty
  case "$__choice" in
  y | Y)
    kubectl taint nodes `hostname` node-role.kubernetes.io/master:NoSchedule- 2>/dev/null
    kubectl taint nodes `hostname` node.kubernetes.io/not-ready:NoSchedule- 2>/dev/null
  ;;
  n | N)
      log "跳过${del_no_schedule_prompt}" &
      ;;
  *)
      log "跳过${del_no_schedule_prompt}" &
      ;;
  esac
}

function flannel() {
    FLANNEL_VERSION="0.24.0"
    log "开始安装网络组件flannel-v${FLANNEL_VERSION}"
    if [ "$1" ];then
      FLANNEL_VERSION=$1
    fi
    del_no_schedule
    docker load -i offline/images/kube-flannel-v0.24.0.tar.gz
    kubectl apply -f addons/kube-flannel/${FLANNEL_VERSION}/flannel-init.yaml
    kubectl get all -n kube-flannel
    check_pod_status kube-flannel
}

function calico() {
    CALICO_VERSION="3.26.1"
    log "开始安装网络组件calico-v${CALICO_VERSION}"
    if [ "$1" ];then
      CALICO_VERSION=$1
    fi
    del_no_schedule
    kubectl apply -f addons/kube-calico/${CALICO_VERSION}/calico-init.yaml
    log "网络组件flannel安装完成"
}

function descheduler() {
    DESCHEDULER_VERSION="0.24.0"
    log "开始安装调度管理组件descheduler-v${DESCHEDULER_VERSION}"
    if [ "$1" ];then
      DESCHEDULER_VERSION=$1
    fi
    del_no_schedule
    kubectl apply -f addons/kube-descheduler/${DESCHEDULER_VERSION}/
    log "调度管理组件descheduler安装完成"
}

function dashboard() {
    DASHBOARD_VERSION="2.7.0"
    log "开始安装k8s-web组件Dashboard-v${DASHBOARD_VERSION}"
    if [ "$1" ];then
      DASHBOARD_VERSION=$1
    fi
    kubectl create ns kubernetes-dashboard
    kubectl apply -f addons/kube-dashboard/$DASHBOARD_VERSION/dashboard-init.yaml
    kubectl get all -n kubernetes-dashboard
    check_pod_status kubernetes-dashboard
    kubectl create -f addons/kube-dashboard/$DASHBOARD_VERSION/dashboard-svc-account.yaml
    kubectl create token dashboard-admin -n kubernetes-dashboard
    log "安装完成,浏览方式: 用firefox 浏览 https://nodes-ip:30001 (要用命令查看pod-dashboard所对应的node节点),跳出不安全提示,然后高级点添加网站到安全例外"
}

function inginx() {
    INGINX_NGINX_VERSION="1.9.5"
    log "开始安装k8s-nginx组件ingress-nginx-v${INGINX_NGINX_VERSION}"
    if [ "$1" ];then
      INGINX_NGINX_VERSION=$1
    fi
    kubectl apply -f addons/kube-ingress-nginx/$INGINX_NGINX_VERSION/ingress-nginx-init.yaml
    kubectl get all -n ingress-nginx
    check_pod_status ingress-nginx
    log "k8s-nginx组件ingress-nginx安装完成"
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
    log "开始安装监控组件metrics-v${METRICS_VERSION}"
    kubectl apply -f addons/kube-metrics/${METRICS_VERSION}/metrics-init.yaml
    log "开始安装监控组件state-metrics-standard-v${STATE_METRICS_STANDARD_VERSION}"
    kubectl apply -f addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}/cluster-role-binding.yaml
    kubectl apply -f addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}/cluster-role.yaml
    kubectl apply -f addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}/service-account.yaml
    kubectl apply -f addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}/service.yaml
    kubectl apply -f addons/kube-state-metrics-standard/${STATE_METRICS_STANDARD_VERSION}/deployment.yaml
    log "监控组件metrics安装完成"
}

function alibaba_cloud_log() {
    ALI_CLOUD_LOG_VERSION="0.4.2"
    ALI_LOG_SLS_PROJECT_NAME=$1
    ALI_LOG_REGION=$2
    ALI_LOG_UID=$3
    ALI_LOG_ACCESS_KEY_ID=$4
    ALI_LOG_ACCESS_KEY_SECRET=$5
    if [ "$6" ];then
      ALI_CLOUD_LOG_VERSION=$6
    fi
    KUBE_CLUSTER_ID=echo $RANDOM
    chmod 744 addons/kube-alibaba-cloud-log/${ALI_CLOUD_LOG_VERSION}/k8s-custom-install.sh
    sed -i "s/{{ALI_LOG_SLS_PROJECT_NAME}}/${ALI_LOG_SLS_PROJECT_NAME}/g" addons/kube-alibaba-cloud-log/${ALI_CLOUD_LOG_VERSION}/values.yaml
    sed -i "s/{{ALI_LOG_REGION}}/${ALI_LOG_REGION}/g" addons/kube-alibaba-cloud-log/${ALI_CLOUD_LOG_VERSION}/values.yaml
    sed -i "s/{{ALI_LOG_UID}}/${ALI_LOG_UID}/g" addons/kube-alibaba-cloud-log/${ALI_CLOUD_LOG_VERSION}/values.yaml
    sed -i "s/{{ALI_LOG_ACCESS_KEY_ID}}/${ALI_LOG_ACCESS_KEY_ID}/g" addons/kube-alibaba-cloud-log/${ALI_CLOUD_LOG_VERSION}/values.yaml
    sed -i "s/{{ALI_LOG_ACCESS_KEY_SECRET}}/${ALI_LOG_ACCESS_KEY_SECRET}/g" addons/kube-alibaba-cloud-log/${ALI_CLOUD_LOG_VERSION}/values.yaml
    sed -i "s/{{CLUSTER_ID}}/custom-${KUBE_CLUSTER_ID}/g" addons/kube-alibaba-cloud-log/${ALI_CLOUD_LOG_VERSION}/values.yaml
    bash addons/kube-alibaba-cloud-log/${ALI_CLOUD_LOG_VERSION}/k8s-custom-install.sh; kubectl apply -R -f result
}

function all(){
  flannel
  dashboard
  inginx
  metrics
  descheduler
  alibaba_cloud_log
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
  descheduler)
    descheduler
    ;;
  alibaba_cloud_log)
    alibaba_cloud_log
    ;;
  all)
    all
    ;;
  esac
}
main_entrance $@

