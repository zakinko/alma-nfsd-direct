#!/bin/sh
# The 512 MiB direct READ in run.sh came back different once over RDMA
# NFSv4.2 on the 36-patch kernel and intact on the 46-patch one.  Repeat it,
# the way run.sh does it (nfsd restarted and caches dropped before each READ),
# for both transports and versions, and count how often the data differs and
# where.  Runs last, on the XFS left on /srv/nv.
set -u
fail=0
FAIL() { echo "FAIL: $*"; fail=1; }
N=${N:-8}
D=/sys/kernel/debug/nfsd; T=/sys/kernel/tracing
W=/var/tmp/rr; mkdir -p $W
IF=$(ip -o -4 route show default | awk '{ print $5; exit }')
A=$(ip -o -4 addr show dev "$IF" | awk '{ split($4, a, "/"); print a[1]; exit }')
rdma link show | grep -q rxe0 || FAIL "no rxe0"
echo "/srv/nv *(rw,no_root_squash,sync,fsid=3)" > /etc/exports
F=/srv/nv/rr; dd if=/dev/urandom of=$F bs=1M count=512 conv=fsync status=none; chmod 644 $F
S=$(sha256sum < $F | cut -d' ' -f1)
echo 2 > $D/io_cache_read
echo 1 > $T/events/nfsd/nfsd_read_direct/enable
mkdir -p /mnt/rr
# As run.sh's nmount: NFSv4 mounts get ESTALE right after nfsd restarts.
mnt() {
	for i in 1 2 3 4 5; do
		mount -t nfs -o $1 $A:/srv/nv /mnt/rr 2>/dev/null && return 0
		exportfs -f; sleep 3
	done
	return 1
}
cold() {
	umount /mnt/rr 2>/dev/null
	systemctl stop nfs-server
	sync; echo 3 > /proc/sys/vm/drop_caches
	systemctl start nfs-server; exportfs -ra
	grep -q rdma /proc/fs/nfsd/portlist || echo "rdma 20049" > /proc/fs/nfsd/portlist
	mnt $1
}
for tr in rdma tcp; do for v in 3 4.2; do
	tag="$tr v$v"
	o=vers=$v,rsize=1048576,wsize=1048576
	[ $tr = rdma ] && o=$o,proto=rdma,port=20049
	bad=0; nm=0; how=""
	for i in $(seq 1 $N); do
		cold $o || { nm=$((nm + 1)); continue; }
		echo > $T/trace
		dd if=/mnt/rr/rr of=$W/got bs=1M iflag=direct status=none
		e=$(grep -c nfsd_read_direct $T/trace)
		if [ "$(sha256sum < $W/got | cut -d' ' -f1)" != "$S" ]; then
			bad=$((bad + 1))
			how="$how [$i: $e direct READs, $(stat -c %s $W/got) bytes, $(cmp -l $F $W/got 2>/dev/null | wc -l) differ, first $(cmp $F $W/got 2>&1 | head -1)]"
		fi
	done
	echo "MEASURE $tag: $bad of $((N - nm)) direct 512MiB reads differ, $nm not mounted;$how"
	[ $bad = 0 ] && [ $nm = 0 ] && echo "PASS $tag" || FAIL "$tag"
done; done
umount /mnt/rr 2>/dev/null
echo 0 > $D/io_cache_read
dmesg | grep -iE 'BUG|WARNING: CPU|Oops|general protection|Bad page|rpcrdma|svcrdma' | tail -20
exit $fail
