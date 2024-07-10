#!/bin/bash
set -e

###############################################################################
# General configurations
###############################################################################

declare -A GIT_REL
GIT_REL[imx-atf]=rel_imx_5.4.70_2.3.0
GIT_REL[uboot-imx]=imx_v2020.04_5.4.70_2.3.0
GIT_REL[linux-imx]=lf-5.15.y
GIT_REL[imx-mkimage]=lf-6.1.1-1.0.0

# Distribution for rootfs
# - buildroot
# - debian
: ${DISTRO:=buildroot}

## Buildroot Options
: ${BUILDROOT_VERSION:=2023.11}
: ${BUILDROOT_DEFCONFIG:=buildroot_defconfig}
: ${BUILDROOT_ROOTFS_SIZE:=512M}
## Debian Options
: ${DEBIAN_VERSION:=bullseye}
: ${DEBIAN_ROOTFS_SIZE:=936M}
: ${DEBIAN_PACKAGES:="apt-transport-https,busybox,ca-certificates,can-utils,command-not-found,chrony,curl,e2fsprogs,ethtool,fdisk,gpiod,haveged,i2c-tools,ifupdown,iputils-ping,isc-dhcp-client,initramfs-tools,libiio-utils,lm-sensors,locales,nano,net-tools,ntpdate,openssh-server,psmisc,rfkill,sudo,systemd,systemd-sysv,dbus,tio,usbutils,wget,xterm,xz-utils"}
: ${HOST_NAME:=imx8mn}
## Kernel Options:
: ${INCLUDE_KERNEL_MODULES:=true}
: ${LINUX_DEFCONFIG:=imx_v8_defconfig}

#UBOOT_ENVIRONMENT -
# - mmc:1:0 (MMC 1 Partition 0) <-- microSD on SolidSense N8 Compact
# - mmc:2:0 (MMC 2 Partition 0) <-- eMMC on SolidSense N8 Compact
# - mmc:2:1 (MMC 2 Partition boot0) <-- eMMC boot0 on SolidSense N8 Compact
# - mmc:2:2 (MMC 2 Partition boot1) <-- eMMC boot1 on SolidSense N8 Compact
: ${UBOOT_ENVIRONMENT:=mmc:1:0} # <-- default microSD on SolidSense N8 Compact

ROOTDIR=`pwd`

###
: ${SHALLOW:=true}
if [ "x$SHALLOW" == "xtrue" ]; then
        SHALLOW_FLAG="--depth 500"
fi

REPO_PREFIX=`git log -1 --pretty=format:%h || echo "unknown"`

export PATH=$ROOTDIR/build/toolchain/gcc-arm-11.2-2022.02-x86_64-aarch64-none-elf/bin:$PATH
export CROSS_COMPILE=aarch64-none-elf-
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

# Install Toolchain
if [[ ! -d $ROOTDIR/build/toolchain ]]; then
	mkdir -p $ROOTDIR/build/toolchain
	cd $ROOTDIR/build/toolchain
	wget https://developer.arm.com/-/media/Files/downloads/gnu/11.2-2022.02/binrel/gcc-arm-11.2-2022.02-x86_64-aarch64-none-elf.tar.xz
	tar -xvf gcc-arm-11.2-2022.02-x86_64-aarch64-none-elf.tar.xz
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
	wget https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/firmware-imx-8.10.bin
	bash firmware-imx-8.10.bin --auto-accept
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
echo "*** Building ATF"
cd $ROOTDIR/build/imx-atf
make -j$(nproc) PLAT=imx8mn bl31
cp build/imx8mn/release/bl31.bin $ROOTDIR/build/imx-mkimage/iMX8M/

# Build u-boot
echo "*** Building u-boot"
cd $ROOTDIR/build/uboot-imx/
make imx8mn_solidrun_defconfig
./scripts/kconfig/merge_config.sh .config $ROOTDIR/configs/uboot.extra
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
cp $ROOTDIR/build/linux-imx/arch/arm64/boot/Image ${ROOTDIR}/images/tmp/Image
cp $ROOTDIR/build/linux-imx/arch/arm64/boot/dts/freescale/*imx8mn*.dtb ${ROOTDIR}/images/tmp/
if [ "x${INCLUDE_KERNEL_MODULES}" = "xtrue" ]; then
	make -j$(nproc) modules
	rm -rf ${ROOTDIR}/images/tmp/modules
	make -j$(nproc) INSTALL_MOD_PATH="${ROOTDIR}/images/tmp/modules" modules_install
fi

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
	make ${BUILDROOT_DEFCONFIG} BR2_EXTERNAL=${ROOTDIR}/packages/buildroot-external/nvmemfuse
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
			-kernel "${ROOTDIR}/images/tmp/Image" \
			-append "console=ttyAMA0 root=/dev/vda rootfstype=ext2 ip=dhcp rw init=/stage2.sh" \

		:

		# convert to ext4
		tune2fs -O extents,uninit_bg,dir_index,has_journal rootfs.e2.orig
	fi;

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
# Bring bootlader all together
###############################################################################
echo "================================="
echo "*** Creating boot loader image"
echo "================================="
unset ARCH CROSS_COMPILE
cd $ROOTDIR/build/imx-mkimage
make clean
make SOC=iMX8MN dtbs=imx8mn-compact.dtb BL31=$ROOTDIR/build/imx-atf/build/imx8mn/release/bl31.bin flash_ddr4_val
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
		KERNEL_MODULES_SIZE_KB=$(du -s "${ROOTDIR}/images/tmp/modules/" | cut -f1)
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
	find "${ROOTDIR}/images/tmp/modules/lib/modules" -type f -not -name "*.ko*" -printf "%P\n" | e2cp -G 0 -O 0 -P 644 -s "${ROOTDIR}/images/tmp/modules/lib/modules" -d "$ROOTFS_IMG:lib/modules" -a
	find "${ROOTDIR}/images/tmp/modules/lib/modules" -type f -name "*.ko*" -printf "%P\n" | e2cp -G 0 -O 0 -P 644 -s "${ROOTDIR}/images/tmp/modules/lib/modules" -d "$ROOTFS_IMG:lib/modules" -a
fi

# e2fsck -f -y ${ROOTFS_IMG}
IMG=imx8mn-sdhc-${DISTRO}-${REPO_PREFIX}.img

IMAGE_BOOTPART_SIZE_MB=150 # bootpart size = 150MiB
IMAGE_BOOTPART_SIZE=$((IMAGE_BOOTPART_SIZE_MB*1024*1024)) # Convert megabytes to bytes 
IMAGE_ROOTPART_SIZE=`stat -c "%s" tmp/rootfs.ext4`
IMAGE_ROOTPART_SIZE_MB=$(($IMAGE_ROOTPART_SIZE / (1024 * 1024) )) # Convert bytes to megabytes
IMAGE_SIZE=$((IMAGE_BOOTPART_SIZE+IMAGE_ROOTPART_SIZE+2*1024*1024))  # additional 2M at the end
IMAGE_SIZE_MB=$(echo "$IMAGE_SIZE / (1024 * 1024)" | bc) # Convert bytes to megabytes
dd if=/dev/zero of=${IMG} bs=1M count=${IMAGE_SIZE_MB}
env PATH="$PATH:/sbin:/usr/sbin" parted --script ${IMG} mklabel msdos mkpart primary 8MiB ${IMAGE_BOOTPART_SIZE_MB}MiB mkpart primary ${IMAGE_BOOTPART_SIZE_MB}MiB $((IMAGE_SIZE_MB - 1))MiB

do_generate_extlinux ${ROOTDIR}/images/extlinux.conf ${IMG} 2

mmd -i tmp/part1.fat32 ::/extlinux
mcopy -i tmp/part1.fat32 $ROOTDIR/images/extlinux.conf ::/extlinux/extlinux.conf
mcopy -i tmp/part1.fat32 $ROOTDIR/build/linux-imx/arch/arm64/boot/Image ::/Image
mmd -i tmp/part1.fat32 ::/freescale
mcopy -s -i tmp/part1.fat32 $ROOTDIR/build/linux-imx/arch/arm64/boot/dts/freescale/*imx8mn*.dtb ::/freescale
if [ "x$DISTRO" == "xbuildroot" ]; then
       mcopy -s -i tmp/part1.fat32 $ROOTDIR/build/buildroot/output/images/rootfs.cpio.uboot ::/
fi

dd if=$ROOTDIR/build/imx-mkimage/iMX8M/flash.bin of=${IMG} bs=1K seek=32 conv=notrunc
dd if=tmp/part1.fat32 of=${IMG} bs=1M seek=8 conv=notrunc
dd if=${ROOTFS_IMG} of=${IMG} bs=1M seek=${IMAGE_BOOTPART_SIZE_MB} conv=notrunc
echo -e "\n\n*** Image is ready - images/${IMG}"
