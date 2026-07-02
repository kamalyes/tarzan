#!/usr/bin/env bash
# -y 全程免交互(与 install-kube.sh 习惯一致), 可出现在任意位置: clean-residue.sh -y all
# 解析在 source 之前完成, 环境变量 AUTO_CONFIRM 由 common.sh/variables.sh 消费
args=()
for arg in "$@"; do
    case "$arg" in
        -y | -Y) export AUTO_CONFIRM=1 ;;
        *) args+=("$arg") ;;
    esac
done
source ./common.sh

action=${args[0]}

function del_kube_node() {
    kubectl get nodes | grep -q "$(hostname)" 1>&2 >/dev/null
    if [ $? -eq 0 ]; then
        del_kube_node_prompt="删除K8s群集中的所有Node节点"
        if prompt_for_confirmation "$which_prompt" "$del_kube_node_prompt"; then
            log "检查kubelet服务是否正常运行"
            kubelet --version 1>/dev/null 2>/dev/null
            if [ $? != 0 ]; then
                color_echo ${yellow} "kubelet 未正常安装, 跳过${del_kube_node_prompt}"
            else
                kubectl delete node --all
            fi
        fi
    fi
}

function reset_kube() {
    reset_kube_prompt="重置K8s"
    if prompt_for_confirmation "$which_prompt" "$reset_kube_prompt"; then
        log "检查kubeadm服务是否正常运行"
        kubeadm --version 1>/dev/null 2>/dev/null
        if [ $? != 0 ]; then
            systemctl status kubeadm
            color_echo ${yellow} "kubeadm 未正常安装, 跳过${reset_kube_prompt}"
        else
            kubeadm reset -f
        fi
    fi
}

function del_flannel() {
    del_flannel_prompt="删除flannel网络配置和flannel网口"
    if prompt_for_confirmation "$which_prompt" "$del_flannel_prompt"; then
        rm -rf /etc/cni
        # 删除残留网桥与 VXLAN 接口(cni0 由 flannel 在节点重新加入后按 controller 新分配的 podCIDR 自动重建;
        # 手工重建并预设全局网段 IP 会与重新分配的 podCIDR 冲突: cni0 already has an IP address different)
        ip link delete cni0 2>/dev/null || true
        ip link delete flannel.1 2>/dev/null || true
        # 清理 flannel 子网缓存与 CNI 运行数据(残留旧子网会让 flannel 沿用与重新分配不一致的网段)
        rm -f /run/flannel/subnet.env
        rm -rf /var/lib/cni
        log "${del_flannel_prompt} OK"
    fi
}

function delete_dkube() {
    delete_dkube_prompt="卸载k8s&Docker等相关程序"
    if prompt_for_confirmation "$which_prompt" "$delete_dkube_prompt"; then
        # 按发行版选择包管理器(rhel 家族 yum / debian 家族 apt-get)
        if [[ "$OS_FAMILY" == "debian" ]]; then
            apt-get purge -y 'kube*' 'docker*' containerd.io
            apt-get install -y lsof
        else
            yum -y remove kube*
            yum -y remove docker*
            yum -y install lsof
        fi
        lsof -i :6443 | grep -v "PID" | awk '{print "kill -9",$2}' | sh
        lsof -i :10251 | grep -v "PID" | awk '{print "kill -9",$2}' | sh
        lsof -i :10252 | grep -v "PID" | awk '{print "kill -9",$2}' | sh
        lsof -i :10250 | grep -v "PID" | awk '{print "kill -9",$2}' | sh
        lsof -i :2379 | grep -v "PID" | awk '{print "kill -9",$2}' | sh
        lsof -i :2380 | grep -v "PID" | awk '{print "kill -9",$2}' | sh
        if [[ "$OS_FAMILY" == "debian" ]]; then
            apt-get autoremove -y && apt-get clean
        else
            yum clean all && yum makecache
        fi
        log "${delete_dkube_prompt} OK"
    fi
}

function rmove_kube_conf() {
    rmove_kube_conf_prompt="删除残留的配置文件"
    if prompt_for_confirmation "$which_prompt" "$rmove_kube_conf_prompt"; then
        modprobe -r ipip
        lsmod
        rm -rf ~/.kube/
        rm -rf /etc/kubernetes/
        rm -rf /etc/systemd/system/kubelet.service.d
        rm -rf /etc/systemd/system/kubelet.service
        rm -rf /etc/systemd/system/multi-user.target.wants/kubelet.service
        rm -rf /var/lib/kubelet
        rm -rf /usr/libexec/kubernetes/kubelet-plugins
        rm -rf /usr/bin/kube*
        rm -rf /opt/cni
        rm -rf /var/lib/etcd
        rm -rf /var/etcd
        log "${rmove_kube_conf_prompt} OK"
    fi
}

function all() {
    del_kube_node &&  del_flannel && delete_dkube && rmove_kube_conf
}

# 本机重置(不动集群节点记录): 供群控 remove-slave 远程调用
# 与 all 的区别: 不含 del_kube_node -- 单机解散时节点记录由 master 侧 kubectl delete node 精确摘除,
# slave 持有 admin 凭证执行 delete node --all 会误删全集群节点(含 master)
function reset_local() {
    reset_kube && del_flannel && delete_dkube && rmove_kube_conf
}

function main_entrance() {
    case "${action}" in
    reset_kube)
        reset_kube
        ;;
    rmove_kube_conf)
        rmove_kube_conf
        ;;
    delete_dkube)
        delete_dkube
        ;;
    del_flannel)
        del_flannel
        ;;
    del_kube_node)
        del_kube_node
        ;;
    all)
        all
        ;;
    reset_local)
        reset_local
        ;;
    esac
}
main_entrance $@