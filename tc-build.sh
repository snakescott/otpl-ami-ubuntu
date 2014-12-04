#!/bin/sh

set -o errexit -o nounset -o xtrace

docker run --privileged -v $PWD:/otpl-ami-ubuntu -e EC2_REGION=us-west-2 -w /otpl-ami-ubuntu registry.mesos-vpcqa.otenv.com/ot-awsbuild:latest ./build-ami "$@"
