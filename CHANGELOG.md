### 变更日志

#### [未发布]

2024-09-20:
- 增加 slave join 操作（慎用 没必要存在的功能）
- 抽离公共路径为变量便于 clean
- 处理 ipvs linux 内核 > 4.12 无法启动问题
- 更新 common service 探活
- 增加 1.23.3 coredns 离线 image & 更新提示语句等级
- 升级 cni 版本为最新 1.5.1 & 移除公共依赖 & 缩减包体积
- 更新 kube imagePullPolicy