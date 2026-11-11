#!/bin/sh
# Rebuild sunrpc and nfsd for the running kernel from its own source with the
# series applied, and install them under updates/ so that modprobe picks them.
set -eu
K=$(uname -r)
V=${K%.x86_64}
W=/var/tmp/el9
S=$(cd "$(dirname "$0")" && pwd)
mkdir -p $W && cd $W
echo "== kernel $K"
if ! dnf -q download --source --enablerepo=baseos-source "kernel-$V" 2>/dev/null; then
	R=$(sed 's/[^0-9.]//g' /etc/almalinux-release)
	for u in "https://vault.almalinux.org/$R/BaseOS/Source/Packages" \
		 "https://repo.almalinux.org/vault/$R/BaseOS/Source/Packages"; do
		curl -fsSLO "$u/kernel-$V.src.rpm" && break
	done
fi
ls -l kernel-*.src.rpm
rpm2cpio kernel-*.src.rpm | cpio -idm --quiet 'linux-*.tar.xz'
T=$(ls linux-*.tar.xz)
D=${T%.tar.xz}
tar xJf $T $D/fs/nfsd $D/net/sunrpc $D/include/linux/sunrpc $D/include/trace/misc/fs.h
cd $D
ci() { git -c user.name=ci -c user.email=ci@localhost commit -qm "$1"; }
git init -q && git add fs net include && ci base
echo "== applying $(ls $S/series/*.patch | wc -l) commits to $D"
fail=0
for p in $S/series/*.patch; do
	if git am -q --3way "$p" </dev/null >/dev/null 2>&1; then
		echo "applied: $(basename $p)"
		continue
	fi
	git am --abort 2>/dev/null || true
	if git apply "$p" </dev/null 2>/dev/null; then
		echo "applied with fuzz: $(basename $p)"
		git add fs net include && ci "$(basename $p)"
		continue
	fi
	echo "REJECT: $(basename $p)"
	git apply --reject "$p" </dev/null 2>&1 | grep -v '^Checking\|^Applied\|succeeded' || true
	find . -name '*.rej' -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \;
	fail=1
	break
done
[ $fail = 0 ] || { echo "FAIL: series does not apply to $D"; exit 1; }

# A copy of the build tree whose headers carry the series' header changes.
KD=$W/kd
rm -rf $KD && cp -a /usr/src/kernels/$K $KD
cp include/linux/sunrpc/*.h $KD/include/linux/sunrpc/
cp include/trace/misc/fs.h $KD/include/trace/misc/fs.h
make -s -C $KD M=$PWD/net/sunrpc -j4 modules
make -s -C $KD M=$PWD/fs/nfsd KBUILD_EXTRA_SYMBOLS=$PWD/net/sunrpc/Module.symvers -j4 modules
U=/lib/modules/$K/updates/el9
mkdir -p $U
find net/sunrpc fs/nfsd -name '*.ko' -exec cp {} $U/ \;
ls $U
depmod -a
echo "PASS: built and installed $(ls $U | wc -l) modules"
