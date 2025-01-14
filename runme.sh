#!/bin/bash
set -e

###############################################################################
# General configurations
###############################################################################

declare -A GIT_REL
GIT_REL[imx-atf]=lf_v2.6
GIT_REL[uboot-imx]=lf_v2022.04
GIT_REL[linux-imx]=lf-5.15.y
GIT_REL[imx-mkimage]=lf-6.1.1-1.0.0
GIT_REL[imx-optee-os]=lf-6.6.23-2.0.0
GIT_REL[mfgtools]=uuu_1.4.77

# Distribution for rootfs
# - buildroot
# - debian
: ${DISTRO:=buildroot}

## Buildroot Options
: ${BUILDROOT_VERSION:=2023.11.3}
GIT_REL[buildroot]=${BUILDROOT_VERSION}
: ${BUILDROOT_DEFCONFIG:=buildroot_defconfig}
: ${BUILDROOT_ROOTFS_SIZE:=512M}
## Debian Options
# - bookworm
# - bullseye
: ${DEBIAN_VERSION:=bookworm}
: ${DEBIAN_ROOTFS_SIZE:=936M}
: ${DEBIAN_PACKAGES:="apt-transport-https,busybox,ca-certificates,can-utils,command-not-found,chrony,curl,e2fsprogs,ethtool,fdisk,gpiod,haveged,i2c-tools,ifupdown,iputils-ping,isc-dhcp-client,initramfs-tools,libiio-utils,lm-sensors,locales,nano,net-tools,ntpdate,openssh-server,psmisc,rfkill,sudo,systemd,systemd-sysv,dbus,tio,usbutils,wget,xterm,xz-utils"}
: ${HOST_NAME:=imx8mp}
## Kernel Options:
: ${INCLUDE_KERNEL_MODULES:=true}
: ${LINUX_DEFCONFIG:=imx_v8_defconfig}
# optee-os secure storage on emmc rpmb
# requires protected hardware-unique-key implemetation:
# - tee_otp_get_hw_unique_key
# Implemented by optee-os imx caam driver.
: ${OPTEE_STORAGE_PRIVATE_RPMB:=true}
# optee-os secure storage with insecure real-world fs
# requires monotonic counter implementation to be secure:
# - nv_counter_get_ree_fs
# - nv_counter_incr_ree_fs_to
# Not implemented.
: ${OPTEE_STORAGE_PRIVATE_REE:=false}

#UBOOT_ENVIRONMENT -
# - spi (SPI FLash)
# - mmc:0:* (MMC 0) <-- wifi module on i.mx8mp solidrun som
# - mmc:1:0 (MMC 1 Partition 0) <-- microSD on HummingBoard Pulse
# - mmc:1:1 (MMC 1 Partition boot0) <-- invalid on HummingBoard Pulse
# - mmc:1:2 (MMC 1 Partition boot1) <-- invalid on HummingBoard Pulse
# - mmc:2:0 (MMC 2 Partition 0) <-- eMMC on HummingBoard Pulse
# - mmc:2:1 (MMC 2 Partition boot0) <-- eMMC boot0 on HummingBoard Pulse
# - mmc:2:2 (MMC 2 Partition boot1) <-- eMMC boot1 on HummingBoard Pulse
: ${UBOOT_ENVIRONMENT:=mmc:1:0} # <-- default microSD on HummingBoard Pulse

ROOTDIR=`pwd`

###
: ${SHALLOW:=true}

REPO_PREFIX=`git log -1 --pretty=format:%h || echo "unknown"`

CPU_ARCH=$(uname -m)
if [ "x$CPU_ARCH" == "xaarch64" ]; then
	export PATH=$ROOTDIR/build/toolchain/gcc-arm-11.2-2022.02-aarch64-aarch64-none-elf/bin:$PATH
else
	export PATH=$ROOTDIR/build/toolchain/gcc-arm-11.2-2022.02-x86_64-aarch64-none-elf/bin:$PATH
fi
export CROSS_COMPILE=aarch64-none-elf-
export ARCH=arm64
PARALLEL=$(getconf _NPROCESSORS_ONLN) # Amount of parallel jobs for the builds

# Check if git is configured
GIT_CONF=`git config user.name || true`
if [ "x$GIT_CONF" == "x" ]; then
	echo "git is not configured! using fake email and username ..."
	export GIT_AUTHOR_NAME="SolidRun imx8mp_build Script"
	export GIT_AUTHOR_EMAIL="support@solid-run.com"
	export GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
	export GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
fi

# Install Toolchain
if [[ ! -d $ROOTDIR/build/toolchain ]]; then
	mkdir -p $ROOTDIR/build/toolchain
	cd $ROOTDIR/build/toolchain
	if [ "x$CPU_ARCH" == "xaarch64" ]; then
		wget https://developer.arm.com/-/media/Files/downloads/gnu/11.2-2022.02/binrel/gcc-arm-11.2-2022.02-aarch64-aarch64-none-elf.tar.xz
		tar -xvf gcc-arm-11.2-2022.02-aarch64-aarch64-none-elf.tar.xz
	else
		wget https://developer.arm.com/-/media/Files/downloads/gnu/11.2-2022.02/binrel/gcc-arm-11.2-2022.02-x86_64-aarch64-none-elf.tar.xz
		tar -xvf gcc-arm-11.2-2022.02-x86_64-aarch64-none-elf.tar.xz
	fi
fi

###############################################################################
# Source code clonig
###############################################################################

cd $ROOTDIR
COMPONENTS="imx-atf uboot-imx linux-imx imx-mkimage imx-optee-os ftpm mfgtools buildroot"
mkdir -p build
mkdir -p images/tmp/
for i in $COMPONENTS; do
	if [[ ! -d $ROOTDIR/build/$i ]]; then
		cd $ROOTDIR/build/

		if [ "x$SHALLOW" == "xtrue" ]; then
			SHALLOW_FLAG="--depth 500"
		fi

		CHECKOUT=${GIT_REL["$i"]}
		COMMIT=
		case $i in
			ftpm)
				CHECKOUT=master
				COMMIT=81abeb9fa968340438b4b0c08aa6685833f0bfa1
				SHALLOW_FLAG=
				CLONE="https://github.com/Microsoft/MSRSec.git ftpm"
			;;
			buildroot)
				CLONE="https://github.com/buildroot/buildroot"
			;;
			*)
				CLONE="https://github.com/nxp-imx/$i"
			;;
		esac

		git clone ${SHALLOW_FLAG} ${CLONE} -b $CHECKOUT
		cd $i

		if [ -n "${COMMIT}" ]; then
			git reset --hard ${COMMIT}
		fi

		if [[ -d $ROOTDIR/patches/$i/ ]]; then
			git am $ROOTDIR/patches/$i/*.patch
		fi
	fi
done

if [[ ! -d $ROOTDIR/build/firmware ]]; then
	cd $ROOTDIR/build/
	mkdir -p firmware
	cd firmware
	wget https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/firmware-imx-8.10.bin
	bash firmware-imx-8.10.bin --auto-accept
fi

# Copy firmware
cd $ROOTDIR/build/firmware
cp -v $(find . | awk '/train|hdmi_imx8|dp_imx8/' ORS=" ") ${ROOTDIR}/build/imx-mkimage/iMX8M/

###############################################################################
# Building OPTEE
###############################################################################
build_optee_ftpm() {
	local DEVKIT="$1"
	local CROSS_COMPILE=$2
	local TEE_TA_LOG_LEVEL=2

	cd $ROOTDIR/build/ftpm/TAs/optee_ta
	make -j1 \
		CFG_FTPM_USE_WOLF=y \
		TA_CPU=cortex-a53 \
		TA_CROSS_COMPILE=$CROSS_COMPILE \
		TA_DEV_KIT_DIR="$DEVKIT" \
		CFG_TEE_TA_LOG_LEVEL=$TEE_TA_LOG_LEVEL \
		ftpm

	cp -v out/*/*.ta $ROOTDIR/images/tmp/optee/
}

do_build_opteeos() {
	local PLATFORM=imx-mx8mpevk
	local TEE_CORE_LOG_LEVEL=2

	rm -rf $ROOTDIR/images/tmp/optee
	mkdir -p $ROOTDIR/images/tmp/optee

	# build optee devkit
	cd $ROOTDIR/build/imx-optee-os/
	rm -rf out
	make -j${JOBS} \
		ARCH=arm \
		PLATFORM=${PLATFORM} \
		CROSS_COMPILE64=${CROSS_COMPILE} \
		CROSS_COMPILE32=${CROSS_COMPILE} \
		CFG_ARM64_core=y \
		ta_dev_kit

	# build external TAs
	build_optee_ftpm $ROOTDIR/build/imx-optee-os/out/arm-plat-imx/export-ta_arm64 ${CROSS_COMPILE}

	# build optee os
	cd $ROOTDIR/build/imx-optee-os/

	# REE_FS OPTIONS:
	# - CFG_RPMB_FS:
	#   Enable or disable RPMB Filesystem Feature.
	# - CFG_RPMB_WRITE_KEY:
	#   Disabled by default to avoid accidental programming of key,
	#   enable if optee-os shall use rpmb for secure storage.
	#   Only required during first use.
	if [ "x$OPTEE_STORAGE_PRIVATE_REE" = "xtrue" ]; then
		REE_FS="CFG_REE_FS=y"
	else
		REE_FS="CFG_REE_FS=n"
	fi

	# RPMB_FS OPTIONS:
	# - CFG_RPMB_FS:
	#   Enable or disable RPMB Filesystem Feature.
	# - CFG_RPMB_FS_DEV_ID:
	#   Set MMC device ID of eMMC.
	# - CFG_RPMB_WRITE_KEY:
	#   Disabled by default to avoid accidental programming of key,
	#   enable if optee-os shall use rpmb for secure storage.
	#   Only required during first use.
	if [ "x$OPTEE_STORAGE_PRIVATE_RPMB" = "xtrue" ]; then
		RPMB_FS="CFG_RPMB_FS=y CFG_RPMB_FS_DEV_ID=2 CFG_RPMB_WRITE_KEY=n"
	else
		RPMB_FS="CFG_RPMB_FS=n"
	fi

	# In-Tree Early TA's
	# - avb: for optee_rpmb u-boot command
	IN_TREE_EARLY_TAS="avb/023f8f1a-292a-432b-8fc4-de8471358067"

	# External Early TA's
	# - fTPM
	EXTERNAL_EARLY_TAS="$ROOTDIR/build/ftpm/TAs/optee_ta/out/fTPM/bc50d971-d4c9-42c4-82cb-343fb7f37896.stripped.elf"

	make -j${JOBS} \
		ARCH=arm \
		PLATFORM=$PLATFORM \
		CROSS_COMPILE64=${CROSS_COMPILE} \
		CROSS_COMPILE32=${CROSS_COMPILE} \
		CFG_ARM64_core=y \
		CFG_TEE_CORE_LOG_LEVEL=$TEE_CORE_LOG_LEVEL \
		$REE_FS \
		$RPMB_FS \
		CFG_IN_TREE_EARLY_TAS="$IN_TREE_EARLY_TAS" \
		CFG_EARLY_TA=y \
		EARLY_TA_PATHS="$EXTERNAL_EARLY_TAS"

	cp out/arm-plat-imx/core/tee-pager_v2.bin $ROOTDIR/images/tmp/optee
}

echo "Building optee-os"
do_build_opteeos

###############################################################################
# Building Bootloader
###############################################################################
echo "================================="
echo "Building Bootloader"
echo "================================="

# Build ATF
echo "*** Building ATF"
cd $ROOTDIR/build/imx-atf
rm -rf build
make -j$(nproc) PLAT=imx8mp SPD=opteed bl31
cp build/imx8mp/release/bl31.bin $ROOTDIR/build/imx-mkimage/iMX8M/

# Build u-boot
echo "*** Building u-boot"
cd $ROOTDIR/build/uboot-imx/
make imx8mp_solidrun_defconfig
# make menuconfig
[[ "${UBOOT_ENVIRONMENT}" =~ (.*):(.*):(.*) ]] || [[ "${UBOOT_ENVIRONMENT}" =~ (.*) ]]
if [ "x${BASH_REMATCH[1]}" = "xmmc" ]; then
cat >> .config << EOF
CONFIG_ENV_IS_IN_MMC=y
CONFIG_SYS_MMC_ENV_DEV=${BASH_REMATCH[2]}
CONFIG_SYS_MMC_ENV_PART=${BASH_REMATCH[3]}
CONFIG_ENV_IS_IN_SPI_FLASH=n
EOF
else
	echo "ERROR: \$UBOOT_ENVIRONMENT setting invalid"
	exit 1
fi
make -j$(nproc)
set +e
cp -v $(find . | awk '/u-boot-spl.bin$|u-boot.bin$|u-boot-nodtb.bin$|.*\.dtb$|mkimage$/' ORS=" ") ${ROOTDIR}/build/imx-mkimage/iMX8M/
cp tools/mkimage ${ROOTDIR}/build//imx-mkimage/iMX8M/mkimage_uboot
set -e

###############################################################################
# Building Linux
###############################################################################
#export CROSS_COMPILE=$ROOTDIR/build/buildroot/output/host/bin/aarch64-linux-
echo "================================="
echo "*** Building Linux kernel..."
echo "================================="
cd $ROOTDIR/build/linux-imx
make $LINUX_DEFCONFIG
./scripts/kconfig/merge_config.sh .config $ROOTDIR/configs/kernel.extra
# make menuconfig
make -j$(nproc) Image dtbs
rm -rf ${ROOTDIR}/images/tmp/linux
mkdir -p ${ROOTDIR}/images/tmp/linux/boot/freescale
cp $ROOTDIR/build/linux-imx/arch/arm64/boot/Image ${ROOTDIR}/images/tmp/linux/boot/Image
cp $ROOTDIR/build/linux-imx/arch/arm64/boot/dts/freescale/*imx8mp*.dtb ${ROOTDIR}/images/tmp/linux/boot/freescale/
cp -v System.map ${ROOTDIR}/images/tmp/linux/boot/
cp -v .config ${ROOTDIR}/images/tmp/linux/boot/config
if [ "x${INCLUDE_KERNEL_MODULES}" = "xtrue" ]; then
	make -j$(nproc) modules
	make -j$(nproc) INSTALL_MOD_PATH="${ROOTDIR}/images/tmp/linux/usr" modules_install
fi
KRELEASE=`make kernelrelease`
cd ${ROOTDIR}/images/tmp/linux; tar --owner=root --group=root -cpf ${ROOTDIR}/images/linux-${REPO_PREFIX}.tar *

# Build external Linux Headers package for compiling modules
cd $ROOTDIR/build/linux-imx
rm -rf ${ROOTDIR}/images/tmp/linux-headers
mkdir -p ${ROOTDIR}/images/tmp/linux-headers
tempfile=$(mktemp)
find . -name Makefile\* -o -name Kconfig\* -o -name \*.pl > $tempfile
find arch/arm64/include .config Module.symvers include scripts -type f >> $tempfile
tar -c -f - -T $tempfile | tar -C ${ROOTDIR}/images/tmp/linux-headers -xf -
rm -f $tempfile
unset tempfile
cd ${ROOTDIR}/images/tmp/linux-headers; tar --owner=root --group=root -cpf ${ROOTDIR}/images/linux-headers-${REPO_PREFIX}.tar *

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
	echo -e "\nBR2_TARGET_ROOTFS_EXT2_SIZE=\"${BUILDROOT_ROOTFS_SIZE}\"" >> $ROOTDIR/build/buildroot/configs/${BUILDROOT_DEFCONFIG}
	make ${BUILDROOT_DEFCONFIG}
	# make menuconfig
	make savedefconfig BR2_DEFCONFIG="${ROOTDIR}/build/buildroot/defconfig"
	make -j${PARALLEL}
	cp $ROOTDIR/build/buildroot/output/images/rootfs.ext2 $ROOTDIR/images/tmp/rootfs.ext4
	cp $ROOTDIR/build/buildroot/output/images/rootfs* $ROOTDIR/images/tmp/
	# Preparing initrd
	mkimage -A arm64 -O linux -T ramdisk -d $ROOTDIR/images/tmp/rootfs.cpio $ROOTDIR/images/tmp/initrd.img
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
			-kernel "${ROOTDIR}/images/tmp/linux/boot/Image" \
			-append "console=ttyAMA0 root=/dev/vda rootfstype=ext2 ip=dhcp rw init=/stage2.sh" \

		:

		# convert to ext4
		tune2fs -O extents,uninit_bg,dir_index,has_journal rootfs.e2.orig
	fi;

	# export final rootfs for next steps
	cp --sparse=always rootfs.e2.orig "${ROOTDIR}/images/tmp/rootfs.ext4"

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
MENU TITLE SolidRun i.MX8MP Reference BSP
LABEL default
	MENU LABEL default
	LINUX ../Image
	FDTDIR ../
	APPEND console=\${console} root=PARTUUID=$PARTUUID rw rootwait \${bootargs}
EOF
}

###############################################################################
# Bring bootlader all together
###############################################################################
echo "================================="
echo "*** Creating boot loader image"
echo "================================="
unset ARCH CROSS_COMPILE
cd $ROOTDIR/build/imx-mkimage
make clean
make SOC=iMX8MP dtbs=imx8mp-solidrun.dtb TEE=$ROOTDIR/images/tmp/optee/tee-pager_v2.bin flash_evk
mkdir -p $ROOTDIR/images
cp -v iMX8M/flash.bin $ROOTDIR/images/u-boot-${UBOOT_ENVIRONMENT}-${REPO_PREFIX}.bin

###############################################################################
# Assembling Boot Image
###############################################################################
echo "================================="
echo "Assembling Boot Image"
echo "================================="

# Create disk images
echo "*** Creating disk images"
cd $ROOTDIR/images
dd if=/dev/zero of=tmp/part1.fat32 bs=1M count=148
env PATH="$PATH:/sbin:/usr/sbin" mkdosfs tmp/part1.fat32

if [ "x${INCLUDE_KERNEL_MODULES}" = "xtrue" ]; then

	if [ "x$DISTRO" != "xbuildroot" ]; then
		# Prepare rootfs
		echo "Preparing rootfs"
		KERNEL_MODULES_SIZE_KB=$(du -s "${ROOTDIR}/images/tmp/linux/usr/lib/modules/" | cut -f1)
		KERNEL_MODULES_SIZE_MB=$(echo "$KERNEL_MODULES_SIZE_KB / 1024 + 1" | bc)
		ROOTFS_SIZE=`stat -c "%s" tmp/rootfs.ext4`
		ROOTFS_SIZE_MB=$(($ROOTFS_SIZE / (1024 * 1024) ))
		TOTAL_ROOTFS_SIZE_MB=$((ROOTFS_SIZE_MB + KERNEL_MODULES_SIZE_MB))
		truncate -s ${TOTAL_ROOTFS_SIZE_MB}M ${ROOTFS_IMG}
		set +e
		e2fsck -f -y ${ROOTFS_IMG}
		set -e
		resize2fs ${ROOTFS_IMG}
	fi

	echo "copying kernel modules ..."
	find "${ROOTDIR}/images/tmp/linux/usr/lib/modules" -type f -not -name "*.ko*" -printf "%P\n" | e2cp -G 0 -O 0 -P 644 -s "${ROOTDIR}/images/tmp/linux/usr/lib/modules" -d "$ROOTFS_IMG:usr/lib/modules" -a
	find "${ROOTDIR}/images/tmp/linux/usr/lib/modules" -type f -name "*.ko*" -printf "%P\n" | e2cp -G 0 -O 0 -P 644 -s "${ROOTDIR}/images/tmp/linux/usr/lib/modules" -d "$ROOTFS_IMG:usr/lib/modules" -a
fi

# e2fsck -f -y ${ROOTFS_IMG}
IMG=imx8mp-sdhc-${DISTRO}-${REPO_PREFIX}.img

# note: partition start and end sectors are inclusive, add/subtract 1 where appropriate
IMAGE_BOOTPART_START=$((8*1024*1024)) # partition start aligned to 8MiB
IMAGE_BOOTPART_SIZE=$((150*1024*1024)) # bootpart size = 150MiB
IMAGE_BOOTPART_END=$((IMAGE_BOOTPART_START+IMAGE_BOOTPART_SIZE-1))
IMAGE_ROOTPART_START=$((IMAGE_BOOTPART_END+1))
IMAGE_ROOTPART_SIZE=`stat -c "%s" tmp/rootfs.ext4`
IMAGE_ROOTPART_END=$((IMAGE_ROOTPART_START+IMAGE_ROOTPART_SIZE-1))
IMAGE_SIZE=$((IMAGE_ROOTPART_END+1))
truncate -s ${IMAGE_SIZE} ${IMG}
env PATH="$PATH:/sbin:/usr/sbin" parted --script ${IMG} mklabel msdos mkpart primary ${IMAGE_BOOTPART_START}B ${IMAGE_BOOTPART_END}B mkpart primary ${IMAGE_ROOTPART_START}B ${IMAGE_ROOTPART_END}B

do_generate_extlinux ${ROOTDIR}/images/extlinux.conf ${IMG} 2

mmd -i tmp/part1.fat32 ::/extlinux
mcopy -i tmp/part1.fat32 $ROOTDIR/images/extlinux.conf ::/extlinux/extlinux.conf
mcopy -i tmp/part1.fat32 $ROOTDIR/images/tmp/linux/boot/Image ::/Image
mmd -i tmp/part1.fat32 ::/freescale
mcopy -s -i tmp/part1.fat32 $ROOTDIR/images/tmp/linux/boot/freescale/*.dtb ::/freescale
if [ "x$DISTRO" == "xbuildroot" ]; then
       mcopy -s -i tmp/part1.fat32 $ROOTDIR/build/buildroot/output/images/rootfs.cpio.uboot ::/
fi

dd if=$ROOTDIR/build/imx-mkimage/iMX8M/flash.bin of=${IMG} bs=1K seek=32 conv=notrunc
dd if=tmp/part1.fat32 of=${IMG} seek=$((IMAGE_BOOTPART_START/512)) conv=notrunc,sparse
dd if=${ROOTFS_IMG} of=${IMG} seek=$((IMAGE_ROOTPART_START/512)) conv=notrunc,sparse
dd if=${ROOTFS_IMG} of=${IMG} seek=$((IMAGE_ROOTPART_START/512)) conv=notrunc,sparse
echo -e "\n\n*** Image is ready - images/${IMG}"
