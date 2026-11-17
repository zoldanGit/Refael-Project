#!/bin/bash
# Non-interactive acceptance test. Prints PASS/FAIL per item; exit status 0 = all passed.
#
#   ./verify.sh              full test: NFS root over tap0 (uses sudo via lab-up.sh
#                            if the lab is not already up, and lab-down.sh afterwards)
#   ./verify.sh --initramfs  no sudo at all: boots from RAM with QEMU user networking;
#                            the NFS and host->guest ping items are reported as SKIP
#   --keep-logs              keep the scratch directory (console and gdb logs)
#
# Items: boot to shell, ping both ways, cross-compiled dynamic hello runs,
# UART0 echo through socat + pyserial, gdbserver + gdb-multiarch breakpoint.
# Cleans up after itself: QEMU, socat, test files, and the lab network if it started it.
set -uo pipefail
A=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
MODE=nfs
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --initramfs) MODE=initramfs ;;
    --keep-logs) KEEP=1 ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "verify.sh: unknown option: $arg" >&2; exit 2 ;;
  esac
done
[ "$EUID" -ne 0 ] || { echo 'Run as your normal user.' >&2; exit 2; }

missing=""
for tool in qemu-system-arm python3 socat gdb-multiarch cpio file ping; do
  command -v "$tool" >/dev/null || missing="$missing $tool"
done
python3 -c 'import serial' 2>/dev/null || missing="$missing python3-serial"
[ -x "$A/toolchain/bin/arm-linux-gcc" ] || missing="$missing toolchain(SDK)"
if [ -n "$missing" ]; then
  echo "FAIL  prerequisites                      missing:$missing (run install.sh)"
  exit 1
fi
if ss -H -tln 2>/dev/null | awk '{print $4}' | grep -q ':2345$'; then
  echo 'FAIL  prerequisites                      TCP port 2345 is already in use on this host'
  exit 1
fi

TMP=$(mktemp -d /tmp/armsystem-verify.XXXXXX)
SHARE=""
STARTED_LAB=0
# shellcheck disable=SC2317  # called from the EXIT trap
cleanup() {
  # QEMU and socat are stopped by verify.py; this is the safety net.
  pkill -f "unix:$TMP/qemu-uart" 2>/dev/null
  pkill -f "UNIX-CONNECT:$TMP/qemu-uart" 2>/dev/null
  [ -n "$SHARE" ] && rm -rf -- "$SHARE"
  if [ "$STARTED_LAB" -eq 1 ]; then
    echo '--- stopping the lab network that verify.sh started'
    "$A/lab-down.sh" || echo 'FAIL  cleanup                            lab-down.sh reported a problem'
  fi
  if [ "$KEEP" -eq 1 ]; then echo "logs kept in $TMP"; else rm -rf -- "$TMP"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "armsystem verify: mode=$MODE, assets $(cat "$A/VERSION" 2>/dev/null || echo '?'), $(date '+%F %T')"
ARGS=(--prefix "$A" --mode "$MODE" --tmp "$TMP")
if [ "$MODE" = nfs ]; then
  if [ ! -e "$A/outfs2/bin/busybox" ]; then
    echo "FAIL  prerequisites                      NFS root $A/outfs2 not unpacked (run install.sh)"
    exit 1
  fi
  if ! ip link show tap0 >/dev/null 2>&1 || ! ss -H -tln | awk '{print $4}' | grep -q ':2049$'; then
    echo '--- the lab network is down; starting it with lab-up.sh (sudo)'
    STARTED_LAB=1
    "$A/lab-up.sh" || { echo 'FAIL  prerequisites                      lab-up.sh failed'; exit 1; }
  fi
  if pgrep -f 'qemu-system-arm.*ifname=tap0' >/dev/null; then
    echo 'FAIL  prerequisites                      a guest is already running on tap0; power it off first'
    exit 1
  fi
  SHARE=$(mktemp -d "$A/outfs2/work/verify.XXXXXX") || { echo "FAIL  prerequisites                      cannot write to $A/outfs2/work"; exit 1; }
  chmod 755 "$SHARE"
  ARGS+=(--share "$SHARE" --guest-share "/work/$(basename "$SHARE")")
fi

python3 -B "$A/lib/verify.py" "${ARGS[@]}"
exit $?
