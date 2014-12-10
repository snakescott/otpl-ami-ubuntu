#!/bin/bash

set -o errexit -o nounset

if [ $# -ne 2 ]; then
  echo "Usage: $0 s3-bucket image-name"
  exit 1
fi

if [ $(id -u) -ne 0 ]; then
  echo "You must be root to run this script"
  exit 1
fi

set -o xtrace

SCRIPT_DIR=$PWD
ROOT_DIR=$(mktemp -d)
S3_BUCKET=$1
IMAGE_NAME=$2
RELEASE=trusty
CURL='curl -fsS'

if [ $EC2_REGION = us-west-1 ]; then
  AKI="aki-880531cd"
elif [ $EC2_REGION = us-west-2 ]; then
  AKI="aki-fc8f11cc"
else
  echo "Unknown region $EC2_REGION"
  exit 1
fi

echo "AMI tools at $EC2_AMITOOL_HOME"
echo "Building $RELEASE base image in $ROOT_DIR, kernel $AKI, named $IMAGE_NAME, uploading to $S3_BUCKET"

cd $ROOT_DIR

# https://gist.github.com/jpetazzo/6127116 Debian pro tips!
mkdir -p etc/dpkg/dpkg.cfg.d etc/apt/apt.conf.d
# this forces dpkg not to call sync() after package extraction and speeds up install
echo "force-unsafe-io" > etc/dpkg/dpkg.cfg.d/02apt-speedup
# we don't need an apt cache
echo "Acquire::http {No-Cache=True;};" > etc/apt/apt.conf.d/no-cache

debootstrap --include=cloud-init,man-db,manpages-dev,wget,git,git-man,curl,ca-certificates,zsh,rsync,screen,lsof,mlocate,nano,ssh,pax,strace,linux-image-virtual,grub,postfix,bsd-mailx,apt-transport-https,ntp,unzip,ruby,kpartx,gdisk,patch,psmisc,btrfs-tools $RELEASE . http://us-west-2.ec2.archive.ubuntu.com/ubuntu/

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

# nsenter because ubuntu is dumb.
# https://bugs.launchpad.net/ubuntu/+source/util-linux/+bug/1012081
cp $SCRIPT_DIR/extras/nsenter usr/bin/nsenter

# btrfs configuration
mkdir -p opt/bin/
cp $SCRIPT_DIR/extras/init-btrfs.sh opt/bin/

mkdir -p etc/ot
echo $IMAGE_NAME > etc/ot/base-image

# prevent daemons from starting in the chroot

cat > usr/sbin/policy-rc.d <<EOF
#!/bin/sh
exit 101
EOF

chmod +x usr/sbin/policy-rc.d

cat > tmp/init-setup.sh <<SETUP
set -o errexit -o nounset -o xtrace

export DEBIAN_FRONTEND=noninteractive

locale-gen en_US en_US.UTF-8
dpkg-reconfigure locales

mkdir -p /boot/grub
update-grub -y
sed -i.bak 's%# kopt=.*%# kopt=root=/dev/xvda1 ro cgroup_enable=memory swapaccount=1%' /boot/grub/menu.lst
rm /boot/grub/menu.lst.bak
update-grub

update-rc.d -f hwclock.sh remove
update-rc.d -f hwclockfirst.sh remove
echo 'root: ec2-root@opentable.com' >> /etc/aliases
newaliases

# ensure we have access to our apt repos
cloud-init single -n cc_apt_configure

# install docker

echo deb https://get.docker.com/ubuntu docker main > /etc/apt/sources.list.d/docker.list
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 36A1D7869245C8950F966E92D8576A8BA88D21E9
apt-get update

# ensure we get updates
apt-get dist-upgrade -y

# install universe package which can't be debootstrapped
apt-get install -y jq mosh python-pip

# install apparmor too to work around https://github.com/dotcloud/docker/issues/4734, this should eventually go away
apt-get install -y lxc lxc-docker apparmor apparmor-profiles

# install ec2-ami-tools

cd /opt
curl -sSfO http://s3.amazonaws.com/ec2-downloads/ec2-ami-tools.zip
unzip ec2-ami-tools.zip
rm ec2-ami-tools.zip
mv ec2-ami-tools-* ec2-ami-tools

echo 'export EC2_AMITOOL_HOME=/opt/ec2-ami-tools; export PATH=$PATH:$EC2_AMITOOL_HOME/bin' > /etc/profile.d/ami.sh
chmod +x /etc/profile.d/ami.sh

pip install awscli

apt-get purge -y linux-image-3.13.0-24-generic
apt-get autoremove
apt-get clean

SETUP

chmod +x tmp/init-setup.sh
chroot $ROOT_DIR /tmp/init-setup.sh
rm tmp/init-setup.sh usr/sbin/policy-rc.d

# Configure Docker daemon
cat > etc/default/docker <<DOCKERCONF
mkdir -p /mnt/docker /mnt/docker-tmp
DOCKER_OPTS="-g /mnt/docker"
export TMPDIR="/mnt/docker-tmp"
DOCKERCONF

cd

umount -l ${ROOT_DIR}{/sys,/proc,/dev}

[ -e $IMAGE_NAME ] && rm -f $IMAGE_NAME

tar -cz -C $ROOT_DIR -f $IMAGE_NAME.tgz .
aws s3 cp $IMAGE_NAME.tgz s3://$S3_BUCKET/

ec2-bundle-vol -c $EC2_CERT -k $EC2_PRIVATE_KEY -u $AWS_ACCOUNT_ID -r x86_64 -p $IMAGE_NAME -s 10240 -v $ROOT_DIR --fstab $SCRIPT_DIR/config/fstab --no-inherit -B ami=sda,root=/dev/sda1,swap=/dev/sdb,ephemeral0=/dev/sdc,ephemeral1=/dev/sdd --no-filter
ec2-upload-bundle -b $S3_BUCKET -a $AWS_ACCESS_KEY -s $AWS_SECRET_KEY -m /tmp/$IMAGE_NAME.manifest.xml --retry
AMI=$(aws ec2 register-image --image-location $S3_BUCKET/$IMAGE_NAME.manifest.xml --name $IMAGE_NAME --architecture x86_64 --kernel-id $AKI | jq -r .ImageId)
aws ec2 create-tags --resources $AMI --tags "Key=Name,Value=$IMAGE_NAME" "Key=ot-base-image,Value=ubuntu"

rm -rf $ROOT_DIR /tmp/$IMAGE_NAME*

echo "Completed: $AMI"
