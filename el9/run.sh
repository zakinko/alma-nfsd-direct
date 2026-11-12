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
for m in sunrpc nfsd rpcrdma; do echo "$m: $(modinfo -n $m)"; done
# MAINLINE=1: an upstream kernel, nothing rebuilt.  Otherwise the RHEL 9
# kernel with the series built into sunrpc, rpcrdma and nfsd.
if [ -z "${MAINLINE:-}" ]; then
	case "$(modinfo -n nfsd) $(modinfo -n sunrpc) $(modinfo -n rpcrdma)" in
	*updates/el9/nfsd.ko*updates/el9/sunrpc.ko*updates/el9/rpcrdma.ko*) echo "PASS: rebuilt modules are the ones modprobe uses" ;;
	*) FAIL "modprobe does not use the rebuilt modules" ;;
	esac
	grep -qE ' xdr_buf_to_bvec(\s|$)' /proc/kallsyms && echo "PASS: rebuilt sunrpc is loaded" || FAIL "loaded sunrpc lacks xdr_buf_to_bvec"
fi
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
echo 1 > $T/events/nfsd/nfsd_write_vector/enable
echo 1 > $T/events/nfsd/nfsd_file_get_dio_attrs/enable

B=/var/tmp/nd
mkdir -p $B/img /srv/md /srv/zfs
for i in 0 1 2 3; do truncate -s 2G $B/img/md$i $B/img/z$i; done
# The md members.  Loop and scsi_debug disks keep the block layer's default DMA
# alignment of 512 bytes, which an NFS WRITE payload does not meet (it follows
# the RPC header in the receive buffer), so nfsd writes them buffered.  The
# NVMe host driver asks for less, so the members are NVMe namespaces exported
# over nvme-loop from files, when the modules are there.
md=""
C=/sys/kernel/config/nvmet
if modprobe nvmet && modprobe nvme-loop && modprobe nvme-fabrics; then
	mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
	mkdir -p $C/ports/1 && echo loop > $C/ports/1/addr_trtype
	for i in 0 1 2 3; do
		s=$C/subsystems/nd$i
		mkdir -p $s/namespaces/1
		echo 1 > $s/attr_allow_any_host
		echo $B/img/md$i > $s/namespaces/1/device_path
		# The file backend otherwise writes the image with O_DIRECT, which
		# imposes the VM disk's 512-byte DMA alignment on a namespace that
		# advertises 4 bytes: buffers that a real NVMe drive takes then
		# fail with EIO underneath XFS.
		echo 1 > $s/namespaces/1/buffered_io
		echo 1 > $s/namespaces/1/enable
		ln -s $s $C/ports/1/subsystems/nd$i
		nvme connect -t loop -n nd$i
	done
	udevadm settle
	md=$(nvme list -o json | sed -n 's/.*"DevicePath" *: *"\([^"]*\)".*/\1/p' | sort)
	echo "md members (nvme-loop): $md"
	for d in $md; do echo "$d dma_alignment: $(cat /sys/block/${d#/dev/}/queue/dma_alignment) lbs: $(cat /sys/block/${d#/dev/}/queue/logical_block_size)"; done
	# md0 does not inherit the members' DMA alignment on this kernel, so one
	# namespace carries an XFS of its own to show the direct WRITE path.
	nv=$(echo $md | awk '{ print $NF }')
	md=$(echo $md | awk '{ $NF = ""; print }')
	mkdir -p /srv/nv && mkfs.xfs -q $nv && mount $nv /srv/nv && chmod 777 /srv/nv
	: > /srv/nv/probe; xfs_io -c "statx -r -m 0x2000" /srv/nv/probe | grep -i dio
fi
if [ -z "$md" ]; then
	for i in 0 1 2 3; do md="$md $(losetup --direct-io=on -f --show $B/img/md$i)"; done
	echo "md members (loop): $md"
fi
mdadm --create /dev/md0 --run -l0 -n$(echo $md | wc -w) $md
mkfs.xfs -q /dev/md0 && mount /dev/md0 /srv/md
echo "md0 dma_alignment: $(cat /sys/block/md0/queue/dma_alignment)"
: > /srv/md/probe
xfs_io -c "statx -r -m 0x2000" /srv/md/probe | grep -i dio
FS="md"
mountpoint -q /srv/nv && FS="md nv"
if modprobe zfs 2>/dev/null; then
	zpool create -o ashift=12 -O recordsize=1M -O atime=off -m /srv/zfs tank \
		$B/img/z0 $B/img/z1 $B/img/z2 $B/img/z3 && FS="$FS zfs"
	zfs version
fi
chmod 777 /srv/md /srv/zfs
cat > /etc/exports <<X
/srv/md  *(rw,no_root_squash,sync,fsid=1)
/srv/zfs *(rw,no_root_squash,sync,fsid=2)
/srv/nv  *(rw,no_root_squash,sync,fsid=3)
X
sed -i 's/^# *threads=.*/threads=16/' /etc/nfs.conf

# Soft-RoCE on the VM's own interface, for NFS over RDMA.  Over RDMA a large
# WRITE payload arrives by RDMA Read into whole pages; over TCP it follows the
# RPC header in the receive buffer, so its first bvec starts mid-page.
H=127.0.0.1
IF=$(ip -o -4 route show default | awk '{ print $5; exit }')
if modprobe rdma_rxe 2>/dev/null && rdma link add rxe0 type rxe netdev "$IF"; then
	H=$(ip -o -4 addr show dev "$IF" | awk '{ split($4, a, "/"); print a[1]; exit }')
	modprobe rpcrdma
	rdma link show
	TRANSPORTS="tcp rdma"
else
	echo "no soft-RoCE: RDMA rounds skipped"
	TRANSPORTS="tcp"
fi
srv_start() {
	systemctl start nfs-server
	case "$TRANSPORTS" in *rdma*)
		grep -q rdma /proc/fs/nfsd/portlist || echo "rdma 20049" > /proc/fs/nfsd/portlist ;;
	esac
}
srv_start
cat /proc/fs/nfsd/portlist
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
	# NFSv4 state keeps files open in nfsd, so the server is stopped before
	# the pool is exported, and every client mount goes with it.
	for x in $FS; do umount /mnt/$x; done
	systemctl stop nfs-server
	sync; echo 3 > /proc/sys/vm/drop_caches
	if [ "$FS" = zfs ]; then
		zpool export tank && zpool import -d $B/img tank || FAIL "pool export/import"
		exportfs -f
	fi
	srv_start
	for x in $FS; do mount -t nfs -o $O $H:/srv/$x /mnt/$x || FAIL "mount $x"; done
	a0=$(arc)
}
ntrace() { grep -c "$1" $T/trace; }

# Re-importing the pool leaves NFSv4 file handles stale, on the other
# exports too, so ZFS (which never goes direct in 2.2) runs last, alone,
# over NFSv3.
ZFS=""
case "$FS" in *zfs*) ZFS=1; FS=$(echo $FS | sed 's/zfs//'); TRANSPORTS="$TRANSPORTS zfs" ;; esac
for tr in $TRANSPORTS; do
ALLFS=$FS
modes="0 1 2"; H=127.0.0.1; X=""; VERS="3 4.2"
if [ $tr = zfs ]; then
	FS=zfs; VERS=3; tr=tcp
elif [ $tr = rdma ]; then
	modes=2; H=$(ip -o -4 addr show dev "$IF" | awk '{ split($4, a, "/"); print a[1]; exit }')
	X=,proto=rdma,port=20049
fi
for vers in $VERS; do
	O=vers=$vers,rsize=1048576,wsize=1048576$X
	for fs in $FS; do mkdir -p /mnt/$fs; mount -t nfs -o $O $H:/srv/$fs /mnt/$fs || FAIL "mount $fs over $tr"; done
	for mode in $modes; do
		echo $mode > $D/io_cache_read; echo $mode > $D/io_cache_write
		for fs in $FS; do
			f=f$mode-$vers; u=u$mode-$vers
			tag="$tr v$vers mode=$mode fs=$fs"
			cold; echo > $T/trace
			dd if=$SRC of=/mnt/$fs/$f bs=1M oflag=direct status=none
			sync; wc=$(cache $fs $f); wd=$(ntrace nfsd_write_direct)
			wv=$(ntrace nfsd_write_vector)
			cold; echo > $T/trace
			rs=$(dd if=/mnt/$fs/$f bs=1M iflag=direct status=none | sha256sum | cut -d' ' -f1)
			rc=$(cache $fs $f); rd=$(ntrace nfsd_read_direct)
			# Writes that do not start or end on a block boundary.
			dd if=$SRC of=/mnt/$fs/$u bs=12345 count=2000 oflag=direct status=none
			cold
			us=$(dd if=/mnt/$fs/$u bs=1M iflag=direct status=none | sha256sum | cut -d' ' -f1)
			ss=$(sha256sum < /srv/$fs/$u | cut -d" " -f1)
			[ "$ss" = "$USUM" ] && echo "PASS $tag: unaligned writes stored intact on the server" || FAIL "$tag: unaligned writes stored wrong on the server"
			echo "MEASURE $tag: write leaves ${wc}MiB cached, $wd direct and $wv buffered WRITE segments; read leaves ${rc}MiB cached, $rd direct READ events"
			[ "$rs" = "$SUM" ] && echo "PASS $tag: 512MiB read back intact" || FAIL "$tag: data read back differs"
			[ "$us" = "$USUM" ] && echo "PASS $tag: unaligned writes read back intact" || FAIL "$tag: unaligned writes read back differ"
			rm -f /mnt/$fs/$f /mnt/$fs/$u
			# ZFS 2.2 reports no STATX_DIOALIGN, so nfsd never goes direct on
			# it, and the ARC delta after export/import is noisy: report only.
			[ $fs = zfs ] && continue
			case $mode in
			2)
				[ $rc -lt 64 ] && echo "PASS $tag: direct read bypasses the cache" || FAIL "$tag: direct read left ${rc}MiB cached"
				# md0 asks for 512-byte DMA alignment, which no WRITE
				# payload here meets: buffered, on every kernel.
				[ $fs = md ] && continue
				# The RHEL 9 block layer wants every segment of a direct
				# write to be a whole number of logical blocks; a TCP
				# payload's first bvec is not, so nfsd writes it buffered.
				# Upstream since 6.18 checks only the total length.
				if [ $tr = tcp ] && [ -z "${MAINLINE:-}" ]; then
					echo "INFO $tag: direct write on RHEL 9 over TCP falls back to buffered (${wd} direct segments, ${wc}MiB cached)"
				else
					[ $wc -lt 64 ] && [ $wd -gt 0 ] && echo "PASS $tag: direct write bypasses the cache" || FAIL "$tag: direct write left ${wc}MiB cached, $wd direct segments"
				fi
				;;
			1)
				# Upstream drops the pages behind a dontcache read; RHEL 9
				# has no dontcache, so value 1 is buffered there.
				if [ -n "${MAINLINE:-}" ]; then
					[ $rc -lt 64 ] && echo "PASS $tag: dontcache read leaves the cache empty" || FAIL "$tag: dontcache read left ${rc}MiB cached"
				else
					[ $rc -ge 256 ] && echo "PASS $tag: buffered read fills the cache" || FAIL "$tag: buffered read left only ${rc}MiB cached"
				fi
				;;
			*)
				[ $rc -ge 256 ] && echo "PASS $tag: buffered read fills the cache" || FAIL "$tag: buffered read left only ${rc}MiB cached"
				;;
			esac
		done
	done
	for fs in $FS; do umount /mnt/$fs; done
done
FS=$ALLFS
done
grep -m3 nfsd_file_get_dio_attrs $T/trace
dmesg | grep -iE 'nfsd|sunrpc|bio_vec|BUG|WARNING' | tail -20
exit $fail
