#!/bin/bash
docker push  kamalyes/kube-dashboard:v2.7.0
docker push  kamalyes/kube-metrics-scraper:v1.0.4
docker push kamalyes/kube-flannel-cni-plugin:v1.2.0
docker push kamalyes/kube-flannel:v0.24.0
docker push kamalyes/kube-nginx-ingress-controller:v1.9.5
docker push kamalyes/kube-webhook-certgen:v20231011-8b53cabe0
docker push kamalyes/kube-metrics-server:v0.6.1
docker push kamalyes/kube-metrics-server:v0.6.4
docker push kamalyes/kube-state-metrics:2.10.0
docker push kamalyes/kube-coredns:1.11.1
docker push kamalyes/kube-pause:3.9