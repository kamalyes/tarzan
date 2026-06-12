#!/usr/bin/env bash
source ./common.sh

# 群控脚本: 基于 conf/ssh_hosts 批量远程执行命令 / 分发文件 / 一键安装所有 slave
# 连接/免密自举/批量执行分发等通用能力在 common.sh, 这里只保留 slave 加入集群的业务流程

action=$1

# 单台 slave 安装(分发安装包 + 远程解压执行 join)
function slave_install() {
    local user=$1 host=$2 password=$3 port=$4
    local package=$5 masterip=$6 token=$7 hash=$8
    # 幂等预检: master(有 admin.conf)与已加入节点(有 kubelet.conf)自动跳过, 重复执行只装新机器
    local node_state
    if is_local_host "$host"; then
        # 本机不发起 SSH, 直接本地检测
        node_state="fresh"
        [ -f /etc/kubernetes/kubelet.conf ] && node_state="joined"
        [ -f /etc/kubernetes/admin.conf ] && node_state="master"
    else
        node_state=$(timeout 30 ssh $SSH_OPTS -p "$port" "$user@$host" \
            'if [ -f /etc/kubernetes/admin.conf ]; then echo master; elif [ -f /etc/kubernetes/kubelet.conf ]; then echo joined; else echo fresh; fi' 2>/dev/null) || node_state=""
    fi
    if [[ "$node_state" == "master" ]]; then
        log "[$user@$host] 是 master 节点, 无需加入, 跳过"
        return 0
    fi
    if [[ "$node_state" == "joined" ]]; then
        log "[$user@$host] 已加入集群, 跳过(如需重新加入请先在该机执行 clean-residue.sh 清理残留)"
        return 0
    fi
    log "[$user@$host] 分发 slave 安装包"
    timeout $SSH_COPY_TIMEOUT scp $SSH_OPTS $SSH_ALIVE_OPTS -P "$port" "$package" "$user@$host:~/" || {
        color_echo ${red} "[$user@$host] 安装包分发失败"
        return 1
    }
    log "[$user@$host] 远程安装并加入集群"
    timeout $SSH_EXEC_TIMEOUT ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
        "tar -xzf ~/${NODE_PACKAGE_PATH}.tar.gz -C ~ && cd ~/$NODE_PACKAGE_PATH && /bin/bash install-kube.sh --join -y --masterip $masterip --token $token --discovery-token-ca-cert-hash $hash" || {
        color_echo ${red} "[$user@$host] slave 安装失败"
        return 1
    }
    log "[$user@$host] slave 安装完成"
}

# 一键安装所有 slave: 免密自举后动态生成 join 凭据(kubeadm token), 批量分发安装
function install_slaves() {
    ensure_passwordless
    local package="${NODE_PACKAGE_PATH}.tar.gz"
    if [ ! -f "$package" ]; then
        color_echo ${red} "未找到 $package, 请先在 master 执行 install-kube.sh 生成 slave 安装包"
        exit 1
    fi
    # 动态生成 join 凭据(不复用旧 token, 60s 上限防止 API 未就绪时无限等待)
    local join_command
    log "动态生成 join 凭据(kubeadm token create)"
    join_command=$(timeout 60 kubeadm token create --print-join-command --ttl=0)
    local masterip token hash
    # masterip 保留 ip:port 原样传递(kubeadm join 支持, 自定义 KUBE_BIND_PORT 时不丢端口)
    masterip=$(echo "$join_command" | awk '{print $3}')
    token=$(echo "$join_command" | awk '{print $5}')
    hash=$(echo "$join_command" | awk '{print $7}')
    if [ -z "$masterip" ] || [ -z "$token" ] || [ -z "$hash" ]; then
        color_echo ${red} "解析 join 凭据失败: $join_command"
        exit 1
    fi
    log "join 凭据已生成(master: $masterip)"
    for_each_machine slave_install "$package" "$masterip" "$token" "$hash"
}

function main_entrance() {
    case "${action}" in
        hosts)
            list_machines
            ;;
        exec)
            run_command_on_machines "$2"
            ;;
        copy)
            copy_file_to_machines "$2" "$3"
            ;;
        install-slaves)
            install_slaves
            ;;
        *)
            echo "Usage: $0 {hosts|exec <command>|copy <local-file> [remote-path]|install-slaves}"
            exit 1
            ;;
    esac
}

main_entrance "$@"
