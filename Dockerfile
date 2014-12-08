FROM registry.mesos-vpcqa.otenv.com/ot-ubuntu:latest
ADD . /otpl-ami-ubuntu
ENTRYPOINT /otpl-ami-ubuntu/build-ami.sh
