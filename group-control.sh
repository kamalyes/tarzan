#!/usr/bin/env bash
source ./common.sh

# 群控脚本: 基于 conf/ssh_hosts 批量远程执行命令 / 分发文件 / 一键安装所有 slave
# 连接/免密自举/批量执行分发等通用能力在 common.sh, 这里只保留 slave 加入集群的业务流程

action=$1

# 遍历目标机器执行回调, 回调参数: user host password port ...
# 单台失败不中断其余机器, 全部处理完后聚合返回失败状态
function for_each_machine() {
    local exec_fn=$1
    shift
    local line user host password port hostname failed=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        # user:host:pass[:port[:hostname]] —— 第 5 段主机名仅作备注, 兼容带主机名的清单
        IFS=':' read -r user host password port hostname <<< "$line"
        port=${port:-$DEFAULT_SSH_PORT}
        hostname=${hostname:-}
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
    # 幂等预检(探测逻辑在 common.sh probe_node_state): master 与已加入节点自动跳过,
    # half_joined(机器有残留但集群无记录)不能跳过, 否则该机器永久卡在清单里
    local node_state
    node_state=$(probe_node_state "$user" "$host" "$port")
    if [[ "$node_state" == "master" ]]; then
        log "[$user@$host] 是 master 节点, 无需加入, 跳过"
        return 0
    fi
    if [[ "$node_state" == "half_joined" ]]; then
        color_echo ${yellow} "[$user@$host] 机器有安装残留但集群无此节点(节点被删或加入中断), 请先执行 ./group-control.sh remove-slave $host 清理后重跑"
        return 1
    fi
    if [[ "$node_state" == "joined" ]]; then
        log "[$user@$host] 已加入集群, 跳过(如需重新加入请先执行 ./group-control.sh remove-slave $host)"
        return 0
    fi
    # 端口预检: 在分发前探测 slave -> master API 可达性, 提前暴露安全组问题
    # (masterip 为 ip:port 原样传递, 拆解端口; 无端口时 kubeadm 默认 6443)
    local api_host="${masterip%%:*}" api_port="${masterip##*:}"
    [[ "$api_port" == "$api_host" ]] && api_port="6443"
    if ! timeout -k 5 20 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
        "timeout 5 bash -c '</dev/tcp/$api_host/$api_port' >/dev/null 2>&1" 2>/dev/null; then
        color_echo ${red} "[$user@$host] 无法访问 master API($api_host:$api_port), 请在安全组放行后重跑(TCP $api_port, 源: 该节点内网IP)"
        return 1
    fi
    log "[$user@$host] master API($api_host:$api_port) 可达"
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
    log "[$user@$host] 远程解压安装包(${pkg_size}, 解压在目标机执行, 每 3 秒探测远端 tar 进程)"
    # 后台发起 + 主循环轮询进程判活: 前台 ssh 会话在部分云环境僵死(远端命令完成后会话不返回, 已复现多次),
    # nohup 让 tar 脱离会话独立运行, 轮询每轮都是新短会话, 彻底绕开僵死; ^C 也随主循环即时响应
    # timeout -k 5: 僵死会话阻塞在 socket 读取时 SIGTERM 不可达, timeout 只发信号不等退出, 必须补刀 SIGKILL 才能保证返回
    # </dev/null: 后台 tar 若继承会话 stdin, sshd 因管道未全关而等不到会话结束, 发起命令也随之僵死
    timeout -k 5 15 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
        "nohup tar -xzf ~/${NODE_PACKAGE_PATH}.tar.gz -C ~ </dev/null >/dev/null 2>&1 &" || {
        color_echo ${red} "[$user@$host] 解压命令发起失败, 重跑 install-slaves 即可(已传文件不重传, 解压幂等覆盖)"
        return 1
    }
    log "[$user@$host] 解压命令已发起(目标机后台运行), 开始轮询探测"
    local extract_deadline=$(( $(date +%s) + 300 ))
    while true; do
        sleep 3
        # pgrep 模式用 [t]ar 规避自匹配(远端 shell 的命令行本身含 tar -xzf 字样)
        state=$(timeout -k 5 15 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
            "if pgrep -f '[t]ar -xzf.*${NODE_PACKAGE_PATH}' >/dev/null 2>&1; then du -sh ~/${NODE_PACKAGE_PATH} 2>/dev/null; else echo __DONE__; fi" 2>/dev/null || true)
        case "$state" in
            __DONE__)
                # 进程消失后校验解压产物(tar 异常退出进程同样会消失, 不能只看进程判活)
                if timeout -k 5 15 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" "test -f ~/$NODE_PACKAGE_PATH/install-kube.sh" 2>/dev/null; then
                    break
                fi
                color_echo ${red} "[$user@$host] 安装包解压失败, 重跑 install-slaves 即可(已传文件不重传, 解压幂等覆盖)"
                return 1
                ;;
            "") echo "  [$user@$host] 探测会话无响应(链路抖动), 持续重试中..." ;;
            *) echo "  [$user@$host] 解压中, 已写入: ${state}" ;;
        esac
        if [ "$(date +%s)" -ge "$extract_deadline" ]; then
            color_echo ${red} "[$user@$host] 解压超时(300s), 重跑 install-slaves 即可(解压幂等覆盖)"
            return 1
        fi
    done
    log "[$user@$host] 安装包解压完成"
    # node name 直接取 conf/ssh_hosts 第5列的规划主机名(单一清单: 连接信息与主机名规划同文件, conf/hosts 由其派生)
    local node_name=$(get_planned_hostname "$host")
    local hname_args=""
    if [[ -n "$node_name" ]]; then
        hname_args="-hname $node_name"
        log "[$user@$host] 远程执行 install-kube.sh --join(节点名 $node_name 取自 conf/ssh_hosts, 安装日志将流式回显)"
    else
        color_echo ${yellow} "[$user@$host] conf/ssh_hosts 未配置 $host 的主机名(第5列), 以机器默认主机名加入集群(建议补充后重跑)"
        log "[$user@$host] 远程执行 install-kube.sh --join(默认主机名, 安装日志将流式回显)"
    fi
    # --node-ip 传清单 IP: 异地公网组网(机器不在同一 VPC)时, kubelet/flannel/longhorn 按该 IP 互联,
    # 内网注册(默认网卡 IP)会让 apiserver->kubelet 10250 / VXLAN 8472 / 副本同步全部超时
    timeout -k 5 $SSH_EXEC_TIMEOUT ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
        "cd ~/$NODE_PACKAGE_PATH && /bin/bash install-kube.sh --join -y $hname_args --node-ip $host --masterip $masterip --token $token --discovery-token-ca-cert-hash $hash" || {
        color_echo ${red} "[$user@$host] slave 安装失败"
        return 1
    }
    log "[$user@$host] slave 安装完成"
    # 分发 master 的 admin.conf 作为 slave 的 kubectl 凭证(增强体验, 失败不阻塞节点加入)
    log "[$user@$host] 分发 kubectl 凭证(支持在该机使用 kubectl 管理集群)"
    timeout -k 5 60 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
        "mkdir -p ~/.kube && cat > ~/.kube/config && chmod 600 ~/.kube/config" < "$KUBE_ADMIN_CONFIG_FILE" \
        || color_echo ${yellow} "[$user@$host] kubectl 凭证分发失败(不影响集群加入, 可手动拷贝 master 的 $KUBE_ADMIN_CONFIG_FILE 到该机 ~/.kube/config)"
    log "[$user@$host] 全部完成"
}

# 单台 slave 解散: master 侧摘除节点记录 + 远程本机重置并删除安装目录(与 slave_install 对称的逆向流程)
function slave_remove() {
    local user=$1 host=$2 password=$3 port=$4
    if is_local_host "$host"; then
        color_echo ${fuchsia} "[$user@$host] 是 master 本机, 不参与单机解散(整体解散请用 destroy-cluster)"
        return 0
    fi
    # 幂等预检: master 机器拒绝对称解散, 未加入过集群的机器无需解散
    # half_joined(机器有残留但集群无记录)正是解散要处理的场景, 放行走清理流程
    local node_state
    node_state=$(probe_node_state "$user" "$host" "$port")
    if [[ "$node_state" == "master" ]]; then
        color_echo ${fuchsia} "[$user@$host] 是 master 节点, 不参与单机解散(整体解散请用 destroy-cluster)"
        return 0
    fi
    if [[ "$node_state" != "joined" && "$node_state" != "half_joined" ]]; then
        log "[$user@$host] 未加入集群, 无需解散"
        return 0
    fi
    if ! prompt_for_confirmation "[$user@$host]" "解散该节点(摘除集群记录 + 清理机器)"; then
        return 0
    fi
    # 节点名与 slave_install 同源: ssh_hosts 第5列规划名, 缺失时用远端当前主机名(按加入时的实际名摘除记录)
    local node_name=$(get_planned_hostname "$host")
    [[ -z "$node_name" ]] && node_name=$(timeout -k 5 15 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" "hostname" 2>/dev/null)
    log "[$user@$host] master 侧摘除节点记录: $node_name"
    kubectl delete node "$node_name" 2>/dev/null || log "节点 $node_name 已不在集群记录中"
    # 远程本机重置(reset_local 不做节点删除, 节点记录已由上面精确摘除)
    # 清理耗时远短于安装, 专用 600s 超时兜底($SSH_EXEC_TIMEOUT 3600s 等于无兜底, 远端卡死时干等一小时)
    timeout -k 5 600 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
        "if [ -d ~/$NODE_PACKAGE_PATH ]; then cd ~/$NODE_PACKAGE_PATH && /bin/bash clean-residue.sh -y reset_local; fi" || true
    log "[$user@$host] 删除安装目录与安装包"
    timeout -k 5 60 ssh $SSH_OPTS $SSH_ALIVE_OPTS -p "$port" "$user@$host" \
        "rm -rf ~/$NODE_PACKAGE_PATH ~/${NODE_PACKAGE_PATH}.tar.gz" || true
    color_echo ${green} "[$user@$host] 已解散(如不再纳管请在 conf/ssh_hosts 注释该行)"
    return 0
}

# 解散单台 slave(按 IP 或 ssh_hosts 第5列主机名定位目标)
function remove_single_slave() {
    local target=$1
    if [ -z "$target" ]; then
        color_echo ${red} "Usage: $0 remove-slave <ip|主机名>"
        exit 1
    fi
    local line=$(awk -F: -v t="$target" '{sub(/#.*/,"")} $2==t || $5==t {print; exit}' "$TARGET_FILE")
    if [ -z "$line" ]; then
        color_echo ${red} "conf/ssh_hosts 中未找到目标: $target(可按 IP 或第5列主机名匹配)"
        exit 1
    fi
    local user host password port discard
    IFS=':' read -r user host password port discard <<< "$line"
    ensure_passwordless
    slave_remove "$user" "$host" "$password" "${port:-$DEFAULT_SSH_PORT}"
}

# 解散整个集群: 逐台 slave 清理解散, 最后重置 master 本机
function destroy_cluster() {
    echo -e "\033[31m警告: 将解散整个集群, 所有机器(master + slave)的 K8s 组件与配置将被清除, 不可恢复!\033[0m"
    read -p "确认解散整个集群? 输入 yes 继续: " __confirm </dev/tty
    if [[ "$__confirm" != "yes" ]]; then
        color_echo ${yellow} "已取消"
        exit 0
    fi
    ensure_passwordless
    for_each_machine slave_remove
    # master 本机最后重置(all 含清空节点记录, 此时 slave 均已摘除, 剩余记录随本机重置一并清除)
    log "本机(master)重置"
    /bin/bash clean-residue.sh -y all
    color_echo ${green} "集群已解散, 如需重建重新执行 install-kube.sh 即可"
}

# longhorn 默认副本数随集群节点数收敛(副本须落不同节点, 超过节点数调度不满会 Degraded; 生产标准上限 3)
# 节点数不足 3 时取节点数(单 master=1 保证 PVC 可绑定), 只影响新建卷, 已有卷副本不变
function sync_longhorn_replicas() {
    # 未装 longhorn 时跳过(无 settings 资源)
    kubectl -n longhorn-system get settings default-replica-count >/dev/null 2>&1 || return 0
    local node_count replica_count current
    # 节点注册即计入(不筛 Ready: 刚 join 的节点短暂 NotReady 属瞬态, 副本调度由 longhorn 在节点就绪后自行补齐)
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$node_count" -eq 0 ] || [ -z "$node_count" ]; then
        return 0
    fi
    if [ "$node_count" -ge 3 ]; then
        replica_count=3
    else
        replica_count=$node_count
    fi
    current=$(kubectl -n longhorn-system get settings default-replica-count -o jsonpath='{.value}' 2>/dev/null)
    if [ "$current" = "$replica_count" ]; then
        log "longhorn 默认副本数已是 $replica_count(当前节点数 $node_count), 无需调整"
        return 0
    fi
    if kubectl -n longhorn-system patch settings default-replica-count -p "{\"value\":\"$replica_count\"}" --type=merge >/dev/null 2>&1; then
        log "longhorn 默认副本数已按节点数收敛为 $replica_count(节点数 $node_count, 上限 3; 只影响新建卷, 已有卷不变)"
    else
        color_echo ${yellow} "longhorn 默认副本数调整失败(不影响节点加入, 可手动: kubectl -n longhorn-system patch settings default-replica-count -p '{\"value\":\"$replica_count\"}' --type=merge)"
    fi
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
    # 节点加入完成后联动收敛 longhorn 默认副本数(可调度节点变多, 新建卷的副本冗余自动跟上; 未装 longhorn 时静默跳过)
    sync_longhorn_replicas
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
        remove-slave)
            remove_single_slave "$2"
            ;;
        destroy-cluster)
            destroy_cluster
            ;;
        *)
            echo "Usage: $0 {hosts|exec <command>|copy <local-file> [remote-path]|install-slaves|remove-slave <ip|主机名>|destroy-cluster}"
            exit 1
            ;;
    esac
}

main_entrance "$@"
