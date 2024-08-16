在`Kubernetes`中使用`Kubernetes`作为`Ingress Controller`时，可以通过创建TLS秘钥和证书并将它们作为`Secret`资源加载到`Kubernetes`集群中来配置SSL证书。

以下是一个简单的步骤和示例代码，用于创建TLS Secret资源。

首先，你需要有一个私钥和证书文件。私钥文件通常是.key文件，而证书文件可以是.crt或.pem文件。

创建一个Kubernetes Secret资源，将你的TLS秘钥和证书作为数据部分。

假设你的私钥文件名为`tls.key`，证书文件名为`tls.crt`，可以使用以下命令创建`Secret`：

```bash
kubectl create secret tls tls-secret --key tls.key --cert tls.crt
```

接下来，在你的Ingress资源中引用这个Secret：

```bash
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-ingress
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  tls:

- hosts:
  - example.com
    secretName: tls-secret
  rules:
- host: example.com
    http:
      paths:
  - path: /
        pathType: Prefix
        backend:
          service:
            name: my-service
            port:
              number: 80
```

在这个Ingress资源定义中，tls部分指定了使用tls-secret这个Secret来进行SSL/TLS传输加密，并且通过注解来强制使用HTTPS。
确保替换`tls.key`、`tls.crt`、`example-ingress`、`example.com`、`my-service`和端口号为你自己的实际值。

当然ingress还有其它的属性, 模版见附件`ingress-ssl-template.yaml`
