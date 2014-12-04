#!/bin/sh

set -o errexit -o nounset -o xtrace

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ec2-ami-tools debootstrap python-pip
pip install awscli

export EC2_AMITOOL_HOME=/usr/lib/ec2-ami-tools
./build-ami.sh "$@"
