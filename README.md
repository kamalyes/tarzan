
# 离线安装

```bash
# 基于tarzan-offline-multiple包
# 增加HOST配置信息
bash -c 'cat << EOF >> /conf/hosts
10.0.0.3 k8s-master
10.0.0.8 k8s-node1
10.0.0.9 k8s-node2
10.0.0.10 k8s-node3
EOF'
# Master 10.0.0.3
sh install-kube.sh -v v1.23.3 -addr 10.0.0.3 --flannel --hostname k8s-master # (内网)
# 安装完Master之后会得到一个join指令（Kubeadm join command）
kubeadm join 10.0.0.3:6443 --token 0dy3rl.33bugu3rax35r815 --discovery-token-ca-cert-hash sha256:0c7e8afb55c242c351bfb744cc4e64cf7221033f3dd7f4aaa995602cb6af3b9d
# 假设k8s-master对应的外网为115.132.233.15 则需追加参数 --virtualip 115.132.233.15
sh install-kube.sh -v v1.23.3 -addr 115.132.233.15 --virtualip 115.132.233.15 --flannel --hostname k8s-master
# Slave
sh install-kube.sh && ${Kubeadm join command} --hostname k8s-node1 
sh install-kube.sh && ${Kubeadm join command} --hostname k8s-node2
sh install-kube.sh && ${Kubeadm join command} --hostname k8s-node3
```

# 在线安装

```bash
# 基于tarzan-online包
# 携带参数如下
--image-pull-policy Always
```

# 二次开发

```bash
# 因为包有点大所以需要克隆深度=1，其中很多离线包 所以需要用到git-lfs插件
git clone --depth=1 git@github.com:kamalyes/tarzan.git
cd tarzan
```
