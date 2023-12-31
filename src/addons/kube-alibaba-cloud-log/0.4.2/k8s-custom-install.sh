#!/bin/bash

ROOTDIR=$(cd $(dirname $0) && pwd)

kubeconfig=""

kubectlcmd="kubectl"


# initArch discovers the architecture for this system.
initArch() {
  ARCH=$(uname -m)
  case $ARCH in
    armv5*) ARCH="armv5";;
    armv6*) ARCH="armv6";;
    armv7*) ARCH="arm";;
    aarch64) ARCH="arm64";;
    x86) ARCH="386";;
    x86_64) ARCH="amd64";;
    i686) ARCH="386";;
    i386) ARCH="386";;
  esac
}

# initOS discovers the operating system for this system.
initOS() {
  OS=$(echo `uname`|tr '[:upper:]' '[:lower:]')

  case "$OS" in
    # Minimalist GNU for Windows
    mingw*|cygwin*) OS='windows';;
  esac
}

# runs the given command as root (detects if we are root already)
runAsRoot() {
  if [ $EUID -ne 0 -a "$USE_SUDO" = "true" ]; then
    sudo "${@}"
  else
    "${@}"
  fi
}

verifySupported() {
  local supported="linux-386\nlinux-amd64\nlinux-arm\nlinux-arm64\nlinux-ppc64le\nlinux-s390x\ndarwin-amd64"
  if ! echo "${supported}" | grep -q "${OS}-${ARCH}"; then
    echo "Current script does not support for ${OS}-${ARCH}."
    exit 1
  fi
}

funcGetSelect() {
  valuename=$1
  eval value='$'$valuename
  shift
  for arg in $@; do
    if [ x$arg == x$value ]; then
      echo use $valuename:$arg
      return
    fi
  done
  if [ x$value != x ]; then
    echo unsupport option $valuename :$value
  fi
  if [ $# == 0 ]; then
    echo select $valuename error!
    exit
  fi
  echo -e "\nselect your $valuename"
  select SELECTTEMP in $@; do
    if [ $SELECTTEMP ]; then
      eval $valuename=$SELECTTEMP
      echo use $valuename:$SELECTTEMP
      break
    else
      echo error input $SELECTTEMP
    fi
  done
}

checkHelm() {
  helmPkgPath=./helm.tar.gz
  helmPath=./helm/helm-$OS-$ARCH
  if [ -f "$helmPath" ]; then
      echo "$helmPath exists."
  else
    tar zxvf $helmPkgPath -C ./
  fi
}

checkKubeConfig() {
  kubectl version
  if [ $? != 0 ]; then
    echo "[ENV] Kubectl has not been installed, please install it before installing Logtail components"
    exit 1
  fi
  if [[ $kubeconfig != "" ]]; then
    echo "use kubeconfig $kubeconfig"∫
    kubectlcmd="kubectl --kubeconfig=$kubeconfig"
  fi
}

emptyMustParams=false
checkMustParams() {
  find_str=$1:
  str=`grep $find_str values.yaml`
  str=${str#*${find_str}} 
  if [ -z $str ] || [ $str == "" ];then
      echo empty $1
      emptyMustParams=true
  fi
}


getNameSpace() {
  find_str=NameSpace:
  str=`grep $find_str values.yaml`
  str=${str#*${find_str}} 
  echo $str
}

confirmInput() {
  echo "====== your input start ====="
  grep "SlsProjectName" values.yaml
  grep "Region" values.yaml
  grep "AliUid" values.yaml
  grep "AccessKeyID" values.yaml
  grep "AccessKeySecret" values.yaml
  echo "====== your input end ====="

  checkMustParams "SlsProjectName"
  checkMustParams "Region"
  checkMustParams "AliUid"
  checkMustParams "AccessKeyID"
  checkMustParams "AccessKeySecret"

  if [ $emptyMustParams == true ];then
    echo "please confirm your input"
    exit
  fi

  echo "please confirm your input is valid?"
  funcGetSelect confirm yes no
  if [ "$confirm" == no ]; then
    echo "cancel uninstall"
    exit
  fi
  confirm=""
}


initArch
initOS
verifySupported
checkHelm

checkKubeConfig
getNameSpace

rm -rf result
confirmInput
$helmPath template . --output-dir ./result --debug

echo `ls -l $ROOTDIR/result`


getNameSpace() {
  find_str=NameSpace:
  str=`grep $find_str values.yaml`
  str=${str#*${find_str}}
  echo $str
}

namespace=$(getNameSpace)

getLogConfiguration() {
  cm=$(kubectl get configmap alibaba-log-configuration -n ${namespace} -o yaml 2>&1)
  echo "$cm"
}

configuration=$(getLogConfiguration)

getOldParms() {
  find_str="$1:"
  str=`echo "$configuration" | grep "$find_str"`
  str=${str#*${find_str}}
  echo $str
}

getNewParms() {
  find_str="$1:"
  str=`grep "$find_str" result/logtail-k8s-all/templates/0-alicloud-log-configuration.yaml`
  str=${str#*${find_str}}
  echo $str
}

inconsistentParams=false
compareOldAndNewString() {
  oldParm=$(getOldParms $1)
  oldParm="${oldParm//\"/}"
  newParm=$(getNewParms "$1")
  newParm="${newParm//\"/}"
  if [ "$oldParm" != "$newParm" ]; then
    echo "inconsistent params $1, old: $oldParm new: $newParm"
    inconsistentParams=true
  fi
}

compareOldAndNewInt() {
  oldParm=$(getOldParms $1)
  oldParm=${oldParm//\"/}
  newParm=$(getNewParms "$1")
  newParm=${newParm//\"/}
  if (( oldParm > newParm )); then
    echo "inconsistent resource params $1, old: $oldParm new: $newParm"
    inconsistentParams=true
  fi
}

version=$(getOldParms "logtail-deployment")
if [ "$version" == "v2" ]; then
  echo "normal update with new script"
else
   echo "you have an old alibaba-log-configuration in your cluster, please confirm you are upgrading your logtail with new script?"
   funcGetSelect confirm yes no
   if [ "$confirm" == no ]; then
    echo "cancel uninstall"
    exit
  fi
  echo "checking upgrade"
  compareOldAndNewString log-ali-uid
  compareOldAndNewString log-config-path
  compareOldAndNewString log-endpoint
  compareOldAndNewString log-machine-group
  compareOldAndNewString log-project
  compareOldAndNewString access-key-id
  compareOldAndNewString access-key-secret

  compareOldAndNewInt " max-bytes-per-sec"
  compareOldAndNewInt " mem-limit"
  compareOldAndNewInt " cpu-core-limit"
  compareOldAndNewInt " send-requests-concurrency"

  if [ $inconsistentParams == true ];then
    echo "please confirm your new configmap(result/logtail-k8s-all/templates/0-alicloud-log-configuration.yaml), there are some inconsistent params with old configmap, may cause problems"
    exit
  fi
  echo "all upgrade check passed"
fi