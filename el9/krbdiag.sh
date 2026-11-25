#!/bin/sh
# Stock-kernel reproduction of the krb5i client setup from unaligned.sh, with
# full diagnostics, to find out why rpc-gssd will not start.  No custom kernel.
set -ux
N=nd.test; R=TEST
W=/var/tmp/krb; mkdir -p $W
hostnamectl set-hostname $N
A=$(hostname -I | awk '{ print $1 }')
grep -q $N /etc/hosts || echo "$A $N" >> /etc/hosts

dnf -y -q install krb5-server krb5-workstation nfs-utils xfsprogs

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
echo "== kdb5_util create =="
kdb5_util create -s -r $R -P "$(cat $W/mk)"
echo "== addprinc nfs/$N =="
kadmin.local -q "addprinc -randkey nfs/$N"
rm -f /etc/krb5.keytab
echo "== ktadd nfs/$N =="
kadmin.local -q "ktadd nfs/$N"
echo "== keytab =="; klist -k /etc/krb5.keytab
echo "== start krb5kdc =="; systemctl start krb5kdc; systemctl --no-pager status krb5kdc | head -8

# Reproduce the custom-kernel state: GSS modules present but not loaded, so
# rpc_pipefs has no gssd/ dir and rpc.gssd exits "rpc_pipefs directory empty".
echo "== force the -nd state faithfully: unload gss AND remount pipefs empty =="
systemctl stop rpc-gssd 2>/dev/null
rmmod rpcsec_gss_krb5 2>/dev/null; rmmod auth_rpcgss 2>/dev/null
# The subdirs persist across rmmod, so remount rpc_pipefs with the module
# unloaded to reproduce the -nd kernel's never-populated gssd.
umount /var/lib/nfs/rpc_pipefs 2>&1 | head -2
mount -t rpc_pipefs sunrpc /var/lib/nfs/rpc_pipefs 2>&1 | head -2
echo "rpc_pipefs after fresh remount (gssd should be ABSENT):"; ls /var/lib/nfs/rpc_pipefs
echo "== restart rpc-gssd on faithfully-empty pipefs (expect FAIL) =="
systemctl restart rpc-gssd 2>&1; echo "rc=$?"; systemctl is-active rpc-gssd && echo UNEXPECTED_OK || echo "failed as expected"
echo "== FIX A: modprobe only (does the notifier replay?) =="
modprobe rpcsec_gss_krb5
echo "rpc_pipefs after modprobe only:"; ls /var/lib/nfs/rpc_pipefs
systemctl restart rpc-gssd 2>&1; systemctl is-active rpc-gssd && echo "FIXA(modprobe-only) WORKED" || echo "FIXA failed (notifier did not replay)"
echo "== FIX B: remount pipefs now that module is loaded =="
systemctl stop rpc-gssd 2>/dev/null
umount /var/lib/nfs/rpc_pipefs 2>&1 | head -1
mount -t rpc_pipefs sunrpc /var/lib/nfs/rpc_pipefs
echo "rpc_pipefs after modprobe+remount:"; ls /var/lib/nfs/rpc_pipefs
systemctl restart rpc-gssd 2>&1; systemctl is-active rpc-gssd && echo "FIXB(modprobe+remount) WORKED" || echo "FIXB failed"
echo "lsmod gss:"; lsmod | grep -E 'rpcgss|gss_krb5' || echo "  (none loaded)"

echo "== rpc_pipefs =="; mount | grep rpc_pipefs || echo "not mounted"
echo "== systemctl restart gssproxy =="
systemctl restart gssproxy; echo "gssproxy rc=$?"
systemctl --no-pager status gssproxy | head -12

echo "== systemctl restart rpc-gssd =="
systemctl restart rpc-gssd; echo "rpc-gssd rc=$?"
echo "---- systemctl status rpc-gssd ----"
systemctl --no-pager -l status rpc-gssd | head -30
echo "---- journalctl -xeu rpc-gssd ----"
journalctl --no-pager -xeu rpc-gssd | tail -40
echo "---- cat rpc-gssd.service ----"
systemctl cat rpc-gssd | sed -n '1,60p'

echo "== rpc.gssd foreground -vvv (5s) =="
timeout 5 /usr/sbin/rpc.gssd -f -vvv 2>&1 | head -40
echo "rpc.gssd foreground exit"

echo "== try a self krb5i mount =="
mkdir -p /srv/nv /mnt/ua
mountpoint -q /srv/nv || { truncate -s 2G $W/xfs.img; mkfs.xfs -q $W/xfs.img; mount -o loop $W/xfs.img /srv/nv; }
echo "/srv/nv *(rw,no_root_squash,sync,fsid=3,sec=sys:krb5i)" > /etc/exports
systemctl restart nfs-server; exportfs -ra; exportfs -v
echo b > /srv/nv/b
timeout 60 mount -t nfs -o vers=4.2,sec=krb5i,proto=tcp $N:/srv/nv /mnt/ua
echo "krb5i mount rc=$?"
mount | grep /mnt/ua || true
cat /mnt/ua/b 2>&1 || true
echo "---- dmesg gss ----"; dmesg | grep -iE 'gss|rpcsec|nfs4' | tail -20
exit 0
