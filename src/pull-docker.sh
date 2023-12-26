#!/bin/bash
# 没科学上网只能老实做引用,各位放心使用,build引自官方镜像
# 具体见 https://hub.docker.com/u/thejosan20/  https://github.com/kamalyes?tab=repositories

docker pull docker.io/kubernetesui/dashboard:v2.7.0
docker tag docker.io/kubernetesui/dashboard:v2.7.0 kamalyes/kube-dashboard:v2.7.0

docker pull docker.io/kubernetesui/metrics-scraper:v1.0.4
docker tag docker.io/kubernetesui/metrics-scraper:v1.0.4 kamalyes/kube-metrics-scraper:v1.0.4

docker pull docker.io/flannel/flannel-cni-plugin:v1.2.0
docker tag docker.io/flannel/flannel-cni-plugin:v1.2.0 kamalyes/kube-flannel-cni-plugin:v1.2.0

docker pull docker.io/flannel/flannel:v0.24.0
docker tag docker.io/flannel/flannel:v0.24.0 kamalyes/kube-flannel:v0.24.0

docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/nginx-ingress-controller:v1.9.5
docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/nginx-ingress-controller:v1.9.5 kamalyes/kube-nginx-ingress-controller:v1.9.5

docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/kube-webhook-certgen:v20231011-8b53cabe0
docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/kube-webhook-certgen:v20231011-8b53cabe0 kamalyes/kube-webhook-certgen:v20231011-8b53cabe0

docker pull registry.aliyuncs.com/google_containers/metrics-server:v0.6.1
docker tag registry.aliyuncs.com/google_containers/metrics-server:v0.6.1 kamalyes/kube-metrics-server:v0.6.1

docker pull registry.aliyuncs.com/google_containers/metrics-server:v0.6.4
docker tag registry.aliyuncs.com/google_containers/metrics-server:v0.6.4 kamalyes/kube-metrics-server:v0.6.4

docker pull bitnami/kube-state-metrics:2.10.0
docker tag bitnami/kube-state-metrics:2.10.0 kamalyes/kube-state-metrics:2.10.0

docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/coredns:1.11.1
docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/coredns:1.11.1 kamalyes/kube-coredns:1.11.1

docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.9
docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.9 kamalyes/kube-pause:3.9

docker images | grep kamalyes
