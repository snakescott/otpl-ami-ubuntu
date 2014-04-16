# Opentable AMI: Debian

This base image is a minimal install of Debian or Ubuntu.

## Requirements

The Debian builder requires `debootstrap` and the ec2 toolset.  Most testing is done from within ec2 itself, so that is the supported environment to run this script in.

## Produces

The `build-ami.sh` script outputs an Amazon AMI image to a configurable S3 bucket.
