# SolidRun's i.MX8MP based HummingBoard Pulse build scripts

## Introduction

Main intention of this repository is to produce a reference system for i.MX8MP based product evaluation.
Automatic binary releases are available on our website [IMX8MP_Images](https://images.solid-run.com/IMX8/imx8mp_build) for download.

The build script provides ready to use **Debian/Buildroot** images that can be deployed on micro SD and future on eMMC.

## Source code versions

- [U-boot lf_v2022.04](https://github.com/nxp-imx/uboot-imx/tree/lf_v2022.04)
- [Linux kernel lf-5.15.y](https://github.com/nxp-imx/linux-imx/tree/lf-5.15.y)
- [Buildroot 2020.11.2](https://github.com/buildroot/buildroot/tree/2020.11.2)
- [Debian bullseye](https://deb.debian.org/debian)

## Compiling Image from Source

### Configuration Options

The build script supports several customisation options that can be applied through environment variables:

- INCLUDE_KERNEL_MODULES: include kernel modules in rootfs
   - true (default)
   - false
- DISTRO: Choose Linux distribution for rootfs
  - buildroot (default)
  - debian
- BUILDROOT_VERSION
  - 2020.11.2 (default)
- BUILDROOT_DEFCONFIG: Choose specific config file name from `config/` folder
  - buildroot_defconfig (default)
- BR2_PRIMARY_SITE: Use specific (local) buildroot mirror
- DEBIAN_VERSION
  - bullseye (default)
- DEBIAN_ROOTFS_SIZE
  - 936M (default)

#### Example
   generating buildroot image
   ```
   ./runme.sh
   ```
   generating debian image
   ```
   DISTRO=debian ./runme.sh
   ```   

## Build with Docker
A docker image providing a consistent build environment can be used as below:

1. build container image (first time only)
   ```
   docker build -t imx8mp_build docker
   # optional with an apt proxy, e.g. apt-cacher-ng
   # docker build --build-arg APTPROXY=http://127.0.0.1:3142 -t imx8mp_build docker
   ```
2. invoke build script in working directory
   ```
   docker run -i -t -v "$PWD":/work imx8mp_build -u $(id -u) -g $(id -g)
   ```

### rootless Podman

Due to the way podman performs user-id mapping, the root user inside the container (uid=0, gid=0) will be mapped to the user running podman (e.g. 1000:100).
Therefore in order for the build directory to be owned by current user, `-u 0 -g 0` have to be passed to *docker run*.

## Deploying
For SD card bootable images, plug in a micro SD into your machine and run the following, where sdX is the location of the SD card got probed into your machine -

```
umount /media/<relevant directory>
sudo dd if=images/microsd-<hash>.img of=/dev/sdX
```

And then set the HummingBoard Pulse DIP switch to boot from SD

### Login
- **username:** root
- **password:** root

== Legal notice and licensing
All of the end products of this project (toolchain, root filesystem, kernel,
bootloaders) can contain both open source software and proprietary binaries,
released under various licenses.

Using open source software gives you the freedom to build rich embedded
systems, choosing from a wide range of packages, but also imposes some
obligations that you must know and honour.
Some licenses require you to publish the license text in the documentation of
your product. Others require you to redistribute the source code of the
software to those that receive your product.

The exact requirements of each license are documented in each repository that
is downloaded, and it is your responsibility (or that of your legal office)
to comply with those requirements.
