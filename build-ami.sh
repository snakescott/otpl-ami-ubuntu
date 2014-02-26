#!/bin/bash

set -o errexit -o nounset
export http_proxy='http://ec2-54-193-23-200.us-west-1.compute.amazonaws.com:3128'

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 image-name"
  exit 1
fi

SCRIPT_DIR=`pwd`/`dirname $0`
ROOT_DIR=$(mktemp -d)
IMAGE_NAME=$1
EC2_BIN=$EC2_HOME/bin/
RELEASE_RPM='http://mirror.centos.org/centos/6.5/os/x86_64/Packages/centos-release-6-5.el6.centos.11.1.x86_64.rpm'
CURL='curl -fsS'


function wait_file() {
  x=0
  while [ "$x" -lt 100 -a ! -e $1 ]; do
          x=$((x+1))
          sleep .1
  done
}

function wait_snapshot() {
  x=0
  echo "Waiting for snapshot $1 to complete..."
  while [ "$x" -lt 20 -a ! $(ec2-describe-snapshot $1 | grep completed) ]; do
    x=$((x+1))
    sleep 10
  done
}

if [[ -e /dev/xvdz ]]; then
  echo "/dev/xvdz is already assigned"
  exit 1
fi

INSTANCE_ID=$($CURL http://169.254.169.254/latest/meta-data/instance-id)
VOL_ID=$($EC2_BIN/ec2-create-volume -s 10 -z us-west-1b | cut -f 2)
$EC2_BIN/ec2-create-tags $VOL_ID --tag "Name=$IMAGE_NAME"
$EC2_BIN/ec2-attach-volume $VOL_ID -i $INSTANCE_ID -d /dev/xvdz
wait_file /dev/xvdz
mkfs.ext4 -L ec2root /dev/xvdz
mount /dev/xvdz $ROOT_DIR

echo Building CentOS base image in $ROOT_DIR

pushd $ROOT_DIR
mkdir -p var/lib/rpm
rpm --rebuilddb --root=$ROOT_DIR

rpm -i --root=$ROOT_DIR --nodeps $RELEASE_RPM

# System and network config
mkdir -p etc/sysconfig/{network-scripts,selinux}
cp $SCRIPT_DIR/sysconfig/ifcfg-eth* etc/sysconfig/network-scripts/
cp $SCRIPT_DIR/fstab etc/fstab
cp /var/lib/random-seed var/lib/random-seed

# Keep AWS vars when a user runs sudo
mkdir etc/sudoers.d/
cp $SCRIPT_DIR/aws-sudo etc/sudoers.d/

sed -i -e 's/mirrorlist=/#mirrorlist=/g' -e 's/#baseurl=/baseurl=/g' etc/yum.repos.d/CentOS-Base.repo

YUM="yum --disableplugin=fastestmirror --installroot=$ROOT_DIR -q -y"

$YUM install @core wget git curl man zsh rsync screen irqbalance glibc nss \
  openssl redhat-lsb-core at bind-utils file lsof man ethtool man-pages mlocate nano ntp ntpdate \
  openssh-clients strace pax tar yum-utils nc

# Disable SELinux
cp $SCRIPT_DIR/sysconfig/selinux etc/selinux/config

# Useful utility for cron jobs
cp $SCRIPT_DIR/cronic usr/local/bin/cronic

# Grub config
KERN_VERS=$(basename $ROOT_DIR/boot/vmlinuz-*)
RAMFS_VERS=$(basename $ROOT_DIR/boot/initramfs-*)
sed -e "s/KERN/$KERN_VERS/" -e "s/RAMFS/$RAMFS_VERS/" < $SCRIPT_DIR/grub.conf > boot/grub/grub.conf
ln -s '../boot/grub/grub.conf' etc/grub.conf
ln -s 'grub.conf' boot/grub/menu.lst

cp $SCRIPT_DIR/init.d/* etc/init.d/


cat > tmp/init-setup.sh <<SETUP
set -o errexit -o nounset -o xtrace
chkconfig --add ec2-run-user-data
chkconfig --add get-ssh-key
chkconfig iptables off
chkconfig ip6tables off
chkconfig resize-filesystems on
echo 'root: ec2-root@opentable.com' >> /etc/aliases
echo 'proxy=$http_proxy' >> /etc/yum.conf
echo 'NETWORKING=yes' > /etc/sysconfig/network
sed -i 's/enabled=1/enabled=0/' /etc/yum/pluginconf.d/fastestmirror.conf
newaliases
SETUP
chmod +x tmp/init-setup.sh

chroot $ROOT_DIR /tmp/init-setup.sh

rm tmp/init-setup.sh

popd

umount $ROOT_DIR
sync
$EC2_BIN/ec2-detach-volume $VOL_ID
SNAP_ID=$($EC2_BIN/ec2-create-snapshot $VOL_ID | cut -f 2)

wait_snapshot $SNAP_ID

IMAGE_ID=$($EC2_BIN/ec2-register -n $IMAGE_NAME -a x86_64 -s $SNAP_ID --root-device-name /dev/xvda -b '/dev/xvdb=ephemeral0' --kernel aki-880531cd | cut -f 2)
$EC2_BIN/ec2-create-tags $IMAGE_ID --tag "Name=$IMAGE_NAME" --tag ot-base-image
$EC2_BIN/ec2-delete-volume $VOL_ID

rmdir $ROOT_DIR
