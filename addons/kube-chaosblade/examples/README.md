1、执行 Kubernetes 实验场景，需要提前部署 ChaosBlade Operator，Helm 安装包下载地址

<https://github.com/chaosblade-io/chaosblade-operator/releases> 。使用以下命令安装：

下载成功后进行解压

```bash
tar -xzvf chaosblade-operator-1.7.1.tgz
```

然后使用helm进行安装：

```bash
helm install chaosblade-operator ./chaosblade-operator -n lsc-test
```