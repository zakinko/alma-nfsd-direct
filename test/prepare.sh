#!/bin/sh
# Packages for an NFS server over md RAID + XFS and over ZFS.
set -ex
uname -r
cat /etc/almalinux-release
# Does the kernel the image boots carry the knobs?  Checked before anything is
# installed, so that the answer survives a failure further down.
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
modprobe nfsd
ls /sys/kernel/debug/nfsd || echo "no /sys/kernel/debug/nfsd on $(uname -r)"
dnf -y install epel-release
dnf -y install nfs-utils mdadm xfsprogs fio kernel-devel-$(uname -r)
dnf -y install https://zfsonlinux.org/epel/zfs-release-3-0.el10.noarch.rpm
# The kABI-tracking kmod lags new point releases; fall back to DKMS.
if ! dnf -y --disablerepo=zfs --enablerepo=zfs-kmod install zfs; then
	dnf -y install zfs
fi
modprobe zfs
zfs version
# The newest kernel in the repository, to report whether it has the knobs.
dnf -q repoquery --latest-limit 1 kernel-core
dnf -q changelog kernel-core 2>/dev/null | grep -i -m8 "nfsd.*\(direct\|dontcache\|io_cache\|debugfs\)" || true
