# SolidRun's i.MX8MP based HummingBoard Pulse build scripts

## Introduction
Main intention of this repository is to a buildroot based build environment for i.MX8MP based product evaluation.

The build script provides ready to use images that can be deployed on micro SD and future on eMMC.

## Build with Docker
A docker image providing a consistent build environment can be used as below:

1. build container image (first time only)
   ```
   sudo docker build -t imx8mp_build docker
   # optional with an apt proxy, e.g. apt-cacher-ng
   # docker build --build-arg APTPROXY=http://127.0.0.1:3142 -t imx8mp_build docker
   ```
2. invoke build script in working directory
   ```
   sudo docker run -i -t -v "$PWD":/work imx8mp_build -u $(id -u) -g $(id -g)
   ```

### rootless Podman

Due to the way podman performs user-id mapping, the root user inside the container (uid=0, gid=0) will be mapped to the user running podman (e.g. 1000:100).
Therefore in order for the build directory to be owned by current user, `-u 0 -g 0` have to be passed to *docker run*.

## Build with host tools
Simply running ./runme.sh, it will check for required tools, clone and build images and place results in images/ directory.

## Deploying
For SD card bootable images, plug in a micro SD into your machine and run the following, where sdX is the location of the SD card got probed into your machine -

`sudo dd if=images/microsd-<hash>.img of=/dev/sdX`

And then set the HummingBoard Pulse DIP switch to boot from SD
