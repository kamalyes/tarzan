k8s和dashboard版本存在兼容性关系，版本配套可以到下面的网页查询：<https://github.com/kubernetes/dashboard/releases/>
以下是部分配套关系：
Kubernetes version dashboard version 备注
1.18 v2.0.0 完全支持
1.19 v2.0.4 完全支持
1.20 v2.4.0 完全支持
1.21 v2.4.0 完全支持
1.23 v2.5.0 完全支持
1.24 v2.6.0 完全支持
1.25 v2.7.0 完全支持
1.27 v3.0.0-alpha0 完全支持
1.29 kubernetes-dashboard-7.5.0 完全支持
本文使用的k8s版本为1.23，使用dashboard v2.5.0版本部署。

一、问题
-------------------------------------------------------------------

`{{IP地址}} 通常会使用加密技术来保护您的信息。Chrome 此次尝试连接到 {{IP地址}} 时，该网站发回了异常的错误凭据。这可能是因为有攻击者在试图冒充 {{IP地址}}，或者 Wi-Fi 登录屏幕中断了此次连接。请放心，您的信息仍然是安全的，因为 Chrome 尚未进行任何数据交换便停止了连接。`

`您目前无法访问{{IP地址}}，因为此网站发送了Chrome无法处理的杂乱凭据。网络错误和攻击通常是暂时的，因此，此网页稍后可能会恢复正常。`  

二、解决步骤
---------------------------------------------------------------------

一般情况下，正常安装部署完 Kubernetes Dashboard 后，通过大多数主流浏览器（Chrome、IE、Safari、Edge）是不能正常访问的，据我本人所测试目前只有火狐浏览器支持打开如下图

通过火狐浏览器是可以访问的

2.2 解释原因

该问题是由于部署 Kubernetes Dashboard 时默认生成的证书有问题导致的。在这篇文章中，我们就来教你如何快速优雅的解决它。

既然是证书问题，那解决办法当然是生成一个新的有效证书替换掉过期的即可。

2.3 通过生成新的证书永久解决

下面是生成 Kubernetes Dashboard 域名证书的几种常用方法，你可以根据自身实际情况选用任何一种就行。

1.通过 `https://freessl.cn` 网站，在线生成免费 1 年的证书

2.通过 `Let’s Encrypt` 生成 90 天免费证书

3.通过 `Cert-Manager` 服务来生成和管理证书

4.通过`IP` 直接自签一个证书

几种方式的原理都是一样的，我们这里使用自签证书的方法来进行演示。

1.生成证书

```shell
# 这个也是一种生成证书的一种方式：
openssl genrsa -out tls.key 2048 
openssl req -new -out tls.csr -key tls.key -subj '/CN={{IP地址}}'
openssl x509 -req -days 3650 -in tls.csr -signkey tls.key -out tls.crt
```

# 下面是生成证书的另一种方式

```shell
# 生成证书请求的key
[root@k8s-master kube-dashboard]# openssl genrsa -out tls.key 2048
Generating RSA private key, 2048 bit long modulus
.........................+++
...................................................+++
e is 65537 (0x10001)

# 生成证书请求
[root@k8s-master kube-dashboard]# openssl req -days 3650 -new -out tls.csr -key tls.key -subj '/CN={{IP地址}}'

# 生成自签证书
[root@k8s-master kube-dashboard]# openssl x509 -req -in tls.csr -signkey tls.key -out tls.crt
Signature ok
subject=/CN={{IP地址}}
Getting Private key
```

2.删除原有证书

```bash
[root@k8s-master kube-dashboard]# kubectl get secret kubernetes-dashboard-certs -n kube-dashboard
NAME                         TYPE     DATA   AGE
kubernetes-dashboard-certs   Opaque   0      123m
You have new mail in /var/spool/mail/root
[root@k8s-master kube-dashboard]# kubectl delete secret kubernetes-dashboard-certs -n kube-dashboard
secret "kubernetes-dashboard-certs" deleted

kubectl create secret generic kubernetes-dashboard-certs --from-file=tls.key --from-file=tls.crt -n kube-dashboard
```

4.查看dashboard的pod

```bash
[root@k8s-master kube-dashboard]# kubectl get pod -n kube-dashboard  | grep dashboard
dashboard-metrics-scraper-7645f69d8c-86dxq   1/1     Running   0          127m
kubernetes-dashboard-78cb679857-x4hpw        1/1     Running   0          127m


```

5.删除原有pod即可（会自动创建新的pod）

```bash
[root@k8s-master kube-dashboard]# kubectl delete pod kubernetes-dashboard-78cb679857-x4hpw -n kube-dashboard
pod "kubernetes-dashboard-78cb679857-x4hpw" deleted

#再次查看，pod 正在创建中
[root@k8s-master kube-dashboard]# kubectl get pod -n kube-dashboard  | grep dashboard
dashboard-metrics-scraper-7645f69d8c-86dxq   1/1     Running             0          133m
kubernetes-dashboard-78cb679857-fmv7w        0/1     ContainerCreating   0          29s

#创建好了
[root@k8s-master kube-dashboard]# kubectl get pod -n kube-dashboard  | grep dashboard
dashboard-metrics-scraper-7645f69d8c-86dxq   1/1     Running   0          141m
kubernetes-dashboard-78cb679857-n4hlf        1/1     Running   0          3m57s
```

2.4 在master节点等待pod重新起来进行测试，观察到正常

2.5 获取访问所需要的Token：

```bash
[root@k8s-master ~]# kubectl -n kube-dashboard describe secret $(kubectl -n kube-dashboard get secret | grep kubernetes-admin | awk '{print $1}')
Name:         admin-user-token-khrll
Namespace:    kube-dashboard
Labels:       <none>
Annotations:  kubernetes.io/service-account.name: admin-user
              kubernetes.io/service-account.uid: 266c923b-ed2f-471b-a8fc-1dde3cc10205
Type:  kubernetes.io/service-account-token
Data
====
ca.crt:     1099 bytes
namespace:  20 bytes
token:      eyJh....JKVGxxIQ
```