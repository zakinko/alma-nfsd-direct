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
