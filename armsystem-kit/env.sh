# Source this file:  . ~/armsystem/env.sh
#
# The compiler rule of this kit (see README.md):
#   user programs      -> arm-linux-gcc            (the SDK in toolchain/)
#   kernel and modules -> arm-linux-gnueabihf-gcc  (Debian package), via 'kmake'
ARMSYSTEM=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
export ARMSYSTEM
export ARMSYSTEM_KDIR="$ARMSYSTEM/kernel/build"
case ":$PATH:" in
  *":$ARMSYSTEM/toolchain/bin:"*) ;;
  # appended, not prepended: the SDK also carries host tools that must not shadow Debian's
  *) PATH="$PATH:$ARMSYSTEM/toolchain/bin" ;;
esac
export PATH

# kmake: 'make' for anything that is kernel code.
#   module:  kmake -C "$ARMSYSTEM_KDIR" M="$PWD" modules
#   kernel:  kmake -C ~/armsystem/kernel/linux-6.18.50 O=~/armsystem/kernel/build-6.18.50 -j4 zImage
kmake() { make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- "$@"; }
