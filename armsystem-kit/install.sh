#!/bin/bash
# armsystem kit installer for a fresh Debian 13 (trixie) arm64 machine.
#
#   ./install.sh [--prefix DIR] [--assets FILE.tar.xz] [--no-root-steps]
#
#   --prefix DIR       install here instead of ~/armsystem
#   --assets FILE      assets bundle (default: armsystem-assets-*.tar.xz next to
#                      this script); SHA256SUMS must sit beside it
#   --no-root-steps    do everything that needs no sudo and list what was skipped
#
# Run as your normal user, NOT with sudo. The script calls sudo itself for the
# two steps that need it (apt packages, unpacking the NFS root) and says why.
# Your user must be in group sudo; this is checked before anything is changed.
# Re-running is safe: finished steps are detected and skipped.
set -euo pipefail

KIT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PREFIX="$HOME/armsystem"
ASSETS=""
ROOT_STEPS=1
MARKER=".armsystem-kit"
NEED_MB=1100   # measured: 641 MB assets + 47 MB NFS root, plus headroom

# The one explicit package list. Keep README.md in sync when changing it.
APT_PACKAGES=(
  qemu-system-arm            # the emulator (vexpress-a15)
  nfs-kernel-server          # NFS root for the guest (pulls in rpcbind)
  iproute2 iputils-ping      # tap0 setup, connectivity checks
  socat picocom              # UART0 bridge (setupuart) and a serial terminal
  gdb-multiarch              # host side of gdbserver debugging
  python3 python3-serial     # verify.sh, UART labs, SDK relocation
  gcc-arm-linux-gnueabihf    # compiler for the kernel and kernel modules
  build-essential bc bison flex libssl-dev libncurses-dev   # kernel build host tools
  cpio xz-utils kmod rsync file   # archives, modinfo, kernel 'make' helpers
  curl ca-certificates       # get-kernel-source.sh download
  libncursesw6               # needed by the SDK's arm-linux-gdb
)
# Units that Debian enables and starts when nfs-kernel-server is installed.
NFS_UNITS=(nfs-server.service rpcbind.service rpcbind.socket)

say()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# Succeeds if the user (looked up in the group database) is in group sudo.
in_sudo_group() {
  local g
  for g in $(id -nG -- "$1" 2>/dev/null); do
    [ "$g" = sudo ] && return 0
  done
  return 1
}

# Preflight for the sudo steps. Runs before anything is installed or changed.
# The fix uses full paths: 'su -c' gives root a PATH without /usr/sbin.
preflight_sudo() {
  local user
  user=$(id -un)
  in_sudo_group "$user" && return 0
  die "user '$user' is not allowed to use sudo (not a member of group 'sudo').
Nothing was installed or changed.

To fix it, run this one command (it asks for the ROOT password, then reboots):

  su -c '/usr/sbin/usermod -aG sudo $user && /usr/sbin/reboot'

After the reboot, log in again as '$user' and re-run ./install.sh
(To install only the parts that need no sudo: ./install.sh --no-root-steps)"
}

# Prints the listening sockets on ports 111 (rpcbind) and 2049 (NFS), if any.
open_nfs_ports() {
  ss -H -tuln | awk '{print $1, $5}' | grep -E ':(111|2049)$' || true
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX=$2; shift 2 ;;
    --prefix=*) PREFIX=${1#*=}; shift ;;
    --assets) [ $# -ge 2 ] || die "--assets needs a file"; ASSETS=$2; shift 2 ;;
    --assets=*) ASSETS=${1#*=}; shift ;;
    --no-root-steps) ROOT_STEPS=0; shift ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- 1. checks
say "1/8 Checking this machine"
[ "$EUID" -ne 0 ] || die "run as your normal user, not root/sudo (QEMU and the files must belong to you)."
[ -r /etc/os-release ] || die "/etc/os-release not found; this is not Debian 13."
# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID:-}" != debian ] || [ "${VERSION_ID:-}" != 13 ]; then
  die "needs Debian 13 (trixie); found ${PRETTY_NAME:-unknown}."
fi
ARCH=$(dpkg --print-architecture)
[ "$ARCH" = arm64 ] || die "needs arm64; found $ARCH. The SDK binaries are arm64-only."
info "Debian $VERSION_ID, $ARCH: OK"
if [ "$ROOT_STEPS" -eq 1 ]; then
  preflight_sudo
  info "user $(id -un) is in group sudo: OK"
fi

case "$PREFIX" in /*) ;; *) PREFIX="$PWD/$PREFIX" ;; esac
case "$PREFIX" in
  *[[:space:]:]*) die "prefix may not contain spaces or colons (SDK limitation): $PREFIX" ;;
esac
if [ -e "$PREFIX" ] && [ ! -f "$PREFIX/$MARKER" ]; then
  die "$PREFIX already exists and was not created by this kit; refusing to touch it.
Move it away or choose another place with --prefix."
fi

if [ -z "$ASSETS" ]; then
  shopt -s nullglob
  found=("$KIT_DIR"/armsystem-assets-*.tar.xz)
  shopt -u nullglob
  [ ${#found[@]} -eq 1 ] || die "expected exactly one armsystem-assets-*.tar.xz in $KIT_DIR (found ${#found[@]}); use --assets."
  ASSETS=${found[0]}
fi
[ -f "$ASSETS" ] || die "assets bundle not found: $ASSETS"
ASSETS=$(readlink -f -- "$ASSETS")
SUMS="$(dirname -- "$ASSETS")/SHA256SUMS"
[ -f "$SUMS" ] || die "SHA256SUMS not found next to $ASSETS"
info "prefix: $PREFIX"
info "assets: $ASSETS"

# ---------------------------------------------------------------- 2. apt
say "2/8 Debian packages"
missing=()
for p in "${APT_PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
done
SKIPPED=()
if [ ${#missing[@]} -eq 0 ]; then
  info "all ${#APT_PACKAGES[@]} packages already installed; nothing to do."
elif [ "$ROOT_STEPS" -eq 0 ]; then
  info "SKIPPED (--no-root-steps). Missing: ${missing[*]}"
  SKIPPED+=("apt-get install ${missing[*]}")
else
  nfs_was_installed=0
  dpkg-query -W -f='${Status}' nfs-kernel-server 2>/dev/null | grep -q 'install ok installed' && nfs_was_installed=1
  info "sudo is needed here: installing system packages is a root-only operation."
  info "Installing: ${missing[*]}"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  if [ "$nfs_was_installed" -eq 0 ]; then
    info "sudo is needed here: Debian enables and starts the NFS server as soon as it is"
    info "installed. The lab must not leave NFS running or enabled at boot, so it is"
    info "stopped and disabled now; lab-up.sh starts it only while you work."
    sudo systemctl disable --now "${NFS_UNITS[@]}"
    # Again, explicitly and socket first: while rpcbind.socket is active, systemd
    # keeps port 111 open and restarts rpcbind on demand. Not fatal if it fails;
    # the port check at the end of the install reports what is still open.
    sudo systemctl disable --now rpcbind.socket rpcbind.service nfs-server.service \
      || info "WARNING: could not stop/disable rpcbind and nfs-server; see the port check at the end."
  else
    info "nfs-kernel-server was already installed before this run; its boot-time"
    info "enablement was NOT changed. Check with: systemctl is-enabled ${NFS_UNITS[*]}"
  fi
fi

# ---------------------------------------------------------------- 3. checksum
say "3/8 Verifying the assets bundle"
( cd -- "$(dirname -- "$ASSETS")" \
  && grep -F -- "  $(basename -- "$ASSETS")" SHA256SUMS | sha256sum -c - ) \
  || die "checksum mismatch (or no entry in SHA256SUMS) for $ASSETS; not unpacking."

# ---------------------------------------------------------------- 4. unpack
say "4/8 Unpacking into $PREFIX"
if [ ! -f "$PREFIX/$MARKER" ]; then
  # free space is checked on the nearest directory that already exists
  probe=$(dirname -- "$PREFIX")
  while [ ! -d "$probe" ]; do probe=$(dirname -- "$probe"); done
  avail_mb=$(df -Pm -- "$probe" | awk 'NR==2 {print $4}')
  [ "$avail_mb" -ge "$NEED_MB" ] || die "need about ${NEED_MB} MB free under $probe, only ${avail_mb} MB available."
  mkdir -p -- "$PREFIX"
  echo "created by armsystem-kit install.sh" > "$PREFIX/$MARKER"
fi
if [ -f "$PREFIX/VERSION" ] && [ -x "$PREFIX/toolchain/bin/arm-linux-gcc" ]; then
  info "assets $(cat "$PREFIX/VERSION") already unpacked; skipping."
else
  stage="$PREFIX/.unpack.$$"
  mkdir -- "$stage"
  trap 'rm -rf -- "$stage"' EXIT
  tar -xJf "$ASSETS" -C "$stage" --strip-components=1
  ( cd -- "$stage" && sha256sum --quiet -c MANIFEST.sha256 ) \
    || die "unpacked files do not match MANIFEST.sha256."
  for item in images kernel toolchain licenses relocate-sdk.py PROVENANCE.md MANIFEST.sha256 VERSION; do
    [ -e "$PREFIX/$item" ] && die "$PREFIX/$item exists from an interrupted run; move $PREFIX away and re-run."
    mv -- "$stage/$item" "$PREFIX/$item"
  done
  rm -rf -- "$stage"
  trap - EXIT
  info "unpacked assets $(cat "$PREFIX/VERSION")"
fi

# ---------------------------------------------------------------- 5. SDK
say "5/8 Relocating the SDK to its new path"
if command -v python3 >/dev/null; then
  python3 -B "$PREFIX/relocate-sdk.py" "$PREFIX/toolchain"
  info "SDK prefix: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prefix"])' "$PREFIX/toolchain/sdk-location.json")"
else
  info "SKIPPED: python3 is not installed yet."
  SKIPPED+=("python3 -B $PREFIX/relocate-sdk.py $PREFIX/toolchain")
fi

# ---------------------------------------------------------------- 6. scripts
say "6/8 Installing the lab scripts"
for f in run_qemu setupuart env.sh lab-up.sh lab-down.sh start_qemu_lab.sh verify.sh get-kernel-source.sh README.md; do
  install -m "$([ "${f##*.}" = md ] && echo 644 || echo 755)" -- "$KIT_DIR/$f" "$PREFIX/$f"
done
chmod 644 -- "$PREFIX/env.sh"
mkdir -p -- "$PREFIX/lib" "$PREFIX/examples/module"
install -m 755 -- "$KIT_DIR/lib/guest.py" "$KIT_DIR/lib/verify.py" "$PREFIX/lib/"
install -m 644 -- "$KIT_DIR/examples/hello.c" "$PREFIX/examples/"
install -m 644 -- "$KIT_DIR/examples/module/hello_mod.c" "$KIT_DIR/examples/module/Makefile" "$PREFIX/examples/module/"
info "run_qemu, setupuart, env.sh, lab-up.sh, lab-down.sh, start_qemu_lab.sh, verify.sh, get-kernel-source.sh"

# ---------------------------------------------------------------- 7. NFS root
say "7/8 NFS root filesystem ($PREFIX/outfs2)"
if [ -e "$PREFIX/outfs2/bin/busybox" ]; then
  info "already unpacked; skipping."
elif [ "$ROOT_STEPS" -eq 0 ]; then
  info "SKIPPED (--no-root-steps)."
  SKIPPED+=("unpack images/rootfs.cpio into $PREFIX/outfs2 as root, create outfs2/work")
else
  info "sudo is needed here: the root filesystem contains device nodes and files owned"
  info "by root (uid 0). Only root can create those, and the guest needs them intact."
  [ -z "$(ls -A -- "$PREFIX/outfs2" 2>/dev/null)" ] || die "$PREFIX/outfs2 exists but is incomplete; move it away and re-run."
  sudo mkdir -p -- "$PREFIX/outfs2"
  sudo sh -c 'cd -- "$1" && cpio -idm --no-absolute-filenames --quiet < "$2"' sh "$PREFIX/outfs2" "$PREFIX/images/rootfs.cpio"
  info "sudo is needed here: /work inside the NFS root is handed to you ($(id -un)) so you"
  info "can copy programs to the guest without sudo. The guest sees it as /work."
  sudo mkdir -p -- "$PREFIX/outfs2/work"
  sudo chown "$(id -u):$(id -g)" -- "$PREFIX/outfs2/work"
fi

# ---------------------------------------------------------------- 8. self-test
say "8/8 Self-test: cross-compiling examples/hello.c with the SDK"
if [ ${#SKIPPED[@]} -gt 0 ] && ! command -v python3 >/dev/null; then
  info "SKIPPED: SDK not relocated."
else
  t=$(mktemp -d)
  "$PREFIX/toolchain/bin/arm-linux-gcc" -o "$t/hello" "$PREFIX/examples/hello.c" \
    || die "the SDK compiler failed; the installation is not usable."
  if command -v file >/dev/null; then info "$(file -b "$t/hello" | cut -d, -f1-5)"; fi
  rm -rf -- "$t"
  info "SDK compiler works."
fi

# ---------------------------------------------------------------- port check
say "Checking that the NFS ports (111, 2049) are closed"
PORTS_OPEN=0
if ! command -v ss >/dev/null; then
  info "SKIPPED: 'ss' (package iproute2) is not installed yet; could not check."
else
  open=$(open_nfs_ports)
  if [ -z "$open" ]; then
    info "OK: ports 111 and 2049 are closed."
  else
    PORTS_OPEN=1
    {
      echo
      echo '  ************************************************************'
      echo '  WARNING: NFS/rpcbind ports are OPEN on this machine:'
      printf '%s\n' "$open" | sed 's/^/      /'
      echo '  The lab must not leave them open. If the lab is up right now'
      echo '  (you ran ./lab-up.sh), this is expected: run ./lab-down.sh when'
      echo '  you finish. Otherwise close them with:'
      echo '    sudo systemctl disable --now rpcbind.socket rpcbind.service nfs-server.service'
      echo "  and check again with:  ss -tuln | grep -E ':(111|2049) '"
      echo '  ************************************************************'
    } >&2
  fi
fi

if [ "$PORTS_OPEN" -eq 1 ]; then say "Done, with a WARNING (see above: ports 111/2049 are open)."; else say "Done."; fi
if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "Steps that were skipped and still have to be done:"
  for s in "${SKIPPED[@]}"; do echo "  - $s"; done
  echo "Re-run ./install.sh without --no-root-steps to complete them."
else
  cat <<EOF
Next steps:
  cd $PREFIX
  ./lab-up.sh        # tap0 + NFS (asks for sudo)
  ./verify.sh        # acceptance test
  ./run_qemu         # boot the guest; log in as root (no password)
  ./lab-down.sh      # when you finish for the day

Daily use, one command (brings the lab up, boots the guest, shuts it down on poweroff):
  ./start_qemu_lab.sh
EOF
fi
