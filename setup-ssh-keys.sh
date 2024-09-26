#!/bin/bash
source ./common.sh

# 从命令行参数获取自定义端口和密码
action=${1:-}

# 检查配置文件是否存在
if [ ! -f "$TARGET_FILE" ]; then
    log "配置文件 $TARGET_FILE 不存在,请创建该文件并添加目标机器。"
    exit 1
fi

# 读取目标机器
mapfile -t TARGET_MACHINES < "$TARGET_FILE"

# 生成 SSH 密钥对（如果不存在）
generate_ssh_key() {
    if [ ! -f "$SSH_PRIVATE_RAS_FILE" ]; then
        log "生成新的 SSH 密钥对..."
        if run_command "ssh-keygen -t rsa -b 4096 -N '' -f $SSH_PRIVATE_RAS_FILE"; then
            log "SSH 密钥对生成成功。"
        else
            color_echo ${red} "SSH 密钥对生成失败,请检查相关权限。"
            exit 1
        fi
    else
        color_echo ${fuchsia} "SSH 密钥对已存在,跳过生成步骤,修改权限"
        set_ssh_key_permissions
    fi
}

# 设置 SSH 密钥权限
set_ssh_key_permissions() {
    run_command "chmod 600 $SSH_PRIVATE_RAS_FILE"
    run_command "chmod 644 $SSH_PUBLIC_RAS_FILE"
}

# 检查网络连接和 SSH 服务
check_target() {
    local TARGET=$1
    local PORT=$2
    log "正在检查 $TARGET ..."

    if ping -c 1 "${TARGET#*@}" &> /dev/null; then
        log "网络连接正常。"
        if timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$PORT" "$TARGET" "exit" &> /dev/null; then
            log "SSH 服务已安装并正常运行。"
        else
            color_echo ${red} "SSH 服务未运行或无法访问 $TARGET。"
        fi
    else
        color_echo ${red} "无法访问 $TARGET, 网络连接失败。"
    fi
}

# 复制公钥到目标机器
copy_ssh_key() {
    local TARGET=$1
    local PORT=$2
    local PASSWORD=$3
    log "正在将公钥复制到 $TARGET ..."

    if timeout 5 sshpass -p "$PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no -p "$PORT" "$TARGET"; then
        log "公钥成功复制到 $TARGET。"
    else
        color_echo ${red} "复制公钥到 $TARGET 失败,请检查连接和凭据。"
        return 1  # 添加返回值以指示失败
    fi
}

# 处理目标机器的 SSH 设置
setup_ssh_for_targets() {
    local CUSTOM_PORT=$1
    local CUSTOM_PASSWORD=$2

    for TARGET in "${TARGET_MACHINES[@]}"; do
        IFS=':' read -r USER HOST PASSWORD PORT <<< "$TARGET"

        # 使用自定义端口和密码，或配置文件中的值
        PORT=${CUSTOM_PORT:-${PORT:-$DEFAULT_SSH_PORT}}
        PASSWORD=${CUSTOM_PASSWORD:-${PASSWORD:-$DEFAULT_SSH_PASSWORD}}

        USER_HOST="${USER}@${HOST}"

        # Debug output
        debug_info "$USER" "$HOST" "$PASSWORD" "$PORT"

        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt $SSH_MAX_PORT ]; then
            color_echo ${red} "无效的端口号: $PORT。请检查配置文件中的端口。"
            continue
        fi

        if ! copy_ssh_key "$USER_HOST" "$PORT" "$PASSWORD"; then
            continue  # 如果复制公钥失败，跳过此目标
        fi

        check_target "$USER_HOST" "$PORT"
    done
}

# 复制文件到目标机器
copy_file_to_machines() {
    local FILE=$1
    local TARGET_PATH=$2
    local CUSTOM_PORT=$3
    local CUSTOM_PASSWORD=$4

    for TARGET in "${TARGET_MACHINES[@]}"; do
        copy_file_to_machine "$FILE" "$TARGET" "$TARGET_PATH" "$CUSTOM_PORT" "$CUSTOM_PASSWORD"
    done
}

# 复制文件到单个目标机器
copy_file_to_machine() {
    local FILE=$1
    local TARGET=$2
    local TARGET_PATH=$3
    local CUSTOM_PORT=$4
    local CUSTOM_PASSWORD=$5

    # 从目标机器中提取用户、主机、密码、端口
    IFS=':' read -r USER HOST PASSWORD PORT <<< "$TARGET"

    # 使用命令行参数覆盖配置文件中的端口和密码
    PORT=${CUSTOM_PORT:-${PORT:-$DEFAULT_PORT}}
    PASSWORD=${CUSTOM_PASSWORD:-${PASSWORD:-$DEFAULT_PASSWORD}}

    USER_HOST="${USER}@${HOST}"

    # Debug output
    debug_info "$USER" "$HOST" "$PASSWORD" "$PORT"

    # 确保文件存在
    if [ ! -f "$FILE" ]; then
        color_echo ${red} "文件 $FILE 不存在,无法复制到 $USER_HOST。"
        return
    fi

    log "正在将文件 $FILE 复制到 $USER_HOST ..."
    if timeout 5 sshpass -p "$PASSWORD" scp -o BatchMode=yes -o ConnectTimeout=5 -P "$PORT" "$FILE" "$USER_HOST:$TARGET_PATH" ; then
        log "文件 $FILE 成功复制到 $USER_HOST。"
    else
        color_echo ${red} "无法将文件 $FILE 复制到 $USER_HOST,请检查连接和凭据。"
    fi
}

# 在目标机器上执行远程命令
execute_remote_command() {
    local TARGET=$1
    local COMMAND=$2
    local PORT=$3
    local PASSWORD=$4

    # 从目标机器中提取用户、主机
    IFS=':' read -r USER HOST <<< "$TARGET"

    # 使用命令行参数覆盖配置文件中的端口和密码
    PORT=${PORT:-$DEFAULT_SSH_PORT}
    PASSWORD=${PASSWORD:-$DEFAULT_SSH_PASSWORD}

    USER_HOST="${USER}@${HOST}"

    # Debug output
    debug_info "$USER" "$HOST" "$PASSWORD" "$PORT"
    
    # 使用 sshpass 执行远程命令
    if timeout 5 sshpass -p "$PASSWORD" ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$PORT" "$USER_HOST" "$COMMAND"; then
        log "命令 '$COMMAND' 在 $USER_HOST 执行成功。"
    else
        color_echo ${red} "无法在 $USER_HOST 执行命令 '$COMMAND'，请检查连接和凭据。"
    fi
}

# 打印调试信息
debug_info() {
    local USER=$1
    local HOST=$2
    local PASSWORD=$3
    local PORT=$4
    echo "调试信息: USER=$USER, HOST=$HOST, PASSWORD=$PASSWORD, PORT=$PORT"
}

# 主程序入口
main_entrance() {
    case "${action}" in
        generate_ssh_key)
            generate_ssh_key
            ;;
        setup_ssh_for_targets)
            CUSTOM_PORT=${2:-$DEFAULT_SSH_PORT}
            CUSTOM_PASSWORD=${3:-}
            setup_ssh_for_targets "$CUSTOM_PORT" "$CUSTOM_PASSWORD"
            ;;
        copy_file_to_machines)
            FILE=${2:-}
            TARGET_PATH=${3:-$DEFAULT_SSH_TARGET_PATH}
            CUSTOM_PORT=${4:-$DEFAULT_SSH_PORT}
            CUSTOM_PASSWORD=${5:-}
            echo "传入的文件路径：$FILE"
            copy_file_to_machines "$FILE" "$TARGET_PATH" "$CUSTOM_PORT" "$CUSTOM_PASSWORD"
            ;;
        execute_remote_command)
            TARGET=${2:-}
            COMMAND=${3:-}
            CUSTOM_PORT=${4:-$DEFAULT_SSH_PORT}
            CUSTOM_PASSWORD=${5:-}
            execute_remote_command "$TARGET" "$COMMAND" "$CUSTOM_PORT" "$CUSTOM_PASSWORD"
            ;;
    esac
}

# 调用主程序
main_entrance "$@"
