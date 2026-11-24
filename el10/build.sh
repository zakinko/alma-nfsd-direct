#!/bin/sh
# Rebuild nfsd for the running kernel from its own source, with el10/series
# applied unless PATCH=0, and install it under updates/.
set -eu
K=$(uname -r)
V=${K%.x86_64}
W=/var/tmp/el10
S=$(cd "$(dirname "$0")" && pwd)
mkdir -p $W && cd $W
dnf -y -q install gcc make bison flex elfutils-libelf-devel openssl-devel bc perl cpio xz git \
	kernel-devel-$K dwarves >/dev/null
R=$(sed 's/[^0-9.]//g' /etc/almalinux-release)
curl -fsSLO "https://vault.almalinux.org/$R/BaseOS/Source/Packages/kernel-$V.src.rpm"
rpm2cpio kernel-*.src.rpm | cpio -idm --quiet 'linux-*.tar.xz'
T=$(ls linux-*.tar.xz)
D=${T%.tar.xz}
tar xJf $T $D/fs/internal.h $D/fs/nfsd
cd $D
if [ "${PATCH:-1}" = 1 ]; then
	git init -q
	for p in $S/series/*.patch; do
		git apply --verbose "$p" </dev/null
		echo "applied: $(basename $p)"
	done
fi
grep -n -B3 'status = nfsd_file_get_dio_attrs' fs/nfsd/filecache.c
make -s -C /usr/src/kernels/$K M=$PWD/fs/nfsd -j4 modules
U=/lib/modules/$K/updates/el10
mkdir -p $U
cp fs/nfsd/nfsd.ko $U/
depmod -a
modinfo -n nfsd | grep -q updates/el10
echo "PASS: built nfsd.ko, PATCH=${PATCH:-1}, srcversion $(modinfo -F srcversion nfsd)"
