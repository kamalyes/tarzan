# 安装步骤
1. 在values.yaml中完成必要参数填写
2. 执行bash k8s-custom-install.sh脚本，生成result目录
3. 执行kubectl apply -R -f result 即可完成部署