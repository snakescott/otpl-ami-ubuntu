# Opentable AMI: CentOS

The CentOS base image is a minimal install of CentOS (currently 6.5)
CentOS is used to host the transitional Ness platform.  There is intention to build a
otpl-ami-debian component (which encompasses Ubuntu) in the near future since that seems
to be the platform of choice currently.

## Requirements

The CentOS builder requires `rpm` and the ec2 toolset.

## Produces

The `build-ami.sh` script outputs an Amazon AMI image to a configurable S3 bucket.
