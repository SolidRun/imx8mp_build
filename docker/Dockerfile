# use debian base
FROM debian:bookworm-slim

# apt proxy (optional)
ARG APTPROXY=
RUN test -n "$APTPROXY" && printf 'Acquire::http { Proxy "%s"; }\n' $APTPROXY | tee -a /etc/apt/apt.conf.d/proxy || true

# update
RUN set -e; \
	apt-get update; \
	apt-get -y upgrade; \
	:

RUN set -e; \
	apt-get update; \
	apt-get -y install --no-install-recommends kmod libgnutls28-dev uuid-dev bc bison build-essential ca-certificates cmake cpio crossbuild-essential-armhf crossbuild-essential-arm64 device-tree-compiler dosfstools e2tools file flex fuseext2 git libbz2-dev libncurses-dev libssl-dev libusb-1.0-0-dev libzip-dev make meson mtools multistrap ninja-build p7zip p7zip-full pandoc parted pkg-config  python3 python3-pycryptodome python3-cryptography python3-pyelftools qemu-system-arm rsync squashfs-tools sudo tar u-boot-tools unzip wget xz-utils zlib1g-dev fakeroot debootstrap ; \
	:

# build environment
WORKDIR /work
COPY shflags /
COPY entry.sh /
ENTRYPOINT ["/bin/sh", "/entry.sh"]
