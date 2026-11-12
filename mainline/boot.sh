#!/bin/sh
# Boot AlmaLinux 10 with ELRepo's kernel-ml under qemu+KVM on the runner, and
# leave it reachable as "ssh -p 2222 root@127.0.0.1".
set -eux
W=$RUNNER_TEMP/vm
mkdir -p $W && cd $W
sudo apt-get -qq update
sudo apt-get -qq install -y qemu-system-x86 qemu-utils cloud-image-utils
sudo chmod 666 /dev/kvm
curl -fsSL -o base.qcow2 https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2
qemu-img create -q -f qcow2 -b base.qcow2 -F qcow2 disk.qcow2 30G
ssh-keygen -q -t ed25519 -N '' -f key
sed "s|@KEY@|$(cat key.pub)|" $GITHUB_WORKSPACE/mainline/user-data > user-data
printf 'instance-id: nd\nlocal-hostname: nd\n' > meta-data
cloud-localds seed.iso user-data meta-data
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 8192 -daemonize \
	-display none -serial file:$W/serial.log \
	-drive file=disk.qcow2,if=virtio -drive file=seed.iso,if=virtio,format=raw \
	-nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22
S="ssh -q -i key -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"
# First boot installs kernel-ml and reboots into it.
for i in $(seq 1 120); do
	k=$($S uname -r 2>/dev/null || true)
	case "$k" in *elrepo*) break ;; esac
	sleep 10
done
case "$k" in *elrepo*) ;; *) tail -50 $W/serial.log; exit 1 ;; esac
echo "booted $k"
echo "S=$S" >> $GITHUB_ENV
echo "W=$W" >> $GITHUB_ENV
