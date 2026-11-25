#!/bin/sh
# READs that do not start on a block boundary, with io_cache_read=2: is the
# data the client gets what is in the file?  sec=sys and krb5i, NFSv3 and
# NFSv4.2.  Runs after run.sh, on the XFS it left mounted on /srv/nv.
set -u
fail=0
FAIL() { echo "FAIL: $*"; fail=1; }
N=nd.test; R=TEST
W=/var/tmp/ua; mkdir -p $W
hostnamectl set-hostname $N
A=$(hostname -I | awk '{ print $1 }')
grep -q $N /etc/hosts || echo "$A $N" >> /etc/hosts
dnf -y -q install krb5-server krb5-workstation >/dev/null || FAIL "krb5 packages"
cat > /etc/krb5.conf <<X
[libdefaults]
 default_realm = $R
 dns_lookup_kdc = false
 rdns = false
[realms]
 $R = {
  kdc = $N
  admin_server = $N
 }
[domain_realm]
 .test = $R
X
rm -f /etc/krb5.conf.d/* /var/kerberos/krb5kdc/principal*
head -c 16 /dev/urandom | base64 > $W/mk
kdb5_util create -s -r $R -P "$(cat $W/mk)" >/dev/null 2>&1 || FAIL "kdb5_util"
kadmin.local -q "addprinc -randkey nfs/$N" >/dev/null 2>&1
rm -f /etc/krb5.keytab; kadmin.local -q "ktadd nfs/$N" >/dev/null 2>&1
systemctl start krb5kdc || FAIL "krb5kdc"
echo "/srv/nv *(rw,no_root_squash,sync,fsid=3,sec=sys:krb5i)" > /etc/exports
mountpoint -q /srv/nv || FAIL "/srv/nv is not mounted"
systemctl restart gssproxy rpc-gssd; systemctl restart nfs-server; exportfs -ra
# Diagnose the client GSS daemon: on the custom kernel it has failed to start
# while the stock kernel's starts fine, and the journal is not otherwise kept.
if ! systemctl is-active --quiet rpc-gssd; then
	echo "---- rpc-gssd failed to start; diagnostics ----"
	systemctl --no-pager -l status rpc-gssd 2>&1 | head -25
	journalctl --no-pager -xeu rpc-gssd 2>&1 | tail -25
	echo "---- modinfo / modprobe gss ----"
	for m in auth_rpcgss rpcsec_gss_krb5; do
		ls -l /lib/modules/$(uname -r)/kernel/net/sunrpc/${m%%_*}*/* 2>/dev/null
		modprobe -v $m 2>&1 | head -5 || echo "modprobe $m failed"
	done
	echo "---- rpc.gssd -f -vvv (5s) ----"
	timeout 5 /usr/sbin/rpc.gssd -f -vvv 2>&1 | head -30
	echo "---- end diagnostics ----"
fi
D=/sys/kernel/debug/nfsd
F=/srv/nv/ua; rm -f $F
dd if=/dev/urandom of=$F bs=1M count=64 conv=fsync status=none; chmod 644 $F
T=/sys/kernel/tracing; echo 1 > $T/events/nfsd/nfsd_read_direct/enable
want() { tail -c +$(($1 + 1)) $F | head -c $2 | sha256sum | cut -d' ' -f1; }
get() { timeout 120 dd if=/mnt/ua/ua bs=$3 skip=$1 count=$2 iflag=direct,skip_bytes,count_bytes,fullblock status=none 2>>$W/dd.err | sha256sum | cut -d' ' -f1; }
mkdir -p /mnt/ua
for mode in 0 2; do
echo $mode > $D/io_cache_read
for sec in sys krb5i; do for v in 3 4.2; do
	tag="read=$mode sec=$sec v$v"
	timeout 60 mount -t nfs -o vers=$v,sec=$sec,rsize=1048576,proto=tcp $N:/srv/nv /mnt/ua || { FAIL "$tag: mount"; continue; }
	echo > $T/trace; : > $W/dd.err; ok=0; bad=""
	for off in 0 1 2 3 4 8 12 511 512 1000 1024 2048 4092 4095 4096 4097 8190 1048575; do
		for bs in 1000 12345 65536 1048576; do
			n=$((4 * 1048576)); [ $bs = 1000 ] && n=200000
			if [ "$(get $off $n $bs)" = "$(want $off $n)" ]; then ok=$((ok + 1)); else bad="$bad $off/$bs"; fi
		done
	done
	w=$(want 12 33554432)
	: > $W/par
	for i in 1 2 3 4 5 6 7 8; do ( [ "$(get 12 33554432 1048576)" = "$w" ] || echo $i >> $W/par ) & done; wait
	p=$(wc -l < $W/par)
	echo "MEASURE $tag: $ok good, bad:${bad:- none}; parallel bad $p of 8; $(grep -c nfsd_read_direct $T/trace) direct READ events; dd errors $(wc -l < $W/dd.err)"
	[ -z "$bad" ] && [ $p = 0 ] && echo "PASS $tag" || FAIL "$tag: data differs"
	umount -f /mnt/ua
done; done; done
echo 0 > $D/io_cache_read
dmesg | grep -iE 'BUG|WARNING: CPU|Oops|general protection|Bad page|alignment failure|gss' | tail -20
exit $fail
