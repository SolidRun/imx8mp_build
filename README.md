# SolidRun's i.MX8MP build scripts

## Introduction

Main intention of this repository is to produce a reference system for i.MX8MP based product evaluation.
Automatic binary releases are available on our website [IMX8MP_Images](https://images.solid-run.com/IMX8/imx8mp_build) for download.

The build script provides ready to use **Debian/Buildroot** images that can be deployed on micro SD and eMMC.

## Compiling Image from Source

### Configuration Options

The build script supports several customisation options that can be applied through environment variables:

- `BOOTSOURCE`: Select bootloader media
  - `mmc-data` (SD/eMMC Data Partition, default)
  - `mmc-boot0` (eMMC Partition boot0)
  - `mmc-boot1` (eMMC Partition boot1)
- `DISTRO`: Choose Linux distribution for rootfs
  - `buildroot` (default)
  - `debian`
- `BUILDROOT_VERSION`:  Select version of buildroot
  - `2023.11` (default)
- `BUILDROOT_DEFCONFIG`: Select buildroot defconfig file name from `config/` folder
  - `buildroot_defconfig` (default)
- `BUILDROOT_ROOTFS_SIZE`: Specify rootfs size
  - `448M` (default)
- `BR2_PRIMARY_SITE`: Use specific (local) buildroot mirror
- `DEBIAN_VERSION`
  - `bullseye` (default)
- `DEBIAN_ROOTFS_SIZE`
  - `936M` (default)
- `OPTEE_STORAGE_PRIVATE_RPMB`: enable optee-os secure storage on emmc rpmb partition
  - `true` (default)
- `OPTEE_STORAGE_PRIVATE_REE`: enable optee-os secure storage with insecure real-world fs
  - `false` (default)
- `UBOOT_FDT`: select initial dtb for bootloader before board identification
  - `uboot-imx/arch/arm/dts/*.dts` any dts in this location can be selected by basename
  - `imx8mp-cubox-m` (default)

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

### SD

Default sdcard images combine bootloader and operating system in a single image generated during the build: `images/<distro>-bootimg>-<hash>.img`

For installation to a microSD card use [etcher.io](https://etcher.io/) or Unix `dd` command:

```
# ensure card is not mounted
umount /dev/sdX*
# write image
sudo dd if=images/<distro>-bootimg>-<hash>.img of=/dev/sdX
```

**Note: `dd` command will eat your data, carefully substitute `sdX` with the name of the actual device representing the microSD connected to your PC!**

Finally connect microSD card to the device and set boot-switches accordingly.

### eMMC

1. Boot from a bootable microSD card per instructions above.

2. Interrupt at the U-Boot console by pressing a key at the prompt:

       ...
       Normal Boot
       Hit any key to stop autoboot:  0
       u-boot=>

3. Configure the target eMMC partition for bootloader by executing the respective U-Boot command (choose one):

   - `data`: `mmc partconf 2 1 7 0`
   - `boot0`: `mmc partconf 2 1 1 1`
   - `boot1`: `mmc partconf 2 1 2 2`

   Using the `boot0` partition is recommended unless special requirements dictate otherwise.

4. Prepare a USB flash drive with the Bootloader and OS images to be programmed to the eMMC:

   USB Flash drive should be formatted FAT32 (readable by most PCs) or EXT4 (readable from Linux only),
   then copy the following files as needed:

   - `images/<distro>-bootimg>-<hash>.img` -> `bootimg.img` (for OS & Bootloader combined)
   - `images/<distro>-rootimg>-<hash>.img` -> `rootimg.img` (for OS only)
   - `images/u-boot-mmc-data-<hash>.bin` -> `u-boot-mmc-data.bin` (for eMMC data partition)
   - `images/u-boot-mmc-boot0-<hash>.bin` -> `u-boot-mmc-boot0.bin` (for eMMC boot0 partition)
   - `images/u-boot-mmc-boot1-<hash>.bin` -> `u-boot-mmc-boot1.bin` (for eMMC boot1 partition)

4. Install Bootloader:

   Connect the prepared USB flash drive, confirm the board can see it's files:

       u-boot=> usb start
       starting USB...
       Bus usb@32e40000: USB EHCI 1.00
       scanning bus usb@32e40000 for devices... 3 USB Device(s) found
              scanning usb for storage devices... 1 Storage Device(s) found
       u-boot=> ls usb 0:1 /
       696254464   bootimg.img
       696254464   rootimg.img
         1166536   u-boot-mmc-boot0.bin
         1166536   u-boot-mmc-boot1.bin
         1166552   u-boot-mmc-data.bin

       5 file(s), 0 dir(s)

   Then install bootloader to the previously chosen and ocnfigured eMMC partition:

   - `data`:

          u-boot=> load usb 0:1 $kernel_addr_r u-boot-mmc-data.bin
          u-boot=> setexpr nblocks 0x$filesize + 0x1ff
          u-boot=> setexpr nblocks 0x$nblocks / 0x200
          u-boot=> mmc dev 2 0
          switch to partitions #0, OK
          mmc2(part 0) is current device
          u-boot=> mmc write $kernel_addr_r 0x40 0x$nblocks

          MMC write: dev # 2, block # 64, count 2279 ... 2279 blocks written: OK

   - `boot0`:

          u-boot=> load usb 0:1 $kernel_addr_r u-boot-mmc-boot0.bin
          u-boot=> setexpr nblocks 0x$filesize + 0x1ff
          u-boot=> setexpr nblocks 0x$nblocks / 0x200
          u-boot=> mmc dev 2 1
          switch to partitions #0, OK
          mmc2(part 1) is current device
          u-boot=> mmc write $kernel_addr_r 0 0x$nblocks

          MMC write: dev # 2, block # 0, count 2279 ... 2279 blocks written: OK

   - `boot1`:

          u-boot=> load usb 0:1 $kernel_addr_r u-boot-mmc-boot1.bin
          u-boot=> setexpr nblocks 0x$filesize + 0x1ff
          u-boot=> setexpr nblocks 0x$nblocks / 0x200
          u-boot=> mmc dev 2 2
          switch to partitions #0, OK
          mmc2(part 2) is current device
          u-boot=> mmc write $kernel_addr_r 0 0x$nblocks

          MMC write: dev # 2, block # 0, count 2279 ... 2279 blocks written: OK

5. Install OS:

   TBD.

6. Finally set boot-switches for eMMC, remove microSD and power-cycle the board.

### Boot Select

| SolidSense N8 Boot Select (DIP-Switch S1) |   1 |   2 |
| micro-SD                                  |  ON |  ON |
| eMMC                                      | OFF |  ON |

### Login

- **username:** root
- **password:** root

## Device Tree Overlays

Some add-on cards / options are shipped as device tree overlays (`.dtbo`) that
are applied on top of the base board DTB at boot. The `.dtbo` files are built
and copied to `freescale/` on the boot partition automatically, and the base
DTBs are compiled with symbols (`-@`) so overlays resolve at runtime.

To apply one, add an `FDTOVERLAYS` line to `extlinux/extlinux.conf` on the boot
partition (path is relative to the `extlinux/` dir, same as `FDTDIR`):

```
LABEL default
	MENU LABEL default
	LINUX ../Image.gz
	FDTDIR ../
	FDTOVERLAYS ../freescale/<overlay>.dtbo
	APPEND ...
```

Multiple overlays can be applied by listing several space-separated `.dtbo`
paths on the `FDTOVERLAYS` line. Without an `FDTOVERLAYS` line the board boots
on its base DTB only (no add-on devices).

Available overlays:

| Base board          | Overlay (`freescale/…dtbo`)                          | Enables                          |
| ------------------- | ---------------------------------------------------- | -------------------------------- |
| SolidSense AIOT     | `imx8mp-solidsense-aiot-addon-flash-card.dtbo`       | Flash Card J6 (OPT4001, HDC3022, LM3645) |
| HummingBoard IIoT   | `imx8mp-hummingboard-iiot-rs485-a.dtbo`              | RS485 port A                     |
| HummingBoard IIoT   | `imx8mp-hummingboard-iiot-rs485-b.dtbo`              | RS485 port B                     |
| HummingBoard IIoT   | `imx8mp-hummingboard-iiot-panel-dsi-WJ70N3TYJHMNG0.dtbo` | DSI panel (WJ70N3TYJHMNG0)   |
| HummingBoard IIoT   | `imx8mp-hummingboard-iiot-panel-lvds-WF70A8SYJHLNGA.dtbo` | LVDS panel (WF70A8SYJHLNGA)  |
| HummingBoard Pulse  | `imx8mp-hummingboard-pulse-basler.dtbo`             | Basler camera                    |
| SR-SoM (carrier)    | `imx8mp-sr-som-basler.dtbo`                          | Basler camera                    |

> Note: `FDTOVERLAYS` requires U-Boot built with `CONFIG_OF_LIBFDT_OVERLAY`.
> Always pair an overlay with its matching base board DTB.

