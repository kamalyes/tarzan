#!/usr/bin/env bash
source ./common.sh

action=$1
docker_username=$2
docker_password=$3
docker_registry=$4

function login_docker() {
  log "开始尝试登录Docker Registry, UserName:$docker_username, Password:$docker_password, Registry:$docker_registry"
  docker login --username=$docker_username --password=$docker_password $docker_registry
}

function pull_images() {
  log "开始下载kubeadm所需要的镜像"
  log "针对国内网络,没科学上网只能老实做镜像引用,各位放心使用,build引自官方镜像 "
  log "查Dockerfile网址 https://hub.docker.com/u/kamalyes/  https://github.com/kamalyes?tab=repositories "
  docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/kube-apiserver:v1.25.3
  docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/kube-controller-manager:v1.25.3
  docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/kube-scheduler:v1.25.3
  docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/kube-proxy:v1.25.3
  docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.8
  docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/etcd:3.5.4-0
  docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/coredns:v1.9.3
  docker pull kamalyes/kube-dashboard:v2.7.0
  docker pull kamalyes/kube-metrics-scraper:v1.0.4
  docker pull kamalyes/kube-flannel-cni-plugin:v1.2.0
  docker pull kamalyes/kube-flannel:v0.24.0
  docker pull kamalyes/kube-calico-cni:v3.26.1
  docker pull kamalyes/kube-calico-node:v3.26.1
  docker pull kamalyes/kube-calico-controllers:v3.26.1
  docker pull kamalyes/kube-nginx-ingress-controller:v1.9.5
  docker pull kamalyes/kube-webhook-certgen:v20231011-8b53cabe0
  docker pull kamalyes/kube-metrics-server:v0.6.1
  docker pull kamalyes/kube-metrics-server:v0.6.4
  docker pull kamalyes/kube-state-metrics:2.10.0
  docker pull kamalyes/kube-coredns:1.11.1
  docker pull kamalyes/kube-pause:3.9
  docker pull kamalyes/kube-descheduler:v0.24.0
  log "Kube镜像包Pull OK"
  docker images | grep kamalyes
}

function push_images() {
  docker pull docker.io/kubernetesui/dashboard:v2.7.0
  docker tag docker.io/kubernetesui/dashboard:v2.7.0 kamalyes/kube-dashboard:v2.7.0
  docker rmi -f docker.io/kubernetesui/dashboard:v2.7.0

  docker pull docker.io/kubernetesui/metrics-scraper:v1.0.4
  docker tag docker.io/kubernetesui/metrics-scraper:v1.0.4 kamalyes/kube-metrics-scraper:v1.0.4
  docker rmi -f docker.io/kubernetesui/metrics-scraper:v1.0.4

  docker pull docker.io/flannel/flannel-cni-plugin:v1.2.0
  docker tag docker.io/flannel/flannel-cni-plugin:v1.2.0 kamalyes/kube-flannel-cni-plugin:v1.2.0
  docker rmi -f docker.io/flannel/flannel-cni-plugin:v1.2.0

  docker pull docker.io/flannel/flannel:v0.24.0
  docker tag docker.io/flannel/flannel:v0.24.0 kamalyes/kube-flannel:v0.24.0
  docker rmi -f docker.io/flannel/flannel:v0.24.0

  docker pull docker.io/calico/cni:v3.26.1
  docker tag docker.io/calico/cni:v3.26.1 kamalyes/kube-calico-cni:v3.26.1
  docker rmi -f docker.io/calico/cni:v3.26.1

  docker pull docker.io/calico/node:v3.26.1
  docker tag docker.io/calico/node:v3.26.1 kamalyes/kube-calico-node:v3.26.1
  docker rmi -f docker.io/calico/node:v3.26.1
  
  docker pull docker.io/calico/kube-controllers:v3.26.1
  docker tag docker.io/calico/kube-controllers:v3.26.1 kamalyes/kube-calico-controllers:v3.26.1
  docker rmi -f docker.io/calico/kube-controllers:v3.26.1

  docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/nginx-ingress-controller:v1.9.5
  docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/nginx-ingress-controller:v1.9.5 kamalyes/kube-nginx-ingress-controller:v1.9.5
  docker rmi -f registry.cn-hangzhou.aliyuncs.com/google_containers/nginx-ingress-controller:v1.9.5

  docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/kube-webhook-certgen:v20231011-8b53cabe0
  docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/kube-webhook-certgen:v20231011-8b53cabe0 kamalyes/kube-webhook-certgen:v20231011-8b53cabe0
  docker rmi -f registry.cn-hangzhou.aliyuncs.com/google_containers/kube-webhook-certgen:v20231011-8b53cabe0

  docker pull registry.aliyuncs.com/google_containers/metrics-server:v0.6.1
  docker tag registry.aliyuncs.com/google_containers/metrics-server:v0.6.1 kamalyes/kube-metrics-server:v0.6.1
  docker rmi -f registry.aliyuncs.com/google_containers/metrics-server:v0.6.1

  docker pull registry.aliyuncs.com/google_containers/metrics-server:v0.6.4
  docker tag registry.aliyuncs.com/google_containers/metrics-server:v0.6.4 kamalyes/kube-metrics-server:v0.6.4
  docker rmi -f registry.aliyuncs.com/google_containers/metrics-server:v0.6.4

  docker pull bitnami/kube-state-metrics:2.10.0
  docker tag bitnami/kube-state-metrics:2.10.0 kamalyes/kube-state-metrics:2.10.0
  docker rmi -f bitnami/kube-state-metrics:2.10.0

  docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/coredns:1.11.1
  docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/coredns:1.11.1 kamalyes/kube-coredns:1.11.1
  docker rmi -f registry.cn-hangzhou.aliyuncs.com/google_containers/coredns:1.11.1

  docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.9
  docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.9 kamalyes/kube-pause:3.9
  docker rmi -f registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.9

  docker pull registry.cn-hangzhou.aliyuncs.com/coolops/descheduler:v0.24.0
  docker tag registry.cn-hangzhou.aliyuncs.com/coolops/descheduler:v0.24.0 kamalyes/kube-descheduler:v0.24.0
  docker rmi -f registry.cn-hangzhou.aliyuncs.com/coolops/descheduler:v0.24.0

  log "Kube镜像包Pull OK"
  docker images | grep kamalyes
  docker push kamalyes/kube-dashboard:v2.7.0
  docker push kamalyes/kube-metrics-scraper:v1.0.4
  docker push kamalyes/kube-flannel-cni-plugin:v1.2.0
  docker push kamalyes/kube-flannel:v0.24.0
  docker push kamalyes/kube-calico-cni:v3.26.1
  docker push kamalyes/kube-calico-node:v3.26.1
  docker push kamalyes/kube-calico-controllers:v3.26.1
  docker push kamalyes/kube-nginx-ingress-controller:v1.9.5
  docker push kamalyes/kube-webhook-certgen:v20231011-8b53cabe0
  docker push kamalyes/kube-metrics-server:v0.6.1
  docker push kamalyes/kube-metrics-server:v0.6.4
  docker push kamalyes/kube-state-metrics:2.10.0
  docker push kamalyes/kube-coredns:1.11.1
  docker push kamalyes/kube-pause:3.9
  docker push kamalyes/kube-descheduler:v0.24.0
}

function main_entrance() {
  case "${action}" in
  login_docker)
    login_docker
    ;;
  pull_images)
    pull_images
    ;;
  push_images)
    push_images
    ;;
  esac
}
main_entrance $@
