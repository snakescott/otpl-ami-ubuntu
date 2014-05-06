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
CURL='curl -fsS'

echo "Building $RELEASE base image in $ROOT_DIR, named $IMAGE_NAME, uploading to $S3_BUCKET"

function wait_file() {
  x=0
  while [ "$x" -lt 100 -a ! -e $1 ]; do
          x=$((x+1))
          sleep .1
  done
}

if [ -e /dev/xvdz ]; then
  echo "/dev/xvdz is already assigned"
  exit 1
fi

INSTANCE_ID=$($CURL http://169.254.169.254/latest/meta-data/instance-id)
VOL_ID=$(aws ec2 create-volume --size 10 --availability-zone us-west-2c | jq -r '.VolumeId')
aws ec2 create-tags --resources $VOL_ID --tags "Key=Name,Value=$IMAGE_NAME"
aws ec2 attach-volume --volume-id $VOL_ID --instance-id $INSTANCE_ID --device /dev/xvdz
wait_file /dev/xvdz
mkfs.ext4 -q -L ec2root /dev/xvdz
mount /dev/xvdz $ROOT_DIR


cd $ROOT_DIR
debootstrap --include=cloud-init,man-db,manpages-dev,wget,git,git-man,curl,zsh,rsync,screen,lsof,mlocate,nano,ssh,pax,strace,linux-image-virtual,grub,postfix,bsd-mailx,apt-transport-https,ntp,unzip,ruby,kpartx,gdisk $RELEASE . http://us-west-2.ec2.archive.ubuntu.com/ubuntu/

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

cat > tmp/ami-tools.patch <<PATCH
*** ec2-ami-tools-1.4.0.1/lib/ec2/platform/linux/image.rb.org   2011-10-19 17:45:16.000000000 +0900
--- ec2-ami-tools-1.4.0.1/lib/ec2/platform/linux/image.rb       2011-10-19 17:45:55.000000000 +0900
***************
*** 276,282 ****
              fstab_content = make_fstab
              File.open( fstab, 'w' ) { |f| f.write( fstab_content ) }
              puts "/etc/fstab:"
!             fstab_content.each do |s|
                puts "\t #{s}"
              end
            end
--- 276,282 ----
              fstab_content = make_fstab
              File.open( fstab, 'w' ) { |f| f.write( fstab_content ) }
              puts "/etc/fstab:"
!             fstab_content.each_line do |s|
                puts "\t #{s}"
              end
            end
PATCH

cat > tmp/init-setup.sh <<SETUP
set -o errexit -o nounset -o xtrace

locale-gen en_US en_US.UTF-8
dpkg-reconfigure locales

mkdir -p /boot/grub
update-grub -y
sed -i.bak 's%# kopt=.*%# kopt=root=/dev/xvda1 ro%' /boot/grub/menu.lst
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

# install ec2-ami-tools

cd /opt
curl -sSfO http://s3.amazonaws.com/ec2-downloads/ec2-ami-tools.zip
unzip ec2-ami-tools.zip
rm ec2-ami-tools.zip
mv ec2-ami-tools-* ec2-ami-tools

patch -p1 -d /opt/ec2-ami-tools -i /tmp/ami-tools.patch
rm /tmp/ami-tools.patch

echo 'export EC2_AMITOOL_HOME=/opt/ec2-ami-tools; export PATH=$PATH:$EC2_AMITOOL_HOME/bin' > /etc/profile.d/ami.sh
chmod +x /etc/profile.d/ami.sh

apt-get clean

SETUP

chmod +x tmp/init-setup.sh
chroot $ROOT_DIR /tmp/init-setup.sh
rm tmp/init-setup.sh usr/sbin/policy-rc.d

cd

umount -l ${ROOT_DIR}{/sys,/proc,/dev}
sync

ec2-bundle-vol -c $EC2_CERT -k $EC2_PRIVATE_KEY -u $AWS_ACCOUNT_ID -r x86_64 -p $IMAGE_NAME -s 512 -v $ROOT_DIR --fstab $SCRIPT_DIR/config/fstab --no-inherit -B ami=sda1,root=/dev/sda1,swap=/dev/sdb,ephemeral0=/dev/sdc,ephemeral1=/dev/sdd
ec2-upload-bundle -b $S3_BUCKET -a $AWS_ACCESS_KEY -s $AWS_SECRET_KEY --region $EC2_REGION -m /tmp/$IMAGE_NAME.manifest.xml --retry
AMI=$(aws ec2 register-image --image-location $S3_BUCKET/$IMAGE_NAME --name $IMAGE_NAME --architecture x86_64 --kernel-id aki-fc8f11cc | jq -r .ImageId)
aws ec2 create-tags --resources $AMI --tags "Key=Name,Value=$IMAGE_NAME" "Key=ot-base-image,Value=ubuntu"

umount $ROOT_DIR
rmdir $ROOT_DIR

aws ec2 detach-volume --volume-id $VOL_ID
aws ec2 delete-volume --volume-id $VOL_ID

rm /tmp/$IMAGE_NAME*
