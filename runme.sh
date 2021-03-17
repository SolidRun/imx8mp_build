#!/bin/bash
set -e

### General setup
NXP_REL=rel_imx_5.4.70_2.3.0
UBOOT_NXP_REL=imx_v2020.04_5.4.70_2.3.0
FW_VERSION=firmware-imx-8.10
BUILDROOT_VERSION=2020.02
###
SHALLOW=${SHALLOW:false}
if [ "x$SHALLOW" == "xtrue" ]; then
        SHALLOW_FLAG="--depth 1"
fi

REPO_PREFIX=`git log -1 --pretty=format:%h`

export PATH=$ROOTDIR/build/toolchain/gcc-linaro-7.4.1-2019.02-x86_64_aarch64-linux-gnu/bin:$PATH
export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64
ROOTDIR=`pwd`

if [[ ! -d $ROOTDIR/build/toolchain ]]; then
	mkdir -p $ROOTDIR/build/toolchain
	cd $ROOTDIR/build/toolchain
	wget https://releases.linaro.org/components/toolchain/binaries/7.4-2019.02/aarch64-linux-gnu/gcc-linaro-7.4.1-2019.02-x86_64_aarch64-linux-gnu.tar.xz
	tar -xvf gcc-linaro-7.4.1-2019.02-x86_64_aarch64-linux-gnu.tar.xz
fi

echo "** Download Source and Firmware **"
COMPONENTS="imx-atf uboot-imx"
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
