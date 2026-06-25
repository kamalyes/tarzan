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
    # 包存在性按需检查: 只有待安装(fresh)机器需要安装包, 已加入机器在包缺失时也应正常跳过
    if [ ! -f "$package" ]; then
        color_echo ${red} "未找到 $package, 请先在 master 执行 install-kube.sh 生成 slave 安装包"
        return 1
    fi
    # scp 非交互模式无进度条, 预告包大小给出传输时长预期, 传完回显耗时(传输实现走 common.sh remote_copy: 优先 rsync 断点续传)
    local pkg_size=$(du -h "$package" | awk '{print $1}')
    local start_ts=$(date +%s)
    log "[$user@$host] 分发 slave 安装包(${pkg_size}, 大文件公网传输需静默等待数分钟)"
    remote_copy "$user" "$host" "$port" "$package" "~/" || {
        color_echo ${red} "[$user@$host] 安装包分发失败"
        return 1
    }
    local cost=$(( $(date +%s) - start_ts ))
    log "[$user@$host] 安装包分发完成(耗时 $((cost/60))分$((cost%60))秒)"
    # 拆两步回显: 解压在目标机执行且无输出(吃目标机 CPU/磁盘, 与 master 无关), 与 install-kube.sh 阶段分开才能定位等待点
    log "[$user@$host] 远程解压安装包(${pkg_size}, 解压在目标机执行, 每 15 秒探测远端 tar 进程)"
    # 并行监控: 直接查远端 tar 进程判活(比大小稳定更直接), 进程消失即解压结束
    (
        while true; do
            sleep 15
            # set -e 下命令替换失败会杀掉本监控子 shell, 必须兜底
            # pgrep 模式用 [t]ar 规避自匹配(远端 shell 的命令行本身含 tar -xzf 字样)
            state=$(timeout 15 ssh $SSH_OPTS -p "$port" "$user@$host" \
                "if pgrep -f '[t]ar -xzf.*${NODE_PACKAGE_PATH}' >/dev/null 2>&1; then du -sh ~/${NODE_PACKAGE_PATH} 2>/dev/null; else echo __DONE__; fi" 2>/dev/null || true)
            case "$state" in
                __DONE__)
                    echo "  [$user@$host] 远端解压进程已结束(若久无后续输出为 ssh 会话僵死, 可 Ctrl+C 后重跑, 幂等)"
                    break
                    ;;
                "") : ;;
                *) echo "  [$user@$host] 解压中, 已写入: ${state}" ;;
            esac
        done
    ) &
    local monitor_pid=$!
    # 解压是短时 IO 操作, 单独收紧超时(默认 300s, 不复用 3600s 的安装级超时), 失败时提示重跑可跳过
    timeout 300 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
        "tar -xzf ~/${NODE_PACKAGE_PATH}.tar.gz -C ~" || {
        # set -e 下 kill/wait 失败(进程已退出)会误杀主脚本, 必须兜底
        kill $monitor_pid 2>/dev/null || true
        color_echo ${red} "[$user@$host] 安装包解压失败, 重跑 install-slaves 即可(已传文件不重传, 解压幂等覆盖)"
        return 1
    }
    kill $monitor_pid 2>/dev/null || true
    wait $monitor_pid 2>/dev/null || true
    log "[$user@$host] 安装包解压完成"
    log "[$user@$host] 远程执行 install-kube.sh --join(安装日志将流式回显)"
    timeout $SSH_EXEC_TIMEOUT ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
        "cd ~/$NODE_PACKAGE_PATH && /bin/bash install-kube.sh --join -y --masterip $masterip --token $token --discovery-token-ca-cert-hash $hash" || {
        color_echo ${red} "[$user@$host] slave 安装失败"
        return 1
    }
    log "[$user@$host] slave 安装完成"
    # 分发 master 的 admin.conf 作为 slave 的 kubectl 凭证(增强体验, 失败不阻塞节点加入)
    log "[$user@$host] 分发 kubectl 凭证(支持在该机使用 kubectl 管理集群)"
    timeout 60 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
        "mkdir -p ~/.kube && cat > ~/.kube/config && chmod 600 ~/.kube/config" < "$KUBE_ADMIN_CONFIG_FILE" \
        || color_echo ${yellow} "[$user@$host] kubectl 凭证分发失败(不影响集群加入, 可手动拷贝 master 的 $KUBE_ADMIN_CONFIG_FILE 到该机 ~/.kube/config)"
    log "[$user@$host] 全部完成"
}

# 一键安装所有 slave: 免密自举后动态生成 join 凭据(kubeadm token), 批量分发安装
function install_slaves() {
    ensure_passwordless
    local package="${NODE_PACKAGE_PATH}.tar.gz"
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
