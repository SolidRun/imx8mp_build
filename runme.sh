#!/bin/bash

###############################################################################
# General configurations
###############################################################################

declare -A GIT_REL
GIT_REL[imx-atf]=lf-6.6.36-2.1.0
GIT_REL[uboot-imx]=lf-6.6.52-2.2.0
GIT_REL[linux-imx]=lf-6.6.52-2.2.0
GIT_REL[imx-mkimage]=lf-6.6.52-2.2.0
PKG_VER[firmware-imx]=8.26-d4c33ab

# Distribution for rootfs
# - buildroot
# - debian
: ${DISTRO:=buildroot}

## Buildroot Options
: ${BUILDROOT_VERSION:=2023.11}
: ${BUILDROOT_DEFCONFIG:=buildroot_defconfig}
: ${BUILDROOT_ROOTFS_SIZE:=192M}
: ${BR2_PRIMARY_SITE:=}
## Debian Options
: ${DEBIAN_VERSION:=bullseye}
: ${DEBIAN_ROOTFS_SIZE:=936M}
: ${DEBIAN_PACKAGES:="apt-transport-https,busybox,ca-certificates,can-utils,command-not-found,chrony,curl,e2fsprogs,ethtool,fdisk,gpiod,haveged,i2c-tools,ifupdown,iputils-ping,isc-dhcp-client,initramfs-tools,libiio-utils,lm-sensors,locales,nano,net-tools,ntpdate,openssh-server,psmisc,rfkill,sudo,systemd,systemd-sysv,dbus,tio,usbutils,wget,xterm,xz-utils"}
: ${HOST_NAME:=imx8mn}

# Boot Source
# - mmc-data (SD/eMMC Partition 0)
# - mmc-boot0 (eMMC Partition boot0)
# - mmc-boot1 (eMMC Partition boot1)
: ${BOOTSOURCE:=mmc-data}

ROOTDIR=`pwd`

###
: ${SHALLOW:=true}
if [ "x$SHALLOW" == "xtrue" ]; then
        SHALLOW_FLAG="--depth 500"
fi

# we don't have status code checks for each step - use "-e" with a trap instead
function error() {
	status=$?
	printf "ERROR: Line %i failed with status %i: %s\n" $BASH_LINENO $status "$BASH_COMMAND" >&2
	exit $status
}
trap error ERR
set -e

REPO_PREFIX=`git log -1 --pretty=format:%h || echo "unknown"`

export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64
PARALLEL=$(getconf _NPROCESSORS_ONLN) # Amount of parallel jobs for the builds

# Check if git is configured
GIT_CONF=`git config user.name || true`
if [ "x$GIT_CONF" == "x" ]; then
	echo "git is not configured! using fake email and username ..."
	export GIT_AUTHOR_NAME="SolidRun imx8mn_build Script"
	export GIT_AUTHOR_EMAIL="support@solid-run.com"
	export GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
	export GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
fi

###############################################################################
# Source code clonig
###############################################################################

cd $ROOTDIR
COMPONENTS="imx-atf uboot-imx linux-imx imx-mkimage"
mkdir -p build
mkdir -p images/tmp/
for i in $COMPONENTS; do
	if [[ ! -d $ROOTDIR/build/$i ]]; then
		cd $ROOTDIR/build/

		CHECKOUT=${GIT_REL["$i"]}
		git clone ${SHALLOW_FLAG} https://github.com/nxp-imx/$i -b $CHECKOUT
		cd $i
		if [[ -d $ROOTDIR/patches/$i/ ]]; then
			git am $ROOTDIR/patches/$i/*.patch
		fi
	fi
done

if [[ ! -d $ROOTDIR/build/mfgtools ]]; then
	cd $ROOTDIR/build
	git clone https://github.com/NXPmicro/mfgtools.git -b uuu_1.4.77
	cd mfgtools
	git am ../../patches/mfgtools/*.patch
	cmake .
	make
fi

if [[ ! -d $ROOTDIR/build/firmware ]]; then
	cd $ROOTDIR/build/
	mkdir -p firmware
	cd firmware
	wget https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/firmware-imx-${PKG_VER["firmware-imx"]}.bin
	bash firmware-imx-${PKG_VER["firmware-imx"]}.bin --auto-accept
fi

if [[ ! -d $ROOTDIR/build/buildroot ]]; then
	cd $ROOTDIR/build
	git clone ${SHALLOW_FLAG} https://github.com/buildroot/buildroot -b $BUILDROOT_VERSION

	if [[ -d $ROOTDIR/patches/buildroot ]]; then
		cd $ROOTDIR/build/buildroot
		git am $ROOTDIR/patches/buildroot/*.patch
	fi
fi

# Copy firmware
cd $ROOTDIR/build/firmware
cp -v $(find . | awk '/ddr4_.mem|lpddr4_.*train|hdmi_imx8|dp_imx8/' ORS=" ") ${ROOTDIR}/build/imx-mkimage/iMX8M/

###############################################################################
# Building Bootloader
###############################################################################
echo "================================="
echo "Building Bootloader"
echo "================================="

# Build ATF
do_build_atf() {
	cd $ROOTDIR/build/imx-atf
	make -j$(nproc) PLAT=imx8mn bl31
	cp -v build/imx8mn/release/bl31.bin $ROOTDIR/build/imx-mkimage/iMX8M/
}
echo "*** Building ATF"
do_build_atf

do_build_uboot() {
	cd $ROOTDIR/build/uboot-imx
	./scripts/kconfig/merge_config.sh configs/solidsense-n8_defconfig $ROOTDIR/configs/uboot.extra

	if [ "x${BOOTSOURCE}" = "xmmc-data" ];  then
		# u-boot selects mmc device (1/2) automatically during boot, only set partition/offset
cat >> .config << EOF
CONFIG_ENV_IS_IN_MMC=y
CONFIG_SYS_MMC_ENV_PART=0
CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=0x300
EOF
	fi
	if [ "x${BOOTSOURCE}" = "xmmc-boot0" ];  then
		# u-boot selects mmc device (1/2) automatically during boot, only set partition/offset
cat >> .config << EOF
CONFIG_ENV_IS_IN_MMC=y
CONFIG_SYS_MMC_ENV_PART=1
CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=0x2c0
EOF
	fi
	if [ "x${BOOTSOURCE}" = "xmmc-boot1" ];  then
		# u-boot selects mmc device (1/2) automatically during boot, only set partition/offset
cat >> .config << EOF
CONFIG_ENV_IS_IN_MMC=y
CONFIG_SYS_MMC_ENV_PART=2
CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=0x2c0
EOF
	fi

	make olddefconfig
	# make menuconfig
	make -j$(nproc)
	make savedefconfig

	cp -v $(find . -type f | awk '/u-boot-spl.bin$|u-boot.bin$|u-boot-nodtb.bin$|.*\.dtb$|mkimage$/' ORS=" ") ${ROOTDIR}/build/imx-mkimage/iMX8M/
	cp -v tools/mkimage ${ROOTDIR}/build//imx-mkimage/iMX8M/mkimage_uboot
}
echo "*** Building u-boot"
do_build_uboot

# Assemble boot image
do_build_imximage() {
	unset ARCH CROSS_COMPILE
	cd $ROOTDIR/build/imx-mkimage
	make clean
	make SOC=iMX8MN dtbs=imx8mn-solidsense-n8-compact.dtb BL31=$ROOTDIR/build/imx-atf/build/imx8mn/release/bl31.bin flash_ddr4_evk_no_hdmi
	mkdir -p $ROOTDIR/images
	cp -v iMX8M/flash.bin $ROOTDIR/images/u-boot-${BOOTSOURCE}-${REPO_PREFIX}.bin
}
do_build_imximage

###############################################################################
# Building Linux
###############################################################################
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
echo "================================="
echo "*** Building Linux kernel..."
echo "================================="
cd $ROOTDIR/build/linux-imx
./scripts/kconfig/merge_config.sh arch/arm64/configs/imx_v8_defconfig $ROOTDIR/configs/kernel.extra
make olddefconfig
# make menuconfig
make -j$(nproc) Image Image.gz dtbs modules
make savedefconfig
KRELEASE=`make kernelrelease`
rm -rf $ROOTDIR/images/tmp/linux
mkdir -p $ROOTDIR/images/tmp/linux
mkdir -p $ROOTDIR/images/tmp/linux/boot/freescale
make -j$(nproc) INSTALL_MOD_PATH=$ROOTDIR/images/tmp/linux/usr INSTALL_MOD_STRIP=1 modules_install
cp $ROOTDIR/build/linux-imx/System.map $ROOTDIR/images/tmp/linux/boot
cp $ROOTDIR/build/linux-imx/arch/arm64/boot/Image $ROOTDIR/images/tmp/linux/boot
cp $ROOTDIR/build/linux-imx/arch/arm64/boot/Image.gz $ROOTDIR/images/tmp/linux/boot
cp $ROOTDIR/build/linux-imx/arch/arm64/boot/dts/freescale/imx8mn-solidsense-n8-compact.dtb $ROOTDIR/images/tmp/linux/boot/freescale/

# TODO: can build external modules here

# regenerate modules dependencies
depmod -b "${ROOTDIR}/images/tmp/linux/usr" -F "${ROOTDIR}/images/tmp/linux/boot/System.map" ${KRELEASE}

function pkg_kernel() {
# package kernel individually
	rm -f "${ROOTDIR}/images/linux/linux.tar*"
	cd "${ROOTDIR}/images/tmp/linux"; tar -c --owner=root:0 -f "${ROOTDIR}/images/linux-${REPO_PREFIX}.tar" boot/* usr/lib/modules/*; cd "${ROOTDIR}"
}
pkg_kernel

function pkg_kernel_headers() {
	# Build external Linux Headers package for compiling modules
	cd "${ROOTDIR}/build/linux-imx"
	rm -rf "${ROOTDIR}/images/tmp/linux-headers"
	mkdir -p ${ROOTDIR}/images/tmp/linux-headers
	tempfile=$(mktemp)
	find . -name Makefile\* -o -name Kconfig\* -o -name \*.pl > $tempfile
	find arch/arm64/include include scripts -type f >> $tempfile
	tar -c -f - -T $tempfile | tar -C "${ROOTDIR}/images/tmp/linux-headers" -xf -
	cd "${ROOTDIR}/build/linux-imx"
	find arch/arm64/include .config Module.symvers include scripts -type f > $tempfile
	tar -c -f - -T $tempfile | tar -C "${ROOTDIR}/images/tmp/linux-headers" -xf -
	rm -f $tempfile
	unset tempfile
	cd "${ROOTDIR}/images/tmp/linux-headers"
	tar cpf "${ROOTDIR}/images/linux-headers-${REPO_PREFIX}.tar" *
}
pkg_kernel_headers

###############################################################################
# Building FS Buildroot/Debian
###############################################################################

ROOTFS_IMG="$ROOTDIR/images/tmp/rootfs.ext4"

do_build_buildroot() {
	echo "================================="
	echo "*** Building Buildroot FS..."
	echo "================================="
	cd $ROOTDIR/build/buildroot

	export FORCE_UNSAFE_CONFIGURE=1
	cp $ROOTDIR/configs/${BUILDROOT_DEFCONFIG} $ROOTDIR/build/buildroot/configs
	printf 'BR2_PRIMARY_SITE="%s"\n' "${BR2_PRIMARY_SITE}" >> $ROOTDIR/build/buildroot/configs/${BUILDROOT_DEFCONFIG}
	echo -e "\nBR2_TARGET_ROOTFS_EXT2_SIZE=\"${BUILDROOT_ROOTFS_SIZE}\"" >> $ROOTDIR/build/buildroot/configs/${BUILDROOT_DEFCONFIG}
	make ${BUILDROOT_DEFCONFIG} BR2_EXTERNAL=${ROOTDIR}/packages/buildroot-external/nvmemfuse
	make savedefconfig BR2_DEFCONFIG="${ROOTDIR}/build/buildroot/defconfig"
	make -j${PARALLEL}
	cp $ROOTDIR/build/buildroot/output/images/rootfs.ext2 $ROOTDIR/images/tmp/rootfs.ext4
}

do_build_debian() {
	echo "================================="
	echo "*** Building Debian FS..."
	echo "================================="
	mkdir -p $ROOTDIR/build/debian
	cd $ROOTDIR/build/debian

	# (re-)generate only if rootfs doesn't exist or runme script has changed
	if [ ! -f rootfs.e2.orig ] || [[ ${ROOTDIR}/${BASH_SOURCE[0]} -nt rootfs.e2.orig ]]; then
		rm -f rootfs.e2.orig

		# bootstrap a first-stage rootfs
		rm -rf stage1
		fakeroot debootstrap --variant=minbase \
			--arch=arm64 --components=main,contrib,non-free \
			--foreign \
			--include=${DEBIAN_PACKAGES} \
			${DEBIAN_VERSION} \
			stage1 \
			https://deb.debian.org/debian

		# prepare init-script for second stage inside VM
		cat > stage1/stage2.sh << EOF
#!/bin/sh

# run second-stage bootstrap
/debootstrap/debootstrap --second-stage

# set empty root password
# passwd -d root
echo "root:root" | chpasswd

#Set hosts
echo "${HOST_NAME}" | sudo tee /etc/hostname
echo "127.0.0.1 localhost ${HOST_NAME}" | sudo tee -a /etc/hosts

# delete self
rm -f /stage2.sh

# flush disk
sync

# power-off
reboot -f
EOF
		chmod +x stage1/stage2.sh

		# create empty partition image
		dd if=/dev/zero of=rootfs.e2.orig bs=1 count=0 seek=${DEBIAN_ROOTFS_SIZE}

		# create filesystem from first stage
		mkfs.ext2 -L rootfs -E root_owner=0:0 -d stage1 rootfs.e2.orig

		# bootstrap second stage within qemu
		qemu-system-aarch64 \
			-m 1G \
			-M virt \
			-cpu cortex-a57 \
			-smp 4 \
			-netdev user,id=eth0 \
			-device virtio-net-device,netdev=eth0 \
			-drive file=rootfs.e2.orig,if=none,format=raw,id=hd0 \
			-device virtio-blk-device,drive=hd0 \
			-nographic \
			-no-reboot \
			-kernel "$ROOTDIR/images/tmp/linux/boot/Image" \
			-append "console=ttyAMA0 root=/dev/vda rootfstype=ext2 ip=dhcp rw init=/stage2.sh" \

		:

		# convert to ext4
		tune2fs -O extents,uninit_bg,dir_index,has_journal rootfs.e2.orig

		# fix filesystem errors
		e2fsck -f -y rootfs.e2.orig || true
	fi

	# export final rootfs for next steps
	cp rootfs.e2.orig "${ROOTDIR}/images/tmp/rootfs.ext4"

	# apply overlay (configuration + data files only - can't "chmod +x")
	find "${ROOTDIR}/overlay/${DISTRO}" -type f -printf "%P\n" | e2cp -G 0 -O 0 -s "${ROOTDIR}/overlay/${DISTRO}" -d "${ROOTDIR}/images/tmp/rootfs.ext4:" -a
}

# BUILD selected Distro buildroot/debian
do_build_${DISTRO}

do_generate_extlinux() {
	local EXTLINUX=$1
	local DISKIMAGE=$2
	local PARTNUMBER=$3
	local PARTUUID=`blkid -s PTUUID -o value ${DISKIMAGE}`
	PARTUUID=${PARTUUID}'-0'${PARTNUMBER} # specific partition uuid

	mkdir -p $(dirname ${EXTLINUX})
	cat > ${EXTLINUX} << EOF
TIMEOUT 1
DEFAULT default
MENU TITLE SolidRun i.MX8MN Reference BSP
LABEL default
	MENU LABEL default
	LINUX ../Image
	FDTDIR ../
	APPEND console=\${console} root=PARTUUID=$PARTUUID rw rootwait \${bootargs}
EOF
}

###############################################################################
# Assembling Boot Image
###############################################################################
echo "================================="
echo "Assembling Boot Image"
echo "================================="

# Create disk images
echo "*** Creating disk images"
cd $ROOTDIR/images

# use different filenames for OS-only and combined images
if [ "x${BOOTSOURCE}" = "xmmc-data" ]; then
	IMG=${DISTRO}-bootimg-${REPO_PREFIX}.img
else
	IMG=${DISTRO}-rootimg-${REPO_PREFIX}.img
fi

# calculate partition table
IMAGE_BOOTPART_START=$((4*1024*1024)) # start first partition after 4MB mark (reserved for u-boot)
IMAGE_BOOTPART_SIZE=$((60*1024*1024)) # bootpart size = 60MiB
IMAGE_BOOTPART_END=$((IMAGE_BOOTPART_START+IMAGE_BOOTPART_SIZE-1))
IMAGE_ROOTPART_START=$((IMAGE_BOOTPART_END+1))
IMAGE_ROOTPART_SIZE=`stat -c "%s" tmp/rootfs.ext4`
IMAGE_ROOTPART_END=$((IMAGE_ROOTPART_START+IMAGE_ROOTPART_SIZE-1))
IMAGE_SIZE=$((IMAGE_ROOTPART_END+1))

rm -f tmp/part1.fat32; truncate -s ${IMAGE_BOOTPART_SIZE} tmp/part1.fat32
env PATH="$PATH:/sbin:/usr/sbin" mkdosfs tmp/part1.fat32
rm -f ${IMG}; truncate -s ${IMAGE_SIZE} ${IMG}
env PATH="$PATH:/sbin:/usr/sbin" parted --script ${IMG} mklabel msdos mkpart primary ${IMAGE_BOOTPART_START}B ${IMAGE_BOOTPART_END}B mkpart primary ${IMAGE_ROOTPART_START}B ${IMAGE_ROOTPART_END}B

echo "copying kernel modules ..."
find "${ROOTDIR}/images/tmp/linux/usr/lib/modules" -type f -not -name "*.ko*" -printf "%P\n" | e2cp -G 0 -O 0 -P 644 -s "${ROOTDIR}/images/tmp/linux/usr/lib/modules" -d "${ROOTDIR}/images/tmp/rootfs.ext4:usr/lib/modules" -a
find "${ROOTDIR}/images/tmp/linux/usr/lib/modules" -type f -name "*.ko*" -printf "%P\n" | e2cp -G 0 -O 0 -P 644 -s "${ROOTDIR}/images/tmp/linux/usr/lib/modules" -d "${ROOTDIR}/images/tmp/rootfs.ext4:usr/lib/modules" -a -v

do_generate_extlinux ${ROOTDIR}/images/extlinux.conf ${IMG} 2

mmd -i tmp/part1.fat32 ::/extlinux
mcopy -i tmp/part1.fat32 $ROOTDIR/images/extlinux.conf ::/extlinux/extlinux.conf
mcopy -i tmp/part1.fat32 $ROOTDIR/build/linux-imx/arch/arm64/boot/Image ::/Image
mmd -i tmp/part1.fat32 ::/freescale
mcopy -s -i tmp/part1.fat32 $ROOTDIR/build/linux-imx/arch/arm64/boot/dts/freescale/*imx8mn*.dtb ::/freescale

# copy boot and rootfs partitions to image
dd if=tmp/part1.fat32 of=${IMG} bs=1M seek=4 conv=notrunc
dd if=${ROOTFS_IMG} of=${IMG} bs=1M seek=64 conv=notrunc

# generate combined image with os + bootloader
if [ "x${BOOTSOURCE}" = "xmmc-data" ]; then
	dd if=$ROOTDIR/build/imx-mkimage/iMX8M/flash.bin of=${IMG} bs=1K seek=32 conv=notrunc
fi

echo -e "\n\n*** Images are ready:\n- images/u-boot-${BOOTSOURCE}-${REPO_PREFIX}.bin\n- images/${IMG}"
