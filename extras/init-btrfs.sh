#!/bin/sh
set -o errexit -o xtrace -o nounset

# Check if we already did this bit
lsblk -f | grep btrfs && exit 0

disks=""
for mapping in $(curl -fLS http://169.254.169.254/latest/meta-data/block-device-mapping | grep ephemeral)
do
  disks="$disks $(curl -fLS http://169.254.169.254/latest/meta-data/block-device-mapping/$mapping | sed -E 's#^sd#/dev/xvd#')"
done
mkfs.btrfs -f -m raid0 -d raid0 $disks
