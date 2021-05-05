#!/bin/bash
set -e

### General setup
NXP_REL=rel_imx_5.4.70_2.3.0
LINUX_NXP_REL=rel_imx_5.4.47_2.2.0
UBOOT_NXP_REL=imx_v2020.04_5.4.70_2.3.0
FW_VERSION=firmware-imx-8.10
BUILDROOT_VERSION=2020.02
###
SHALLOW=${SHALLOW:false}
if [ "x$SHALLOW" == "xtrue" ]; then
        SHALLOW_FLAG="--depth 1"
fi

REPO_PREFIX=`git log -1 --pretty=format:%h`

ROOTDIR=`pwd`
export PATH=$ROOTDIR/build/toolchain/gcc-linaro-7.4.1-2019.02-x86_64_aarch64-linux-gnu/bin:$PATH
export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64

if [[ ! -d $ROOTDIR/build/toolchain ]]; then
	mkdir -p $ROOTDIR/build/toolchain
	cd $ROOTDIR/build/toolchain
	wget https://releases.linaro.org/components/toolchain/binaries/7.4-2019.02/aarch64-linux-gnu/gcc-linaro-7.4.1-2019.02-x86_64_aarch64-linux-gnu.tar.xz
	tar -xvf gcc-linaro-7.4.1-2019.02-x86_64_aarch64-linux-gnu.tar.xz
fi

echo "** Download Source and Firmware **"
COMPONENTS="imx-atf uboot-imx linux-imx"
mkdir -p build
for i in $COMPONENTS; do
	if [[ ! -d $ROOTDIR/build/$i ]]; then
		cd $ROOTDIR/build/
		if [ "x$i" == "xuboot-imx" ]; then
			CHECKOUT=$UBOOT_NXP_REL
		elif [ "x$i" == "xlinux-imx" ]; then
			CHECKOUT=$LINUX_NXP_REL
		else
			CHECKOUT=$NXP_REL
		fi
		git clone ${SHALLOW_FLAG} https://source.codeaurora.org/external/imx/$i -b $CHECKOUT
		cd $i
		if [[ -d $ROOTDIR/patches/$i/ ]]; then
			git am $ROOTDIR/patches/$i/*.patch
		fi
	fi
done

# Get the firmware
if [[ ! -d $ROOTDIR/build/firmware ]]; then
	cd $ROOTDIR/build/
	mkdir -p firmware
	cd firmware
	wget https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/${FW_VERSION}.bin
	bash ${FW_VERSION}.bin --auto-accept
	# cp -v $(find . | awk '/train|hdmi_imx8|dp_imx8/' ORS=" ") ${ROOTDIR}/build/uboot-imx/
	# Get the ddr firmware
	cp ${FW_VERSION}/firmware/ddr/synopsys/ddr4*.bin ${ROOTDIR}/build/uboot-imx/
fi

if [[ ! -d $ROOTDIR/build/buildroot ]]; then
        cd $ROOTDIR/build
        git clone ${SHALLOW_FLAG} https://github.com/buildroot/buildroot -b $BUILDROOT_VERSION
fi

# Build ATF
echo "** Building ATF **"
cd $ROOTDIR/build/imx-atf
make -j32 PLAT=imx8mn bl31
cp build/imx8mn/release/bl31.bin ${ROOTDIR}/build/uboot-imx/

# Build u-boot
echo "** Building u-boot **"
cd $ROOTDIR/build/uboot-imx/
export ATF_LOAD_ADDR=0x960000
make imx8mn_solidrun_defconfig
make flash.bin
echo "The boot loader image - ./build/uboot-imx/flash.bin "
echo "Burn the flash.bin to MicroSD card with offset 32KB"

mkdir -p ${ROOTDIR}/images/tmp/
cp ${ROOTDIR}/build/uboot-imx/flash.bin ${ROOTDIR}/images/tmp/

# Build buildroot
echo "** Building buildroot **"
cd $ROOTDIR/build/buildroot
cp $ROOTDIR/configs/buildroot_defconfig configs/imx8mn_compact_defconfig
make imx8mn_compact_defconfig
make

# Build linux
echo "** Building Linux kernel **"
cd $ROOTDIR/build/linux-imx
make imx_v8_defconfig
./scripts/kconfig/merge_config.sh .config $ROOTDIR/configs/kernel.extra
make -j32 Image dtbs

# Create disk images
echo "** Creating disk images **"
mkdir -p $ROOTDIR/images/tmp/
cd $ROOTDIR/images
dd if=/dev/zero of=tmp/part1.fat32 bs=1M count=148
env PATH="$PATH:/sbin:/usr/sbin" mkdosfs tmp/part1.fat32

IMG=microsd-${REPO_PREFIX}.img

echo "label linux" > $ROOTDIR/images/extlinux.conf
echo "        linux ../Image" >> $ROOTDIR/images/extlinux.conf
echo "        fdt ../imx8mn-compact.dtb" >> $ROOTDIR/images/extlinux.conf
echo "        initrd ../rootfs.cpio.uboot" >> $ROOTDIR/images/extlinux.conf
mmd -i tmp/part1.fat32 ::/extlinux
mmd -i tmp/part1.fat32 ::/boot
mcopy -i tmp/part1.fat32 $ROOTDIR/images/extlinux.conf ::/extlinux/extlinux.conf
mcopy -i tmp/part1.fat32 $ROOTDIR/build/linux-imx/arch/arm64/boot/Image ::/boot/Image
mcopy -s -i tmp/part1.fat32 $ROOTDIR/build/linux-imx/arch/arm64/boot/dts/freescale/imx8mn-compact.dtb ::/boot/imx8mn-compact.dtb
mcopy -s -i tmp/part1.fat32 $ROOTDIR/build/buildroot/output/images/rootfs.cpio.uboot ::/boot/rootfs.cpio
dd if=/dev/zero of=${IMG} bs=1M count=301
dd if=$ROOTDIR/build/uboot-imx/flash.bin of=${IMG} bs=1K seek=32 conv=notrunc
env PATH="$PATH:/sbin:/usr/sbin" parted --script ${IMG} mklabel msdos mkpart primary 2MiB 150MiB mkpart primary 150MiB 300MiB
dd if=tmp/part1.fat32 of=${IMG} bs=1M seek=2 conv=notrunc
dd if=$ROOTDIR/build/buildroot/output/images/rootfs.ext2 of=${IMG} bs=1M seek=150 conv=notrunc
echo -e "\n\n*** Image is ready - images/${IMG}"

