#!/usr/bin/env bash
# UART practice between QEMU (vexpress-a15) and the Debian host.
# The guest's 2nd UART (/dev/ttyAMA1) is exposed on host TCP port 4555.
#
#   ./setup-uart.sh install   (once, on the host)
#   ./setup-uart.sh qemu      (tab 1: starts QEMU; log in as root there)
#   ./setup-uart.sh host      (tab 2: host side of the serial line)
#
# Inside QEMU (the '#' prompt) you then run:  /root/uart-test.sh
set -euo pipefail

WORK="${WORK:-$PWD/arm-qemu}"
NFSROOT=/srv/nfsroot
PORT=4555

install_all() {
  sudo apt-get update
  sudo apt-get install -y netcat-openbsd picocom

  # Helper that runs INSIDE the ARM guest
  sudo mkdir -p "$NFSROOT/root"
  sudo tee "$NFSROOT/root/uart-test.sh" >/dev/null <<'EOF'
#!/bin/sh
DEV=/dev/ttyAMA1
ls -l $DEV || { echo "no $DEV"; exit 1; }
stty -F $DEV 115200 raw -echo
echo "hello from arm" > $DEV
echo "Sent 'hello from arm'. Now type a line in the host tab and press Enter..."
read line < $DEV
echo "Got from host: $line"
EOF
  sudo chmod +x "$NFSROOT/root/uart-test.sh"
  echo "Installed. Next: $0 qemu   (tab 1)   and   $0 host   (tab 2)"
}

run_qemu() {
  sudo systemctl start nfs-kernel-server
  cd "$WORK"
  echo "QEMU starting. Log in as root. UART1 is listening on host port $PORT."
  qemu-system-arm -M vexpress-a15 -cpu cortex-a15 -m 512 -display none \
    -serial mon:stdio -serial tcp::$PORT,server,nowait \
    -kernel zImage -dtb vexpress-v2p-ca15-tc1.dtb \
    -nic user,model=lan9118 \
    -append "root=/dev/nfs nfsroot=10.0.2.2:$NFSROOT,nfsvers=3,tcp,port=2049,mountport=20048 rw ip=dhcp console=ttyAMA0"
}

run_host() {
  echo "Connecting to the guest's UART1 on localhost:$PORT (Ctrl+C to quit)"
  echo "Text sent from the guest appears here; type + Enter to send to the guest."
  nc localhost "$PORT"
}

case "${1:-}" in
  install) install_all ;;
  qemu)    run_qemu ;;
  host)    run_host ;;
  *)       echo "usage: $0 [install|qemu|host]"; exit 1 ;;
esac
