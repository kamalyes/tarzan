#!/bin/bash
NEXUS_URL="http://119.29.213.183:18081"

echo -e "开始更新CentoSBase Repo地址为私有="
mkdir /etc/yum.repos.d/bak && mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/bak
cat <<EOF | tee /etc/yum.repos.d/Centos-7.repo
[base]
name=CentOS-$releasever - Base - mirrors.aliyun.com
failovermethod=priority
baseurl=${NEXUS_URL}/repository/yum-group/\$releasever/os/\$basearch/
        ${NEXUS_URL}/repository/yum-group/\$releasever/os/\$basearch/
        ${NEXUS_URL}/repository/yum-group/\$releasever/os/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
 
#released updates 
[updates]
name=CentOS-$releasever - Updates - mirrors.aliyun.com
failovermethod=priority
baseurl=${NEXUS_URL}/repository/yum-group/\$releasever/updates/\$basearch/
        ${NEXUS_URL}/repository/yum-group/\$releasever/updates/\$basearch/
        ${NEXUS_URL}/repository/yum-group/\$releasever/updates/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
 
#additional packages that may be useful
[extras]
name=CentOS-$releasever - Extras - mirrors.aliyun.com
failovermethod=priority
baseurl=${NEXUS_URL}/repository/yum-group/\$releasever/extras/\$basearch/
        ${NEXUS_URL}/repository/yum-group/\$releasever/extras/\$basearch/
        ${NEXUS_URL}/repository/yum-group/\$releasever/extras/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
 
#additional packages that extend functionality of existing packages
[centosplus]
name=CentOS-$releasever - Plus - mirrors.aliyun.com
failovermethod=priority
baseurl=${NEXUS_URL}/repository/yum-group/\$releasever/centosplus/\$basearch/
        ${NEXUS_URL}/repository/yum-group/\$releasever/centosplus/\$basearch/
        ${NEXUS_URL}/repository/yum-group/\$releasever/centosplus/\$basearch/
gpgcheck=1
enabled=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
 
#contrib - packages by Centos Users
[contrib]
name=CentOS-$releasever - Contrib - mirrors.aliyun.com
failovermethod=priority
baseurl=${NEXUS_URL}/repository/yum-group/\$releasever/contrib/\$basearch/
        ${NEXUS_URL}/repository/yum-group/\$releasever/contrib/\$basearch/
        ${NEXUS_URL}/repository/yum-group/\$releasever/contrib/\$basearch/
gpgcheck=1
enabled=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
EOF

cat <<EOF | tee /etc/yum.repos.d/epel.repo
[epel]
name=Extra Packages for Enterprise Linux 7 - \$basearch
baseurl=${NEXUS_URL}/repository/yum-group/7/\$basearch
failovermethod=priority
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7

[epel-debuginfo]
name=Extra Packages for Enterprise Linux 7 - \$basearch - Debug
baseurl=${NEXUS_URL}/repository/yum-group/7/\$basearch/debug
failovermethod=priority
enabled=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7
gpgcheck=1

[epel-source]
name=Extra Packages for Enterprise Linux 7 - \$basearch - Source
baseurl=${NEXUS_URL}/repository/yum-group/7/SRPMS
failovermethod=priority
enabled=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7
gpgcheck=1
EOF
# 添加docker-ce软件源信息
yum clean all && yum makecache
echo -e "更新CentoSBase Repo地址成功="
