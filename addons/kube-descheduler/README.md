> 从 kube-scheduler 的角度来看，它是通过一系列算法计算出最佳节点运行 Pod，当出现新的 Pod 进行调度时，调度程序会根据其当时对 Kubernetes 集群的资源描述做出最佳调度决定，但是 Kubernetes 集群是非常动态的，由于整个集群范围内的变化，比如一个节点为了维护，我们先执行了驱逐操作，这个节点上的所有 Pod 会被驱逐到其他节点去，但是当我们维护完成后，之前的 Pod 并不会自动回到该节点上来，因为 Pod 一旦被绑定了节点是不会触发重新调度的，由于这些变化，Kubernetes 集群在一段时间内就可能会出现不均衡的状态，所以需要均衡器来重新平衡集群。
>
当然我们可以去手动做一些集群的平衡，比如手动去删掉某些 Pod，触发重新调度就可以了，但是显然这是一个繁琐的过程，也不是解决问题的方式。为了解决实际运行中集群资源无法充分利用或浪费的问题，可以使用 descheduler 组件对集群的 Pod 进行调度优化，descheduler 可以根据一些规则和配置策略来帮助我们重新平衡集群状态，其核心原理是根据其策略配置找到可以被移除的 Pod 并驱逐它们，其本身并不会
进行调度被驱逐的 Pod，而是依靠默认的调度器来实现，目前支持的策略有：

```bash
RemoveDuplicates
LowNodeUtilization
RemovePodsViolatingInterPodAntiAffinity
RemovePodsViolatingNodeAffinity
RemovePodsViolatingNodeTaints
RemovePodsViolatingTopologySpreadConstraint
RemovePodsHavingTooManyRestarts
PodLifeTime
```

这些策略都是可以启用或者禁用的，作为策略的一部分，也可以配置与策略相关的一些参数，默认情况下，所有策略都是启用的。另外，还有一些通用配置，如下：

nodeSelector：限制要处理的节点
evictLocalStoragePods: 驱逐使用 LocalStorage 的 Pods
ignorePvcPods: 是否忽略配置 PVC 的 Pods，默认是 False
maxNoOfPodsToEvictPerNode：节点允许的最大驱逐 Pods 数
我们可以通过如下所示的 DeschedulerPolicy 来配置：

```bash
apiVersion: "descheduler/v1alpha1"
kind: "DeschedulerPolicy"
nodeSelector: prod=dev
evictLocalStoragePods: true
maxNoOfPodsToEvictPerNode: 40
ignorePvcPods: false
strategies:  # 配置策略
  ...
```

descheduler 可以以 Job、CronJob 或者 Deployment 的形式运行在 k8s 集群内
