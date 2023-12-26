#!/bin/bash
# cd 到目录中运行 ./install-node.sh 就可以了
KUBE_VERSION="1.25.3"
echo -e "初始化k8s所需要环境."
/bin/bash setupconfig.sh
/bin/bash pull-docker.sh
log "安装kube软件"
/bin/bash install-kube.sh $KUBE_VERSION
echo -e "node加入k8s集群"