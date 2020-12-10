#!/bin/bash
set -e

### General setup
NXP_REL=rel_imx_5.4.47_2.2.0
UBOOT_NXP_REL=imx_v2020.04_5.4.47_2.2.0
#rel_imx_5.4.24_2.1.0
#imx_v2020.04_5.4.24_2.1.0
BUILDROOT_VERSION=2020.02
###
SHALLOW=${SHALLOW:false}
if [ "x$SHALLOW" == "xtrue" ]; then
        SHALLOW_FLAG="--depth 1"
fi

REPO_PREFIX=`git log -1 --pretty=format:%h`

export ARCH=arm64
ROOTDIR=`pwd`

COMPONENTS="imx-atf uboot-imx linux-imx imx-mkimage"
mkdir -p build
for i in $COMPONENTS; do
	if [[ ! -d $ROOTDIR/build/$i ]]; then
		cd $ROOTDIR/build/
		if [ "x$i" == "xuboot-imx" ]; then
			CHECKOUT=$UBOOT_NXP_REL
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


if [[ ! -d $ROOTDIR/build/firmware ]]; then
	cd $ROOTDIR/build/
	mkdir -p firmware
	cd firmware
	wget https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/firmware-imx-8.7.bin
	bash firmware-imx-8.7.bin --auto-accept
	cp -v $(find . | awk '/train|hdmi_imx8|dp_imx8/' ORS=" ") ${ROOTDIR}/build/imx-mkimage/iMX8M/
fi

if [[ ! -d $ROOTDIR/build/buildroot ]]; then
	cd $ROOTDIR/build
	git clone ${SHALLOW_FLAG} https://github.com/buildroot/buildroot -b $BUILDROOT_VERSION
fi

# Build buildroot
echo "*** Building buildroot"
cd $ROOTDIR/build/buildroot
cp $ROOTDIR/configs/buildroot_defconfig configs/imx8mp_hummingboard_pulse_defconfig
make imx8mp_hummingboard_pulse_defconfig
make

export CROSS_COMPILE=$ROOTDIR/build/buildroot/output/host/bin/aarch64-linux-

# Build ATF
echo "*** Building ATF"
cd $ROOTDIR/build/imx-atf
make -j32 PLAT=imx8mp bl31
cp build/imx8mp/release/bl31.bin $ROOTDIR/build/imx-mkimage/iMX8M/

# Build u-boot
echo "*** Building u-boot"
cd $ROOTDIR/build/uboot-imx/
make imx8mp_solidrun_defconfig
make -j 32
set +e
cp -v $(find . | awk '/u-boot-spl.bin$|u-boot.bin$|u-boot-nodtb.bin$|.*\.dtb$|mkimage$/' ORS=" ") ${ROOTDIR}/build/imx-mkimage/iMX8M/
cp tools/mkimage ${ROOTDIR}/build//imx-mkimage/iMX8M/mkimage_uboot
set -e

# Build linux
echo "*** Building Linux kernel"
cd $ROOTDIR/build/linux-imx
make imx_v8_defconfig
./scripts/kconfig/merge_config.sh .config $ROOTDIR/configs/kernel.extra
make -j32 Image dtbs

# Bring bootlader all together
echo "*** Creating boot loader image"
unset ARCH CROSS_COMPILE
cd $ROOTDIR/build/imx-mkimage/iMX8M
sed "s/\(^dtbs = \).*/\1imx8mp-solidrun.dtb/;s/\(mkimage\)_uboot/\1/" soc.mak > Makefile
make clean
make flash_evk SOC=iMX8MP

# Create disk images
echo "*** Creating disk images"
mkdir -p $ROOTDIR/images/tmp/
cd $ROOTDIR/images
dd if=/dev/zero of=tmp/part1.fat32 bs=1M count=148
env PATH="$PATH:/sbin:/usr/sbin" mkdosfs tmp/part1.fat32

IMG=microsd-${REPO_PREFIX}.img

echo "label linux" > $ROOTDIR/images/extlinux.conf
echo "        linux ../Image" >> $ROOTDIR/images/extlinux.conf
echo "        fdt ../imx8mp-hummingboard-pulse.dtb" >> $ROOTDIR/images/extlinux.conf
echo "        initrd ../rootfs.cpio.uboot" >> $ROOTDIR/images/extlinux.conf
#echo "        append root=/dev/mmcblk1p2 rootwait" >> $ROOTDIR/images/extlinux.conf
mmd -i tmp/part1.fat32 ::/extlinux
mcopy -i tmp/part1.fat32 $ROOTDIR/images/extlinux.conf ::/extlinux/extlinux.conf
mcopy -i tmp/part1.fat32 $ROOTDIR/build/linux-imx/arch/arm64/boot/Image ::/Image
mcopy -s -i tmp/part1.fat32 $ROOTDIR/build/linux-imx/arch/arm64/boot/dts/freescale/*imx8mp*.dtb ::/
mcopy -s -i tmp/part1.fat32 $ROOTDIR/build/buildroot/output/images/rootfs.cpio.uboot ::/
dd if=/dev/zero of=${IMG} bs=1M count=301
dd if=$ROOTDIR/build/imx-mkimage/iMX8M/flash.bin of=${IMG} bs=1K seek=32 conv=notrunc
env PATH="$PATH:/sbin:/usr/sbin" parted --script ${IMG} mklabel msdos mkpart primary 2MiB 150MiB mkpart primary 150MiB 300MiB
dd if=tmp/part1.fat32 of=${IMG} bs=1M seek=2 conv=notrunc
dd if=$ROOTDIR/build/buildroot/output/images/rootfs.ext2 of=${IMG} bs=1M seek=150 conv=notrunc
echo -e "\n\n*** Image is ready - images/${IMG}"
