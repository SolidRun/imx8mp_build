#!/bin/bash
###############################################################################
# General configurations
###############################################################################

declare -A GIT_REL GIT_COMMIT GIT_URL
GIT_REL[imx-atf]=lf-6.6.36-2.1.0
GIT_URL[imx-atf]=https://github.com/nxp-imx/imx-atf.git
GIT_REL[uboot-imx]=lf-6.6.52-2.2.0-sr-imx8
GIT_COMMIT[uboot-imx]=a31369d37a4b1c7c20ffe21cfefd41620d7c8e75
GIT_URL[uboot-imx]=https://github.com/SolidRun/u-boot.git
GIT_REL[linux-imx]=lf-6.6-sr-imx8
GIT_COMMIT[linux-imx]=956c4e02e2275edf68d4bde59e68b74450029a09
GIT_URL[linux-imx]=https://github.com/SolidRun/linux-stable.git
GIT_REL[imx-mkimage]=lf-6.6.52-2.2.0
GIT_URL[imx-mkimage]=https://github.com/nxp-imx/imx-mkimage.git
GIT_REL[imx-optee-os]=lf-6.6.23-2.0.0
GIT_URL[imx-optee-os]=https://github.com/nxp-imx/imx-optee-os.git
PKG_VER[firmware-imx]=8.26-d4c33ab
GIT_REL[mfgtools]=uuu_1.4.77
GIT_URL[mfgtools]=https://github.com/NXPmicro/mfgtools.git
GIT_REL[ftpm]=master
GIT_COMMIT[ftpm]=af2185656b0c47afc87b76fa89283bdf170e2759
GIT_URL[ftpm]=https://github.com/Microsoft/MSRSec.git
GIT_REL[isp-vvcam]=lf-6.6.y_2.2.0
GIT_URL[isp-vvcam]=https://github.com/nxp-imx/isp-vvcam.git

# Distribution for rootfs
# - buildroot
# - debian
: ${DISTRO:=buildroot}

## Buildroot Options
: ${BUILDROOT_VERSION:=2023.11}
: ${BUILDROOT_DEFCONFIG:=buildroot_defconfig}
: ${BUILDROOT_ROOTFS_SIZE:=448M}
: ${BR2_PRIMARY_SITE:=}
## Debian Options
: ${DEBIAN_VERSION:=bullseye}
: ${DEBIAN_ROOTFS_SIZE:=936M}
: ${DEBIAN_PACKAGES:="apt-transport-https,busybox,ca-certificates,can-utils,command-not-found,chrony,curl,e2fsprogs,ethtool,fdisk,gpiod,haveged,i2c-tools,ifupdown,iputils-ping,isc-dhcp-client,initramfs-tools,libiio-utils,lm-sensors,locales,nano,net-tools,ntpdate,openssh-server,psmisc,rfkill,sudo,systemd,systemd-sysv,dbus,tio,usbutils,wget,xterm,xz-utils"}
: ${HOST_NAME:=imx8mp}

# Boot Source
# - mmc-data (SD/eMMC Partition 0)
# - mmc-boot0 (eMMC Partition boot0)
# - mmc-boot1 (eMMC Partition boot1)
: ${BOOTSOURCE:=mmc-data}

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
	export GIT_AUTHOR_NAME="SolidRun imx8mp_build Script"
	export GIT_AUTHOR_EMAIL="support@solid-run.com"
	export GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
	export GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
fi

###############################################################################
# Source code clonig
###############################################################################

cd $ROOTDIR
COMPONENTS="imx-atf uboot-imx linux-imx imx-mkimage imx-optee-os ftpm mfgtools isp-vvcam"
mkdir -p build
mkdir -p images/tmp/
for i in $COMPONENTS; do
	if [[ ! -d $ROOTDIR/build/$i ]]; then
		cd $ROOTDIR/build/

		CHECKOUT=${GIT_REL["$i"]}
		git clone ${SHALLOW_FLAG} ${GIT_URL["$i"]} -b ${GIT_REL["$i"]} $i
		cd $i

		if [ -n "${GIT_COMMIT[$i]}" ]; then
			git reset --hard ${GIT_COMMIT["$i"]}
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
do_build_atf() {
	cd $ROOTDIR/build/imx-atf
	rm -rf build
	make -j$(nproc) PLAT=imx8mp SPD=opteed bl31
	cp -v build/imx8mp/release/bl31.bin $ROOTDIR/build/imx-mkimage/iMX8M/
}
echo "*** Building ATF"
do_build_atf

do_build_uboot() {
	cd $ROOTDIR/build/uboot-imx
	./scripts/kconfig/merge_config.sh configs/imx8mp_solidrun_defconfig $ROOTDIR/configs/uboot.extra

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
	make SOC=iMX8MP dtbs=imx8mp-cubox-m.dtb supp_dtbs="imx8mp-cubox-m.dtb imx8mp-hummingboard-mate.dtb imx8mp-hummingboard-pro.dtb imx8mp-hummingboard-pulse.dtb imx8mp-hummingboard-ripple.dtb" BL31=$ROOTDIR/build/imx-atf/build/imx8mp/release/bl31.bin TEE=$ROOTDIR/images/tmp/optee/tee-pager_v2.bin flash_evk
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

function build_kernel() {
	# compile kernel
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
	for prefix in cubox-m hummingboard sr-som; do
		find $ROOTDIR/build/linux-imx/arch/arm64/boot/dts/freescale/ -iname "imx8mp-${prefix}*.dtb*" -exec cp {} $ROOTDIR/images/tmp/linux/boot/freescale/ \;
	done
}

function build_kernel_headers() {
	# Generate external linux headers for compiling modules
	cd "${ROOTDIR}/build/linux-imx"
	rm -rf "${ROOTDIR}/images/tmp/linux-headers"
	mkdir -p ${ROOTDIR}/images/tmp/linux-headers
	tempfile=$(mktemp)
	find . -name Makefile\* -o -name Kconfig\* -o -name \*.pl > $tempfile
	find arch/arm64/include include scripts -type f >> $tempfile
	tar -c -f - -T $tempfile | tar -C "${ROOTDIR}/images/tmp/linux-headers" -xf -
	cd "${ROOTDIR}/build/linux-imx"
	find arch/arm64/include .config Module.symvers include scripts System.map -type f > $tempfile
	tar -c -f - -T $tempfile | tar -C "${ROOTDIR}/images/tmp/linux-headers" -xf -
	rm -f $tempfile
	unset tempfile
}

function pkg_kernel_headers() {
	# package external linux headers
	cd "${ROOTDIR}/images/tmp/linux-headers"
	tar cpf "${ROOTDIR}/images/linux-headers-${REPO_PREFIX}.tar" *
}

function pkg_kernel() {
	# package kernel and modules
	rm -f "${ROOTDIR}/images/linux/linux.tar*"
	cd "${ROOTDIR}/images/tmp/linux"; tar -c --owner=root:0 -f "${ROOTDIR}/images/linux-${REPO_PREFIX}.tar" boot/* usr/lib/modules/*; cd "${ROOTDIR}"
}

# build out of tree camera drivers
function build_isp_vvcam() {
	cd "${ROOTDIR}/build/isp-vvcam/vvcam/v4l2"
	make KERNEL_SRC="${ROOTDIR}/images/tmp/linux-headers" clean
	make -j$(nproc) KERNEL_SRC="${ROOTDIR}/images/tmp/linux-headers"
	make -j$(nproc) KERNEL_SRC="${ROOTDIR}/images/tmp/linux-headers" INSTALL_MOD_PATH="$ROOTDIR/images/tmp/linux/usr" INSTALL_MOD_DIR=extra INSTALL_MOD_STRIP=1 modules_install
}

# compile kernel
build_kernel

# build external modules
build_kernel_headers
build_isp_vvcam

# regenerate modules dependencies
depmod -b "${ROOTDIR}/images/tmp/linux/usr" -F "${ROOTDIR}/images/tmp/linux/boot/System.map" ${KRELEASE}

# generate packages
pkg_kernel_headers
pkg_kernel

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
	cp -L --sparse=always $ROOTDIR/build/buildroot/output/images/rootfs.ext2 $ROOTDIR/images/tmp/rootfs.ext4
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
	APPEND console=\${console} earlycon=ec_imx6q,0x30890000,115200 root=PARTUUID=$PARTUUID rw rootwait \${bootargs}
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
IMAGE_ROOTPART_SIZE=`stat -c "%s" ${ROOTFS_IMG}`
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
mcopy -s -i tmp/part1.fat32 $ROOTDIR/images/tmp/linux/boot/freescale/*.dtb* ::/freescale

# copy boot and rootfs partitions to image
dd if=tmp/part1.fat32 of=${IMG} bs=1M seek=4 conv=notrunc
dd if=${ROOTFS_IMG} of=${IMG} bs=1M seek=64 conv=notrunc

# generate combined image with os + bootloader
if [ "x${BOOTSOURCE}" = "xmmc-data" ]; then
	dd if=$ROOTDIR/build/imx-mkimage/iMX8M/flash.bin of=${IMG} bs=1K seek=32 conv=notrunc
fi

echo -e "\n\n*** Images are ready:\n- images/u-boot-${BOOTSOURCE}-${REPO_PREFIX}.bin\n- images/${IMG}"
