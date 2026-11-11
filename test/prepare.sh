#!/bin/sh
# Packages for an NFS server over md RAID + XFS and over ZFS.
set -ex
uname -r
cat /etc/almalinux-release
dnf -y install epel-release
dnf -y install nfs-utils mdadm xfsprogs util-linux fio kernel-devel-$(uname -r)
dnf -y install https://zfsonlinux.org/epel/zfs-release-3-0.el10.noarch.rpm
# The kABI-tracking kmod lags new point releases; fall back to DKMS.
if ! dnf -y --disablerepo=zfs --enablerepo=zfs-kmod install zfs; then
	dnf -y install zfs
fi
modprobe zfs
zfs version
