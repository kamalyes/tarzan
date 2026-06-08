#!/usr/bin/env bash
source ./common.sh

# 群控脚本: 基于 conf/ssh_hosts 批量远程执行命令 / 分发文件 / 一键安装所有 slave
# conf/ssh_hosts 格式: user:host:password[:port] 每行一台(与 setup-ssh-keys.sh 一致)

action=$1

# 遍历目标机器执行回调, 回调参数: user host password port ...
# 单台失败不中断其余机器, 全部处理完后聚合返回失败状态
function for_each_machine() {
    local exec_fn=$1
    shift
    local line user host password port failed=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        IFS=':' read -r user host password port <<< "$line"
        port=${port:-$DEFAULT_SSH_PORT}
        if ! "$exec_fn" "$user" "$host" "$password" "$port" "$@"; then
            failed=1
        fi
    done < "$TARGET_FILE"
    return $failed
}

function batch_exec() {
    local user=$1 host=$2 password=$3 port=$4
    local command="$5"
    log "[$user@$host] 执行: $command"
    if timeout $SSH_EXEC_TIMEOUT sshpass -p "$password" ssh -o StrictHostKeyChecking=no -p "$port" "$user@$host" "$command"; then
        log "[$user@$host] 执行成功"
    else
        color_echo ${red} "[$user@$host] 执行失败"
        return 1
    fi
}

function batch_copy() {
    local user=$1 host=$2 password=$3 port=$4
    local local_file=$5 remote_path=$6
    if [ ! -f "$local_file" ]; then
        color_echo ${red} "本地文件 $local_file 不存在"
        return 1
    fi
    log "[$user@$host] 分发: $local_file -> $remote_path"
    if timeout $SSH_COPY_TIMEOUT sshpass -p "$password" scp -o StrictHostKeyChecking=no -P "$port" "$local_file" "$user@$host:$remote_path"; then
        log "[$user@$host] 分发成功"
    else
        color_echo ${red} "[$user@$host] 分发失败"
        return 1
    fi
}

# 批量执行命令
function run_command_on_machines() {
    local command="$1"
    if [ -z "$command" ]; then
        color_echo ${red} "请提供要执行的命令"
        exit 1
    fi
    for_each_machine batch_exec "$command"
}

# 批量分发文件
function copy_file_to_machines() {
    local local_file=$1
    local remote_path=${2:-$DEFAULT_SSH_TARGET_PATH}
    if [ -z "$local_file" ]; then
        color_echo ${red} "请提供要分发的本地文件"
        exit 1
    fi
    for_each_machine batch_copy "$local_file" "$remote_path"
}

# 单台 slave 安装(分发安装包 + 远程解压执行 join)
function slave_install() {
    local user=$1 host=$2 password=$3 port=$4
    local package=$5 masterip=$6 token=$7 hash=$8
    # 幂等预检: master(有 admin.conf)与已加入节点(有 kubelet.conf)自动跳过, 重复执行只装新机器
    local node_state
    node_state=$(timeout 30 sshpass -p "$password" ssh -o StrictHostKeyChecking=no -p "$port" "$user@$host" \
        'if [ -f /etc/kubernetes/admin.conf ]; then echo master; elif [ -f /etc/kubernetes/kubelet.conf ]; then echo joined; else echo fresh; fi' 2>/dev/null) || node_state=""
    if [[ "$node_state" == "master" ]]; then
        log "[$user@$host] 是 master 节点, 无需加入, 跳过"
        return 0
    fi
    if [[ "$node_state" == "joined" ]]; then
        log "[$user@$host] 已加入集群, 跳过(如需重新加入请先在该机执行 clean-residue.sh 清理残留)"
        return 0
    fi
    log "[$user@$host] 分发 slave 安装包"
    timeout $SSH_COPY_TIMEOUT sshpass -p "$password" scp -o StrictHostKeyChecking=no -P "$port" "$package" "$user@$host:~/" || {
        color_echo ${red} "[$user@$host] 安装包分发失败"
        return 1
    }
    log "[$user@$host] 远程安装并加入集群"
    timeout $SSH_EXEC_TIMEOUT sshpass -p "$password" ssh -o StrictHostKeyChecking=no -p "$port" "$user@$host" \
        "tar -xzf ~/${NODE_PACKAGE_PATH}.tar.gz -C ~ && cd ~/$NODE_PACKAGE_PATH && /bin/bash install-kube.sh --join -y --masterip $masterip --token $token --discovery-token-ca-cert-hash $hash" || {
        color_echo ${red} "[$user@$host] slave 安装失败"
        return 1
    }
    log "[$user@$host] slave 安装完成"
}

# 一键安装所有 slave: 动态生成 join 凭据(kubeadm token)后批量分发安装
function install_slaves() {
    local package="${NODE_PACKAGE_PATH}.tar.gz"
    if [ ! -f "$package" ]; then
        color_echo ${red} "未找到 $package, 请先在 master 执行 install-kube.sh 生成 slave 安装包"
        exit 1
    fi
    # 动态生成 join 凭据(不复用旧 token)
    local join_command
    join_command=$(kubeadm token create --print-join-command --ttl=0)
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

function list_machines() {
    log "目标机器清单($TARGET_FILE):"
    awk -F: 'NF && $1 !~ /^#/ {printf "  %s@%s:%s\n", $1, $2, ($4 ? $4 : 22)}' "$TARGET_FILE"
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
