#!/bin/sh
# Build the whole RHEL 9 kernel that the guest runs, from its own source
# with the block-layer prerequisites and the nfsd series applied, and make
# it the default boot entry.  Modules are limited to the ones the test
# loads, so that the build fits in a CI job.
set -eu
K=$(uname -r)
V=${K%.x86_64}
W=/var/tmp/el9k
S=$(cd "$(dirname "$0")" && pwd)
mkdir -p $W && cd $W
echo "== kernel $K"
dnf -q download --source --enablerepo=baseos-source "kernel-$V" 2>/dev/null || {
	R=$(sed 's/[^0-9.]//g' /etc/almalinux-release)
	curl -fsSLO "https://vault.almalinux.org/$R/BaseOS/Source/Packages/kernel-$V.src.rpm"
}
rpm2cpio kernel-*.src.rpm | cpio -idm --quiet 'linux-*.tar.xz'
T=$(ls linux-*.tar.xz); D=${T%.tar.xz}
tar xJf $T
cd $D
# git apply works on a plain directory, outside any repository.
for p in $S/series/*.patch; do
	if git apply "$p" </dev/null 2>/dev/null; then echo "applied: $(basename $p)"
	elif git apply -C1 "$p" </dev/null 2>/dev/null; then echo "applied with one line of context: $(basename $p)"
	else echo "REJECT: $(basename $p)"; git apply --reject "$p" </dev/null 2>&1 | tail -5; exit 1
	fi
done
cp /boot/config-$K .config
# The modules the test uses, loaded so that localmodconfig keeps them.
for m in nfsd nfs nfsv3 nfsv4 rpcrdma rdma_rxe nvmet nvme_loop nvme_fabrics \
	 xfs raid0 md_mod loop configfs ib_core rdma_ucm; do modprobe $m 2>/dev/null || true; done
lsmod > $W/lsmod
yes '' | make -s LSMOD=$W/lsmod localmodconfig >/dev/null
scripts/config -d MODULE_SIG -d MODULE_SIG_ALL -d DEBUG_INFO_BTF \
	--set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
	-d DEBUG_INFO -e DEBUG_INFO_NONE --set-str LOCALVERSION "-nd"
make -s olddefconfig
grep -E '^CONFIG_(NFSD|SUNRPC_XPRT_RDMA|RDMA_RXE|NVME_TARGET_LOOP|XFS_FS|MD_RAID0|BLK_DEV_MD)=' .config
time make -s -j$(nproc) bzImage modules
make -s modules_install
make -s install
N=$(make -s kernelrelease)
grubby --set-default /boot/vmlinuz-$N
echo "PASS: built and installed $N"
