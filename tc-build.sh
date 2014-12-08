#!/bin/sh

set -o errexit -o nounset -o xtrace

TAG=otpl-ami-ubuntu:$(date +"%Y%m%d%H%M%S")

docker build -t $TAG .

docker run --privileged -e EC2_REGION=us-west-2 -w /otpl-ami-ubuntu $TAG ./build-ami.sh "$@"
