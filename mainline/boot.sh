#!/bin/sh
# Boot an AlmaLinux cloud image under qemu+KVM on the runner and leave it
# reachable as "ssh -p 2222 root@127.0.0.1".  IMG is the image URL, UD the
# cloud-init user-data, READY a command that succeeds in the guest once
# cloud-init has done its part (and rebooted, if it reboots).
set -eux
W=$RUNNER_TEMP/vm
mkdir -p $W && cd $W
sudo apt-get -qq update
sudo apt-get -qq install -y qemu-system-x86 qemu-utils cloud-image-utils
sudo chmod 666 /dev/kvm
curl -fsSL -o base.qcow2 "$IMG"
qemu-img create -q -f qcow2 -b base.qcow2 -F qcow2 disk.qcow2 30G
ssh-keygen -q -t ed25519 -N '' -f key
sed "s|@KEY@|$(cat key.pub)|" $GITHUB_WORKSPACE/$UD > user-data
printf 'instance-id: nd\nlocal-hostname: nd\n' > meta-data
cloud-localds seed.iso user-data meta-data
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 8192 -daemonize \
	-display none -serial file:$W/serial.log \
	-drive file=disk.qcow2,if=virtio -drive file=seed.iso,if=virtio,format=raw \
	-nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22
S="ssh -q -i key -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o ServerAliveInterval=30 root@127.0.0.1"
ok=""
for i in $(seq 1 120); do
	if $S "$READY" 2>/dev/null; then ok=1; break; fi
	sleep 10
done
[ -n "$ok" ] || { tail -50 $W/serial.log; exit 1; }
echo "booted $($S uname -r)"
echo "S=$S" >> $GITHUB_ENV
echo "W=$W" >> $GITHUB_ENV
