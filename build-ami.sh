#!/bin/bash

set -o errexit -o nounset -o xtrace
export http_proxy='http://54.193.106.53:3128'

SCRIPT_DIR=`pwd`/`dirname $0`
ROOT_DIR=`mktemp -d`
IMAGE_NAME='testimage'
RELEASE_RPM='http://mirror.centos.org/centos/6.5/os/x86_64/Packages/centos-release-6-5.el6.centos.11.1.x86_64.rpm'

echo Building CentOS base image in $ROOT_DIR

cd $ROOT_DIR
mkdir -p var/lib/rpm
rpm --rebuilddb --root=$ROOT_DIR

rpm -i --root=$ROOT_DIR --nodeps $RELEASE_RPM

# System and network config
mkdir -p etc/sysconfig/{network-scripts,selinux}
cp $SCRIPT_DIR/sysconfig/ifcfg-eth* etc/sysconfig/network-scripts/
cp $SCRIPT_DIR/sysconfig/selinux etc/sysconfig/selinux
cp $SCRIPT_DIR/fstab etc/fstab
cp /var/lib/random-seed var/lib/random-seed

sed -i 's/mirrorlist=/#mirrorlist=/g' etc/yum.repos.d/CentOS-Base.repo
sed -i 's/#baseurl=/baseurl=/g' etc/yum.repos.d/CentOS-Base.repo

YUM="yum --disableplugin=fastestmirror --installroot=$ROOT_DIR -y"

$YUM install @core wget git curl man zsh rsync screen irqbalance glibc nss \
  openssl redhat-lsb-core at bind-utils file lsof man ethtool man-pages mlocate nano ntp ntpdate \
  openssh-clients strace pax tar yum-utils

# Useful utility for cron jobs
cp $SCRIPT_DIR/cronic usr/local/bin/cronic

# Grub config
cp $SCRIPT_DIR/grub.conf boot/grub/grub.conf
ln -s '../boot/grub/grub.conf' etc/grub.conf
ln -s 'grub.conf' boot/grub/menu.lst

cp $SCRIPT_DIR/init.d/* etc/init.d/

KERN_VERS=$(basename $ROOT_DIR/boot/vmlinuz-*)
RAMFS_VERS=$(basename $ROOT_DIR/boot/initramfs-*)

cat > tmp/init-setup.sh <<SETUP
set -o errexit -o nounset -o xtrace
chkconfig --add ec2-run-user-data
chkconfig --add get-ssh-key
chkconfig iptables off
chkconfig ip6tables off
echo 'root: sschlansker@opentable.com' >> /etc/aliases
echo 'export http_proxy=$http_proxy' > /etc/profile.d/http-proxy.sh
echo 'proxy=$http_proxy' >> /etc/yum.conf
sed -i 's/enabled=1/enabled=0/' /etc/yum/pluginconf.d/fastestmirror.conf
grubby --add-kernel=/boot/$KERN_VERS --initrd=/boot/$RAMFS_VERS --make-default --title=CentOS --args="root=/dev/xvde1 LANG=en_US.UTF-8 crashkernel=auto"
newaliases
SETUP
chmod +x tmp/init-setup.sh

chroot $ROOT_DIR /tmp/init-setup.sh

rm tmp/init-setup.sh

#ec2-bundle-vol -c /tmp/cert-2LZDZL2CXYF7OXFL24KRJJ5DTXXLBQVA.pem -k /tmp/pk-2LZDZL2CXYF7OXFL24KRJJ5DTXXLBQVA.pem \
#  -r x86_64 -u 6708-2490-4290 --no-inherit --kernel aki-880531cd --fstab root/etc/fstab \
#  -v /srv/packaging/root -p centos65-base -B "ami=sda1,root=/dev/sda1,ephemeral0=sda2,swap=sda3"

#ec2-upload-bundle -b sschlansker-ami -m /tmp/centos65-base.manifest.xml \
#  -a 'AKIAI7XWEKUIRBFOGLAQ' -s 'rCdxyC6vikhSPGj84/3BqkP4EXeQG7nT0Sd5myfI'

