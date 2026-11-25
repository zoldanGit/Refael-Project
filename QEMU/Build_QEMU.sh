#!/usr/bin/env bash
# Build Linux 6.18 + Buildroot rootfs and boot it on QEMU vexpress-a15.
# Tested layout for Debian/Ubuntu hosts. Usage:  ./build-arm-qemu.sh [build|run]
set -euo pipefail

WORK="${WORK:-$PWD/arm-qemu}"
KVER="6.18"
BRVER="2025.08"
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
JOBS="$(nproc)"

deps() {
  sudo apt-get update
  sudo apt-get install -y build-essential gcc-arm-linux-gnueabihf bc bison flex \
    libssl-dev libncurses-dev libelf-dev xz-utils wget cpio unzip rsync file \
    qemu-system-arm
}

kernel() {
  mkdir -p "$WORK" && cd "$WORK"
  [ -f linux-$KVER.tar.xz ] || wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz
  [ -d linux-$KVER ] || tar xf linux-$KVER.tar.xz
  cd linux-$KVER
  make vexpress_defconfig
  # make sure what we need to boot from the emulated SD card is built in
  scripts/config -e EXT4_FS -e DEVTMPFS -e DEVTMPFS_MOUNT \
                 -e MMC -e MMC_ARMMMCI -e BLK_DEV_SD \
                 -e SERIAL_AMBA_PL011 -e SERIAL_AMBA_PL011_CONSOLE
  make olddefconfig
  make -j"$JOBS" zImage dtbs
  cp arch/arm/boot/zImage "$WORK/zImage"
  cp "$(find arch/arm/boot/dts -name vexpress-v2p-ca15-tc1.dtb | head -n1)" "$WORK/vexpress-v2p-ca15-tc1.dtb"
}

rootfs() {
  cd "$WORK"
  [ -f buildroot-$BRVER.tar.gz ] || wget https://buildroot.org/downloads/buildroot-$BRVER.tar.gz
  [ -d buildroot-$BRVER ] || tar xf buildroot-$BRVER.tar.gz
  cd buildroot-$BRVER
  # Buildroot unsets these itself; don't leak kernel cross vars into it
  unset ARCH CROSS_COMPILE
  make qemu_arm_vexpress_defconfig
  # We build our own kernel, so drop Buildroot's kernel and post-image script
  cat >> .config <<'EOF'
# BR2_LINUX_KERNEL is not set
BR2_ROOTFS_POST_IMAGE_SCRIPT=""
BR2_TARGET_ROOTFS_EXT2=y
BR2_TARGET_ROOTFS_EXT2_4=y
BR2_TARGET_ROOTFS_EXT2_SIZE="128M"
EOF
  make olddefconfig
  make -j"$JOBS"
  cp output/images/rootfs.ext2 "$WORK/rootfs.ext2"
}

run() {
  cd "$WORK"
  qemu-system-arm \
    -M vexpress-a15 -cpu cortex-a15 -m 512 -nographic \
    -kernel zImage \
    -dtb vexpress-v2p-ca15-tc1.dtb \
    -drive file=rootfs.ext2,if=sd,format=raw \
    -append "root=/dev/mmcblk0 rw console=ttyAMA0" \
    -nic user
}

case "${1:-build}" in
  build) deps; kernel; rootfs; echo "Done. Run: $0 run" ;;
  run)   run ;;
  *)     echo "usage: $0 [build|run]"; exit 1 ;;
esac
