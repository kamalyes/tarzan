#!/usr/bin/env bash
source ./common.sh

action=$1

function del_kube_node() {
    kubectl get nodes |grep -q `hostname` 1>&2 >/dev/null
    if [ $? -eq 0 ];then
        del_kube_node_prompt="删除K8s群集中的所有Node节点"
        read -p "是否确认${del_kube_node_prompt}? [n/y]" __choice </dev/tty
        case "$__choice" in
        y | Y) 
        log "检查kubelet服务是否正常运行"
        kubelet --version 1>/dev/null 2>/dev/null
        if [ $? != 0 ]; then
            log "kubelet 未正常安装, 跳过${del_kube_node_prompt}"
        else
            kubectl delete node --all
        fi
        ;;
        n | N)
            log "跳过${del_kube_node_prompt}" &
            ;;
        *)
            log "跳过${del_kube_node_prompt}" &
            ;;
        esac
    fi
}

function reset_kube() {
    reset_kube_prompt="重置K8s"
    read -p "是否确认${reset_kube_prompt}? [n/y]" __choice </dev/tty
    case "$__choice" in
    y | Y)
    log "检查kubeadm服务是否正常运行"
    kubeadm --version 1>/dev/null 2>/dev/null
    if [ $? != 0 ]; then
            systemctl status kubeadm
            log "kubeadm 未正常安装, 跳过${reset_kube_prompt}"
    else
        kubeadm reset -f
    fi
    ;;
    n | N)
        log "跳过${reset_kube_prompt}..." &
        ;;
    *)
        log "跳过${reset_kube_prompt}..." &
        ;;
    esac
}

function del_flannel() {
    del_flannel_prompt="删除flannel网络配置和flannel网口"
    read -p "是否确认${del_flannel_prompt}? [n/y]" __choice </dev/tty
    case "$__choice" in
    y | Y)
    rm -rf /etc/cni
    # 删除cni网络
    ifconfig cni0 down
    ip link delete cni0
    ifconfig flannel.1 down
    ip link delete flannel.1
    ifconfig eth0:1 down
    ip link delete eth0:1
    cd /etc/sysconfig/network-scripts/ #(若不生效也可以进入改目录下直接删除配置文件后重启网络)
    log "${del_flannel_prompt} OK"
    ;;
    n | N)
        log "跳过${del_flannel_prompt}..." &
        ;;
    *)
        log "跳过${del_flannel_prompt}..." &
        ;;
    esac
}

function delete_dkube() {
    delete_dkube_prompt="卸载k8s&Docker等相关程序"
    read -p "是否确认${delete_dkube_prompt}? [n/y]" __choice </dev/tty
    case "$__choice" in
    y | Y) echo 
    yum -y remove kube*
    yum -y remove docker*
    yum -y install lsof
    lsof -i :6443 | grep -v "PID" | awk '{print "kill -9",$2}' | sh
    lsof -i :10251 | grep -v "PID" | awk '{print "kill -9",$2}' | sh
    lsof -i :10252 | grep -v "PID" | awk '{print "kill -9",$2}' | sh
    lsof -i :10250 | grep -v "PID" | awk '{print "kill -9",$2}' | sh
    lsof -i :2379 | grep -v "PID" | awk '{print "kill -9",$2}' | sh
    lsof -i :2380 | grep -v "PID" | awk '{print "kill -9",$2}' | sh
    yum clean all && yum makecache
    log "${delete_dkube_prompt} OK"
    ;;
    n | N)
        log "跳过${delete_dkube_prompt}..." &
        ;;
    *)
        log "跳过${delete_dkube_prompt}..." &
        ;;
    esac
}

function rmove_kube_conf() {
    rmove_kube_conf_prompt="删除残留的配置文件"
    read -p "是否确认${rmove_kube_conf_prompt}? [n/y]" __choice </dev/tty
    case "$__choice" in
    y | Y)
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
    ;;
    n | N)
        log "跳过${rmove_kube_conf_prompt}" &
        ;;
    *)
        log "跳过${rmove_kube_conf_prompt}" &
        ;;
    esac
}

function all() {
    del_kube_node &&  del_flannel && delete_dkube && rmove_kube_conf
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
    esac
}
main_entrance $@