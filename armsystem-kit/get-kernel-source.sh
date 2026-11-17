#!/bin/bash
# Download linux-6.18.50 from kernel.org, verify it, unpack it, and prepare an
# out-of-tree build directory with the kit's kernel config. No sudo.
#
#   ./get-kernel-source.sh [--dest DIR] [--tarball FILE]
#
#   --dest DIR      where to put it (default: <armsystem>/kernel)
#   --tarball FILE  use an already downloaded linux-6.18.50.tar.xz (still verified)
#
# Result:  DIR/linux-6.18.50        pristine source (about 1.6 GB)
#          DIR/build-6.18.50        build directory with .config (about 1.3 GB after a build)
set -euo pipefail
A=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
VER=6.18.50
URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VER.tar.xz"
# Same value as in https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc
SHA256=d2fc041dab4e11d9645e3ba53be058faa52b8ce28a8a97c889bb2cacee170461
DEST="$A/kernel"
TARBALL=""
CONFIG="$A/kernel/config-$VER"
NEED_MB=3200   # 1.6 GB source + 1.3 GB build + tarball

die() { printf 'get-kernel-source.sh: %s\n' "$*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) [ $# -ge 2 ] || die "--dest needs a directory"; DEST=$2; shift 2 ;;
    --tarball) [ $# -ge 2 ] || die "--tarball needs a file"; TARBALL=$2; shift 2 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -f "$CONFIG" ] || die "kernel config not found: $CONFIG (run from an installed armsystem directory)"
command -v arm-linux-gnueabihf-gcc >/dev/null || die "arm-linux-gnueabihf-gcc not found; run install.sh (package gcc-arm-linux-gnueabihf)."
mkdir -p -- "$DEST"
DEST=$(cd -- "$DEST" && pwd -P)
SRC="$DEST/linux-$VER"
BUILD="$DEST/build-$VER"

if [ ! -d "$SRC" ]; then
  avail_mb=$(df -Pm -- "$DEST" | awk 'NR==2 {print $4}')
  [ "$avail_mb" -ge "$NEED_MB" ] || die "need about $NEED_MB MB free in $DEST, only $avail_mb MB available."
  if [ -z "$TARBALL" ]; then
    TARBALL="$DEST/linux-$VER.tar.xz"
    if [ ! -f "$TARBALL" ]; then
      echo "==> downloading $URL"
      curl -fL --retry 3 -o "$TARBALL.part" "$URL"
      mv -- "$TARBALL.part" "$TARBALL"
    fi
  fi
  echo "==> verifying sha256 of $TARBALL"
  echo "$SHA256  $TARBALL" | sha256sum -c - || die "checksum mismatch; delete $TARBALL and try again."
  echo "==> unpacking to $SRC"
  tmp="$DEST/.unpack.$$"
  mkdir -- "$tmp"
  trap 'rm -rf -- "$tmp"' EXIT
  tar -xJf "$TARBALL" -C "$tmp"
  mv -- "$tmp/linux-$VER" "$SRC"
  rmdir -- "$tmp"
  trap - EXIT
else
  echo "==> $SRC already exists; not touching it."
fi

if [ ! -f "$BUILD/.config" ]; then
  echo "==> preparing $BUILD with the kit's kernel config"
  mkdir -p -- "$BUILD"
  cp -- "$CONFIG" "$BUILD/.config"
  make -C "$SRC" O="$BUILD" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- olddefconfig
else
  echo "==> $BUILD/.config already exists; not touching it."
fi

cat <<EOT

Ready. Build the kernel with (about 2-3 minutes with -j4):
  make -C $SRC O=$BUILD ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j4 zImage modules
Boot it with:
  KERNEL=$BUILD/arch/arm/boot/zImage $A/run_qemu
EOT
