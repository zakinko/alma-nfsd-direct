#!/bin/sh
# With the rebuilt sunrpc and nfsd loaded: does each io_cache mode leave the
# server's cache as it should, and does the data come back intact?  Loop
# devices stand in for NVMe; the client is this machine, using O_DIRECT so that
# only the server's cache is measured (fincore on the exported file for XFS,
# the ARC for ZFS).  NFSv3 and NFSv4.2 take different READ paths, so both run.
set -u
K=$(uname -r)
fail=0
FAIL() { echo "FAIL: $*"; fail=1; }

systemctl stop nfs-server rpc-gssd rpc-statd nfs-idmapd rpcbind.socket rpcbind 2>/dev/null
umount /var/lib/nfs/rpc_pipefs 2>/dev/null
modprobe -r nfsd nfsv4 nfsv3 nfs lockd nfs_acl rpcsec_gss_krb5 auth_rpcgss rpcrdma sunrpc 2>&1
lsmod | grep -E '^(sunrpc|nfsd) ' && FAIL "old modules still loaded"
modprobe nfsd
for m in sunrpc nfsd; do echo "$m: $(modinfo -n $m)"; done
case "$(modinfo -n nfsd) $(modinfo -n sunrpc)" in
*updates/el9/nfsd.ko*updates/el9/sunrpc.ko*) echo "PASS: rebuilt modules are the ones modprobe uses" ;;
*) FAIL "modprobe does not use the rebuilt modules" ;;
esac
grep -q ' xdr_buf_to_bvec$' /proc/kallsyms && echo "PASS: rebuilt sunrpc is loaded" || FAIL "loaded sunrpc lacks xdr_buf_to_bvec"
dmesg | grep -iE 'disagrees|unknown symbol|taint' | tail -5

D=/sys/kernel/debug/nfsd
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
ls -l $D
for k in io_cache_read io_cache_write; do
	for v in 0 1 2; do
		echo $v > $D/$k 2>/dev/null && [ "$(cat $D/$k)" = $v ] || FAIL "$k refuses $v"
	done
	echo 3 > $D/$k 2>/dev/null && FAIL "$k accepts 3"
	echo 0 > $D/$k
done
T=/sys/kernel/tracing
mountpoint -q $T || mount -t tracefs none $T
echo 1 > $T/events/nfsd/nfsd_read_direct/enable
echo 1 > $T/events/nfsd/nfsd_write_direct/enable
echo 1 > $T/events/nfsd/nfsd_file_get_dio_attrs/enable

B=/var/tmp/nd
mkdir -p $B/img /srv/md /srv/zfs
for i in 0 1 2 3; do truncate -s 2G $B/img/md$i $B/img/z$i; done
md=""
for i in 0 1 2 3; do md="$md $(losetup --direct-io=on -f --show $B/img/md$i)"; done
mdadm --create /dev/md0 --run -l0 -n4 $md
mkfs.xfs -q /dev/md0 && mount /dev/md0 /srv/md
FS="md"
if modprobe zfs 2>/dev/null; then
	zpool create -o ashift=12 -O recordsize=1M -O atime=off -m /srv/zfs tank \
		$B/img/z0 $B/img/z1 $B/img/z2 $B/img/z3 && FS="md zfs"
	zfs version
fi
chmod 777 /srv/md /srv/zfs
cat > /etc/exports <<X
/srv/md  127.0.0.1(rw,no_root_squash,sync,fsid=1)
/srv/zfs 127.0.0.1(rw,no_root_squash,sync,fsid=2)
X
sed -i 's/^# *threads=.*/threads=16/' /etc/nfs.conf
systemctl start nfs-server
exportfs -v

SRC=$B/src
dd if=/dev/urandom of=$SRC bs=1M count=512 status=none
SUM=$(sha256sum < $SRC | cut -d' ' -f1)
USUM=$(head -c $((12345 * 2000)) $SRC | sha256sum | cut -d' ' -f1)
O=vers=3,rsize=1048576,wsize=1048576

arc() { awk '$1 == "data_size" { print int($3 / 1048576) }' /proc/spl/kstat/zfs/arcstats 2>/dev/null || echo 0; }
pc() { fincore -nb -o RES "$1" | awk '{ print int($1 / 1048576) }'; }
cache() { if [ $1 = zfs ]; then echo $(( $(arc) - a0 )); else pc /srv/$1/$2; fi; }
cold() {
	sync; echo 3 > /proc/sys/vm/drop_caches
	if [ "$FS" != md ]; then
		umount /mnt/zfs 2>/dev/null; exportfs -ua
		zpool export tank && zpool import -d $B/img tank
		exportfs -ra
		mount -t nfs -o $O 127.0.0.1:/srv/zfs /mnt/zfs
	fi
	a0=$(arc)
}
ntrace() { grep -c "$1" $T/trace; }

for vers in 3 4.2; do
	O=vers=$vers,rsize=1048576,wsize=1048576
	for fs in $FS; do mkdir -p /mnt/$fs; mount -t nfs -o $O 127.0.0.1:/srv/$fs /mnt/$fs; done
	for mode in 0 1 2; do
		echo $mode > $D/io_cache_read; echo $mode > $D/io_cache_write
		for fs in $FS; do
			f=f$mode-$vers; u=u$mode-$vers
			tag="v$vers mode=$mode fs=$fs"
			cold; echo > $T/trace
			dd if=$SRC of=/mnt/$fs/$f bs=1M oflag=direct status=none
			sync; wc=$(cache $fs $f); wd=$(ntrace nfsd_write_direct)
			cold; echo > $T/trace
			rs=$(dd if=/mnt/$fs/$f bs=1M iflag=direct status=none | sha256sum | cut -d' ' -f1)
			rc=$(cache $fs $f); rd=$(ntrace nfsd_read_direct)
			# Writes that do not start or end on a block boundary.
			dd if=$SRC of=/mnt/$fs/$u bs=12345 count=2000 oflag=direct status=none
			cold
			us=$(dd if=/mnt/$fs/$u bs=1M iflag=direct status=none | sha256sum | cut -d' ' -f1)
			echo "MEASURE $tag: write leaves ${wc}MiB cached, $wd direct WRITE events; read leaves ${rc}MiB cached, $rd direct READ events"
			[ "$rs" = "$SUM" ] && echo "PASS $tag: 512MiB read back intact" || FAIL "$tag: data read back differs"
			[ "$us" = "$USUM" ] && echo "PASS $tag: unaligned writes read back intact" || FAIL "$tag: unaligned writes read back differ"
			case $mode in
			2)
				[ $wc -lt 64 ] && echo "PASS $tag: direct write bypasses the cache" || FAIL "$tag: direct write left ${wc}MiB cached"
				[ $rc -lt 64 ] && echo "PASS $tag: direct read bypasses the cache" || FAIL "$tag: direct read left ${rc}MiB cached"
				;;
			*)
				[ $rc -ge 256 ] && echo "PASS $tag: buffered read fills the cache" || FAIL "$tag: buffered read left only ${rc}MiB cached"
				;;
			esac
		done
	done
	for fs in $FS; do umount /mnt/$fs; done
done
grep -m3 nfsd_file_get_dio_attrs $T/trace
dmesg | grep -iE 'nfsd|sunrpc|bio_vec|BUG|WARNING' | tail -20
exit $fail
