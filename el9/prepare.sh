#!/bin/sh
# Build tools, the test packages and, if it installs, ZFS.
set -ex
uname -r
cat /etc/almalinux-release
dnf -y install epel-release dnf-plugins-core
dnf -y install bpftrace nfs-utils mdadm xfsprogs gcc make bison flex elfutils-libelf-devel \
	openssl-devel bc perl cpio xz git kernel-devel-$(uname -r) \
	kernel-modules-extra-$(uname -r) nvme-cli
dnf -y install https://zfsonlinux.org/epel/zfs-release-2-8.el9.noarch.rpm || true
if dnf -y --disablerepo=zfs --enablerepo=zfs-kmod install zfs; then :
else dnf -y install zfs || echo "zfs did not install"; fi
modprobe zfs && zfs version || echo "no zfs"
