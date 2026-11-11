#!/bin/sh
# Does nfsd on the AlmaLinux 10 kernel serve READ and WRITE without filling
# the server's cache, over md RAID0 + XFS and over ZFS?  Loop devices stand in
# for NVMe; the client is the same machine over TCP, reading and writing with
# O_DIRECT so that only the server's cache is measured.
set -u
uname -r
fail=0
D=/sys/kernel/debug/nfsd
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
ls $D
if [ -e $D/io_cache_read ] && [ -e $D/io_cache_write ]; then
	echo "PASS: io_cache_read and io_cache_write exist"
else
	echo "FAIL: this kernel has no nfsd io_cache knobs"; fail=1
fi
rpm -q --changelog kernel-core-$(uname -r) | grep -i -m5 "nfsd.*\(direct\|dontcache\|io_cache\)"

B=/var/tmp/nd
mkdir -p $B/img /srv/md /srv/zfs /mnt/md /mnt/zfs
SZ=2G
for i in 0 1 2 3; do
	truncate -s $SZ $B/img/md$i $B/img/z$i
done
md=""
for i in 0 1 2 3; do
	md="$md $(losetup --direct-io=on -f --show $B/img/md$i)"
done
mdadm --create /dev/md0 --run -l0 -n4 $md
mkfs.xfs -q /dev/md0
mount /dev/md0 /srv/md
zpool create -o ashift=12 -O recordsize=1M -O atime=off -m /srv/zfs tank \
	$B/img/z0 $B/img/z1 $B/img/z2 $B/img/z3
zfs version
chmod 777 /srv/md /srv/zfs

cat > /etc/exports <<X
/srv/md  127.0.0.1(rw,no_root_squash,sync,fsid=1)
/srv/zfs 127.0.0.1(rw,no_root_squash,sync,fsid=2)
X
sed -i 's/^# *threads=.*/threads=32/' /etc/nfs.conf
systemctl start nfs-server
exportfs -v
mount -t nfs -o vers=4.2,rsize=1048576,wsize=1048576 127.0.0.1:/srv/md /mnt/md
mount -t nfs -o vers=4.2,rsize=1048576,wsize=1048576 127.0.0.1:/srv/zfs /mnt/zfs

arc() { awk '$1 == "data_size" { print int($3 / 1048576) }' /proc/spl/kstat/zfs/arcstats; }
pc() { fincore -nb -o RES "$1" | awk '{ print int($1 / 1048576) }'; }
cold() {
	# Empty the server's caches so that a read has to go to the disks.
	sync; echo 3 > /proc/sys/vm/drop_caches
	exportfs -ua; umount /mnt/zfs
	zpool export tank && zpool import -d $B/img tank
	exportfs -ra
	mount -t nfs -o vers=4.2,rsize=1048576,wsize=1048576 127.0.0.1:/srv/zfs /mnt/zfs
}
setmode() {
	[ -e $D/io_cache_read ] || return 0
	echo $1 > $D/io_cache_read; echo $1 > $D/io_cache_write
}

# mode 0 = buffered, 2 = direct
for mode in 0 2; do
	[ $mode = 2 ] && [ ! -e $D/io_cache_read ] && break
	setmode $mode
	echo "=== mode $mode"
	for fs in md zfs; do
		f=f$mode
		cold
		a0=$(arc)
		r=$(dd if=/dev/zero of=/mnt/$fs/$f bs=1M count=1024 oflag=direct 2>&1 | tail -1)
		sync
		w_pc=$(pc /srv/$fs/$f); w_arc=$(( $(arc) - a0 ))
		cold
		a0=$(arc)
		s=$(dd if=/mnt/$fs/$f of=/dev/null bs=1M iflag=direct 2>&1 | tail -1)
		r_pc=$(pc /srv/$fs/$f); r_arc=$(( $(arc) - a0 ))
		echo "MEASURE mode=$mode fs=$fs write: page cache ${w_pc}MiB, ARC +${w_arc}MiB; $r"
		echo "MEASURE mode=$mode fs=$fs read:  page cache ${r_pc}MiB, ARC +${r_arc}MiB; $s"
		if [ $mode = 2 ]; then
			c=$r_pc; [ $fs = zfs ] && c=$r_arc
			[ "$c" -lt 64 ] && echo "PASS: $fs direct read left ${c}MiB cached" ||
				{ echo "FAIL: $fs direct read left ${c}MiB cached"; fail=1; }
			c=$w_pc; [ $fs = zfs ] && c=$w_arc
			[ "$c" -lt 64 ] && echo "PASS: $fs direct write left ${c}MiB cached" ||
				{ echo "FAIL: $fs direct write left ${c}MiB cached"; fail=1; }
		fi
	done
done
dmesg | grep -i -E "nfsd|zfs|xfs" | tail -20
exit $fail
