#!/bin/bash
source ./common.sh

# SSH 免密手动工具: 群控命令(exec/copy/install-slaves)已内置自动免密,
# 本脚本仅作为手动入口(单独生成密钥 / 手动补装免密 / 手动分发文件), 逻辑全部复用 common.sh

action=${1:-}

# 设置 SSH 密钥权限
set_ssh_key_permissions() {
    run_command "chmod 600 $SSH_PRIVATE_RAS_FILE"
    run_command "chmod 644 $SSH_PUBLIC_RAS_FILE"
}

# 生成 SSH 密钥对(如果不存在)
generate_ssh_key() {
    if [ ! -f "$SSH_PRIVATE_RAS_FILE" ]; then
        log "生成新的 SSH 密钥对..."
        if run_command "ssh-keygen -t rsa -b 4096 -N '' -f $SSH_PRIVATE_RAS_FILE"; then
            log "SSH 密钥对生成成功。"
            set_ssh_key_permissions
        else
            color_echo ${red} "SSH 密钥对生成失败,请检查相关权限。"
            exit 1
        fi
    else
        color_echo ${fuchsia} "SSH 密钥对已存在,跳过生成步骤,修改权限"
        set_ssh_key_permissions
    fi
}

# 主程序入口
main_entrance() {
    case "${action}" in
        generate_ssh_key)
            generate_ssh_key
            ;;
        setup_ssh_for_targets)
            ensure_passwordless
            ;;
        copy_file_to_machines)
            copy_file_to_machines "$2" "${3:-$DEFAULT_SSH_TARGET_PATH}"
            ;;
    esac
}

# 调用主程序
main_entrance "$@"
