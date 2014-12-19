#!/bin/sh
set -o errexit -o xtrace -o nounset

# Check if we already did this bit
lsblk -f | grep btrfs && exit 0

seen_first=0
raid_args=""

disks=""
for mapping in $(curl -fLS http://169.254.169.254/latest/meta-data/block-device-mapping | grep ephemeral)
do
  newdisk="$(curl -fLS http://169.254.169.254/latest/meta-data/block-device-mapping/$mapping | sed -E 's#^sd#/dev/xvd#')"
  if [ -e $newdisk ]; then
    disks="$disks $newdisk"
    if [ $seen_first -eq 1 ]; then
      raid_args="-m raid0 -d raid0"
    fi
    seen_first=1
  fi
done
mkfs.btrfs -f $raid_args $disks
