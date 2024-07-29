#!/usr/bin/env bash

__CURRENT_DIR=$(
  cd "$(dirname "$0")"
  pwd
)

TZ_BASE=${TZ_BASE:-/opt/tarzan}

#######color code########
red="31m"  
green="32m"
yellow="33m" 
blue="36m"
fuchsia="35m"

IMAGE_FILE_PATH="offline/images/images.lock"  

function log() {
    message="[Tarzan Log]: $1 "
    echo -e "\033[32m## ${message} \033[0m\n" 2>&1 | tee -a ${__CURRENT_DIR}/install.log
}

function color_echo() {
  echo -e "\033[$1${@:2}\033[0m" 2>&1 | tee -a ${__CURRENT_DIR}/install.log
}

function run_command() {
    echo ""
    local command=$1
    color_echo "$command"
    echo $command | bash
}