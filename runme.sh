#!/bin/bash
set -e

### General setup

declare -A GIT_REL
GIT_REL[imx-atf]=lf_v2.6
GIT_REL[uboot-imx]=lf_v2022.04
GIT_REL[linux-imx]=lf-5.15.y
GIT_REL[imx-mkimage]=lf-6.1.1-1.0.0

BUILDROOT_VERSION=2020.11.2

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

###
SHALLOW=${SHALLOW:false}
if [ "x$SHALLOW" == "xtrue" ]; then
        SHALLOW_FLAG="--depth 500"
fi

# Kernel Modules:
: ${INCLUDE_KERNEL_MODULES:=true}

REPO_PREFIX=`git log -1 --pretty=format:%h`

export ARCH=arm64
ROOTDIR=`pwd`

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
fi

# Copy firmware
cd $ROOTDIR/build/firmware
cp -v $(find . | awk '/train|hdmi_imx8|dp_imx8/' ORS=" ") ${ROOTDIR}/build/imx-mkimage/iMX8M/

# Build buildroot
echo "*** Building buildroot"
cd $ROOTDIR/build/buildroot
cp $ROOTDIR/configs/buildroot_defconfig configs/imx8mp_hummingboard_pulse_defconfig
make imx8mp_hummingboard_pulse_defconfig
make
cp $ROOTDIR/build/buildroot/output/images/rootfs.ext2 $ROOTDIR/images/tmp/rootfs.ext4
ROOTFS_IMG="$ROOTDIR/images/tmp/rootfs.ext4"

export CROSS_COMPILE=$ROOTDIR/build/buildroot/output/host/bin/aarch64-linux-

# Build ATF
echo "*** Building ATF"
cd $ROOTDIR/build/imx-atf
make -j$(nproc) PLAT=imx8mp bl31
cp build/imx8mp/release/bl31.bin $ROOTDIR/build/imx-mkimage/iMX8M/

# Build u-boot
echo "*** Building u-boot"
cd $ROOTDIR/build/uboot-imx/
make imx8mp_solidrun_defconfig
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

# Build linux
echo "*** Building Linux kernel"
cd $ROOTDIR/build/linux-imx
make imx_v8_defconfig
./scripts/kconfig/merge_config.sh .config $ROOTDIR/configs/kernel.extra
make -j$(nproc) Image dtbs
if [ "x${INCLUDE_KERNEL_MODULES}" = "xtrue" ]; then
	make -j$(nproc) modules
	rm -rf ${ROOTDIR}/images/tmp/modules
	make -j$(nproc) INSTALL_MOD_PATH="${ROOTDIR}/images/tmp/modules" modules_install
fi

# Bring bootlader all together
echo "*** Creating boot loader image"
unset ARCH CROSS_COMPILE
cd $ROOTDIR/build/imx-mkimage
make clean
make SOC=iMX8MP dtbs=imx8mp-solidrun.dtb flash_evk
mkdir -p $ROOTDIR/images
cp -v iMX8M/flash.bin $ROOTDIR/images/u-boot-${UBOOT_ENVIRONMENT}-${REPO_PREFIX}.bin

# Create disk images
echo "*** Creating disk images"
cd $ROOTDIR/images
dd if=/dev/zero of=tmp/part1.fat32 bs=1M count=148
env PATH="$PATH:/sbin:/usr/sbin" mkdosfs tmp/part1.fat32

# Prepare rootfs
echo "Preparing rootfs"
truncate -s 512M ${ROOTFS_IMG}
e2fsck -f -y ${ROOTFS_IMG}
resize2fs ${ROOTFS_IMG}

if [ "x${INCLUDE_KERNEL_MODULES}" = "xtrue" ]; then
	echo "copying kernel modules ..."
	find "${ROOTDIR}/images/tmp/modules/lib/modules" -type f -not -name "*.ko*" -printf "%P\n" | e2cp -G 0 -O 0 -P 644 -s "${ROOTDIR}/images/tmp/modules/lib/modules" -d "$ROOTFS_IMG:lib/modules" -a
	find "${ROOTDIR}/images/tmp/modules/lib/modules" -type f -name "*.ko*" -printf "%P\n" | e2cp -G 0 -O 0 -P 644 -s "${ROOTDIR}/images/tmp/modules/lib/modules" -d "$ROOTFS_IMG:lib/modules" -a
fi

e2fsck -f -y ${ROOTFS_IMG}

IMG=microsd-${REPO_PREFIX}.img

IMAGE_BOOTPART_SIZE_MB=150 # bootpart size = 150MiB
IMAGE_BOOTPART_SIZE=$((IMAGE_BOOTPART_SIZE_MB*1024*1024)) # Convert megabytes to bytes 
IMAGE_ROOTPART_SIZE=`stat -c "%s" tmp/rootfs.ext4`
IMAGE_ROOTPART_SIZE_MB=$(($IMAGE_ROOTPART_SIZE / (1024 * 1024) )) # Convert bytes to megabytes
IMAGE_SIZE=$((IMAGE_BOOTPART_SIZE+IMAGE_ROOTPART_SIZE+2*1024*1024))  # additional 2M at the end
IMAGE_SIZE_MB=$(echo "$IMAGE_SIZE / (1024 * 1024)" | bc) # Convert bytes to megabytes
dd if=/dev/zero of=${IMG} bs=1M count=${IMAGE_SIZE_MB}

echo 'label linux' > $ROOTDIR/images/extlinux.conf
echo '        KERNEL ../Image' >> $ROOTDIR/images/extlinux.conf
echo '        FDTDIR ../' >> $ROOTDIR/images/extlinux.conf
echo '        APPEND ${bootargs} root=${mmcroot} rootwait rw console=${console}' >> $ROOTDIR/images/extlinux.conf

mmd -i tmp/part1.fat32 ::/extlinux
mcopy -i tmp/part1.fat32 $ROOTDIR/images/extlinux.conf ::/extlinux/extlinux.conf
mcopy -i tmp/part1.fat32 $ROOTDIR/build/linux-imx/arch/arm64/boot/Image ::/Image
mcopy -s -i tmp/part1.fat32 $ROOTDIR/build/linux-imx/arch/arm64/boot/dts/freescale/*imx8mp*.dtb ::/
mcopy -s -i tmp/part1.fat32 $ROOTDIR/build/buildroot/output/images/rootfs.cpio.uboot ::/

dd if=$ROOTDIR/build/imx-mkimage/iMX8M/flash.bin of=${IMG} bs=1K seek=32 conv=notrunc
env PATH="$PATH:/sbin:/usr/sbin" parted --script ${IMG} mklabel msdos mkpart primary 2MiB ${IMAGE_BOOTPART_SIZE_MB}MiB mkpart primary ${IMAGE_BOOTPART_SIZE_MB}MiB $((IMAGE_SIZE_MB - 1))MiB
dd if=tmp/part1.fat32 of=${IMG} bs=1M seek=2 conv=notrunc
dd if=${ROOTFS_IMG} of=${IMG} bs=1M seek=${IMAGE_BOOTPART_SIZE_MB} conv=notrunc
echo -e "\n\n*** Image is ready - images/${IMG}"