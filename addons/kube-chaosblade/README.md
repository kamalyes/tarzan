执行 Kubernetes 实验场景，需要提前部署 ChaosBlade Operator，Helm 安装包下载地址

<https://github.com/chaosblade-io/chaosblade-operator/releases> 使用以下命令安装

```bash

# 先安装helm
wget https://get.helm.sh/helm-v3.3.4-linux-amd64.tar.gz
tar -zxvf helm-v3.3.4-linux-amd64.tar.gz
mv linux-amd64/helm /usr/local/bin/helm
helm version

[root@VM-8-3-centos tarzan]# wget https://get.helm.sh/helm-v3.3.4-linux-amd64.tar.gz
--2024-09-14 13:41:04--  https://get.helm.sh/helm-v3.3.4-linux-amd64.tar.gz
Resolving get.helm.sh (get.helm.sh)... 
152.199.39.108, 2606:2800:247:1cb7:261b:1f9c:2074:3c
Connecting to get.helm.sh (get.helm.sh)|152.199.39.108|:443... connected.
HTTP request sent, awaiting response... 200 OK
Length: 12752995 (12M) [application/x-tar]
Saving to: ‘helm-v3.3.4-linux-amd64.tar.gz’

 0% [>                                                                                                        ] 122,880      140KB/s             
89% [=============================================================================================>           ] 11,427,826  75.3KB/s  eta 22s    
89% [=============================================================================================>           ] 11,444,209  72.2KB/s  eta 22s    
100%[========================================================================================================>] 12,752,995  61.7KB/s   in 3m 25s 

2024-09-14 13:44:31 (60.9 KB/s) - ‘helm-v3.3.4-linux-amd64.tar.gz’ saved [12752995/12752995]

[root@VM-8-3-centos tarzan]# tar -zxvf helm-v3.3.4-linux-amd64.tar.gz
linux-amd64/
linux-amd64/README.md
linux-amd64/LICENSE
linux-amd64/helm
[root@VM-8-3-centos tarzan]# mv linux-amd64/helm /usr/local/bin/helm
[root@VM-8-3-centos tarzan]# helm version 
version.BuildInfo{Version:"v3.3.4", GitCommit:"a61ce5633af99708171414353ed49547cf05013d", GitTreeState:"clean", GoVersion:"go1.14.9"}

# 解压混沌包
tar -xzvf chaosblade-operator-1.7.1.tgz
```

然后使用helm进行安装混沌
```bash
helm install chaosblade-operator ./chaosblade-operator -n lsc-test
```
