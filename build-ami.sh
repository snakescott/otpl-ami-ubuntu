#!/bin/bash

set -o errexit -o nounset

if [ $# -eq 0 ]; then
  echo "Usage: $0 image-name"
  exit 1
fi

if [ $(id -u) -ne 0 ]; then
  echo "You must be root to run this script"
  exit 1
fi

SCRIPT_DIR=`pwd`/`dirname $0`
ROOT_DIR=$(mktemp -d)
IMAGE_NAME=$1
RELEASE=trusty
EC2_BIN=$EC2_HOME/bin/
CURL='curl -fsS'

echo "Building $RELEASE base image in $ROOT_DIR, named $IMAGE_NAME"

function wait_file() {
  x=0
  while [ "$x" -lt 100 -a ! -e $1 ]; do
          x=$((x+1))
          sleep .1
  done
}

function wait_snapshot() {
  echo "Waiting for snapshot $1 to complete..."
  while $EC2_BIN/ec2-describe-snapshots $1 | grep -v completed; do
    sleep 10
  done
}

if [ -e /dev/xvdz ]; then
  echo "/dev/xvdz is already assigned"
  exit 1
fi

INSTANCE_ID=$($CURL http://169.254.169.254/latest/meta-data/instance-id)
VOL_ID=$($EC2_BIN/ec2-create-volume -s 10 -z us-west-2c | cut -f 2)
$EC2_BIN/ec2-create-tags $VOL_ID --tag "Name=$IMAGE_NAME"
$EC2_BIN/ec2-attach-volume $VOL_ID -i $INSTANCE_ID -d /dev/xvdz
wait_file /dev/xvdz
mkfs.ext4 -q -L ec2root /dev/xvdz
mount /dev/xvdz $ROOT_DIR


cd $ROOT_DIR
debootstrap --include=cloud-init,man-db,manpages-dev,wget,git,git-man,curl,zsh,rsync,screen,lsof,mlocate,nano,ssh,pax,strace,linux-image-virtual,grub,postfix,bsd-mailx,apt-transport-https $RELEASE . http://us-west-2.ec2.archive.ubuntu.com/ubuntu/

mount -o bind /sys sys
mount -o bind /proc proc
mount -o bind /dev dev


# System and network config
cat $SCRIPT_DIR/config/eth*.cfg >> etc/network/interfaces
cp $SCRIPT_DIR/config/fstab etc/fstab

# Keep AWS vars when a user runs sudo
cp $SCRIPT_DIR/config/aws-sudo etc/sudoers.d/

# Useful utility for cron jobs
cp $SCRIPT_DIR/cronic usr/local/bin/cronic

# cloud-init
cp $SCRIPT_DIR/cloud-init.d/* etc/cloud/cloud.cfg.d/

# prevent daemons from starting in the chroot

cat > usr/sbin/policy-rc.d <<EOF
#!/bin/sh
exit 101
EOF

chmod +x usr/sbin/policy-rc.d

cat > tmp/init-setup.sh <<SETUP
set -o errexit -o nounset -o xtrace

locale-gen en_US en_US.UTF-8
dpkg-reconfigure locales

mkdir -p /boot/grub
update-grub
sed -i.bak 's/# defoptions=quiet splash/# defoptions=cgroup_enable=memory swapaccount=1/' /boot/grub/menu.lst
sed -i.bak 's/# groot=(hd0,0)/# groot=(hd0)/' /boot/grub/menu.lst
rm /boot/grub/menu.lst.bak
update-grub

update-rc.d -f hwclock.sh remove
update-rc.d -f hwclockfirst.sh remove
echo 'root: ec2-root@opentable.com' >> /etc/aliases
newaliases

# install docker

echo deb https://get.docker.io/ubuntu docker main > /etc/apt/sources.list.d/docker.list
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 36A1D7869245C8950F966E92D8576A8BA88D21E9
apt-get update

# install apparmor too to work around https://github.com/dotcloud/docker/issues/4734, this should eventually go away
apt-get install -y lxc lxc-docker apparmor apparmor-profiles

SETUP

chmod +x tmp/init-setup.sh
chroot $ROOT_DIR /tmp/init-setup.sh
rm tmp/init-setup.sh usr/sbin/policy-rc.d

cd

umount -l ${ROOT_DIR}{/sys,/proc,/dev,/}
sync
$EC2_BIN/ec2-detach-volume $VOL_ID
SNAP_ID=$($EC2_BIN/ec2-create-snapshot $VOL_ID | cut -f 2)

wait_snapshot $SNAP_ID

$EC2_BIN/ec2-create-tags $SNAP_ID --tag "Name=ami-$IMAGE_NAME"
IMAGE_ID=$($EC2_BIN/ec2-register -n $IMAGE_NAME -a x86_64 -s $SNAP_ID --root-device-name /dev/xvda -b '/dev/xvdb=ephemeral0' -b '/dev/xvdc=ephemeral1' -b '/dev/xvdd=ephemeral2' -b '/dev/xvde=ephemeral3' --kernel aki-fc8f11cc | cut -f 2)
$EC2_BIN/ec2-create-tags $IMAGE_ID --tag "Name=$IMAGE_NAME" --tag ot-base-image
$EC2_BIN/ec2-delete-volume $VOL_ID

rmdir $ROOT_DIR
