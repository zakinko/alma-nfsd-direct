#!/bin/sh
# Misaligned user O_DIRECT on stacking drivers: dm-linear, dm-mirror and md
# raid1 over loop devices, the bare loop device, and a file on XFS over
# dm-mirror for the iomap path (written out first: a hole is zeroed by
# iomap without a bio, so a misaligned read of one succeeds).  Every case must be refused with EINVAL or
# succeed with intact data, inside a time bound; a hang shows up as the
# timeout.  Afterwards no mirror leg may have been failed for a rejected bio.
set -u
fail=0
FAIL() { echo "FAIL: $*"; fail=1; }
B=/var/tmp/dioal
S=$(cd "$(dirname "$0")" && pwd)
mkdir -p $B && cd $B
gcc -O2 -Wall -o dioal $S/dioal.c || { echo "FAIL: dioal does not build"; exit 1; }
for i in 0 1 2 3 4; do truncate -s 256M img$i; done
L0=$(losetup -f --show img0); L1=$(losetup -f --show img1); L2=$(losetup -f --show img2)
L3=$(losetup -f --show img3); L4=$(losetup -f --show img4)
modprobe dm-mod; modprobe dm-mirror; modprobe raid1
SZ=$(blockdev --getsz $L0)
dmsetup create dioal-lin --table "0 $SZ linear $L0 0"
dmsetup create dioal-mir --table "0 $SZ mirror core 2 1024 nosync 2 $L1 0 $L2 0"
yes | mdadm -q --create /dev/md/dioal --level=1 --raid-devices=2 --metadata=1.2 \
	--assume-clean --run $L3 $L4
mkdir -p mnt
mkfs.xfs -q -f /dev/mapper/dioal-mir && mount /dev/mapper/dioal-mir mnt &&
	dd if=/dev/urandom of=mnt/f bs=1M count=16 conv=fsync status=none ||
	FAIL "xfs on dm-mirror"
echo "dma_alignment: loop $(cat /sys/block/${L0#/dev/}/queue/dma_alignment 2>/dev/null)," \
	"dm $(cat /sys/block/$(basename $(readlink -f /dev/mapper/dioal-lin))/queue/dma_alignment 2>/dev/null)"
for d in $L0 /dev/mapper/dioal-lin /dev/mapper/dioal-mir /dev/md/dioal mnt/f; do
	lbs=512; [ -b $d ] && lbs=$(blockdev --getss $d)
	timeout 120 ./dioal $d $lbs; rc=$?
	[ $rc = 124 ] && FAIL "$d: timed out (hang)"
	[ $rc != 0 ] && [ $rc != 124 ] && FAIL "$d: dioal exited $rc"
done
st=$(dmsetup status dioal-mir); echo "dm-mirror: $st"
case "$st" in *" AA "*) echo "PASS: dm-mirror kept both legs" ;; *) FAIL "dm-mirror failed a leg" ;; esac
md=$(grep -A1 '^md' /proc/mdstat | tr '\n' ' '); echo "md: $md"
case "$md" in *"[UU]"*) echo "PASS: md raid1 kept both legs" ;; *) FAIL "md raid1 failed a leg" ;; esac
dmesg | grep -iE 'BUG|WARNING|hung task|blk_update_request|I/O error' | tail -10
umount mnt; mdadm -q --stop /dev/md/dioal; dmsetup remove dioal-mir dioal-lin
losetup -d $L0 $L1 $L2 $L3 $L4; cd / && rm -rf $B
[ $fail = 0 ] && echo "PASS: misaligned direct I/O on stacking drivers"
exit $fail
