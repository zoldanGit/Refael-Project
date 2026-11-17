#!/bin/bash
# Stop the lab: QEMU, the NFS export, the NFS/rpcbind services and tap0.
# Leaves ports 111 and 2049 closed and reports an error if they are not.
# Keeps outfs2 and everything else on disk. Run as your user (uses sudo).
set -uo pipefail
EXPORTS=/etc/exports.d/armsystem.exports
PIDFILE=/tmp/armsystem-qemu.pid
[ "$EUID" -ne 0 ] || { echo 'Run as your normal user; the script calls sudo itself.' >&2; exit 1; }

if [ -f "$PIDFILE" ] && pid=$(cat "$PIDFILE") && [ -n "$pid" ] \
   && grep -q qemu-system-arm "/proc/$pid/cmdline" 2>/dev/null; then
  echo "==> stopping QEMU (pid $pid)"
  kill "$pid"; sleep 2; kill -9 "$pid" 2>/dev/null || true
fi
rm -f "$PIDFILE" /tmp/qemu-uart /tmp/virtual-uart

echo '==> sudo: removing the NFS export'
sudo rm -f "$EXPORTS"
if [ -x /usr/sbin/exportfs ]; then sudo /usr/sbin/exportfs -ra 2>/dev/null || true; fi

# rpcbind.socket must be stopped too, or it restarts rpcbind on demand.
echo '==> sudo: stopping NFS and rpcbind (stop only; boot-time settings are not changed)'
sudo systemctl stop nfs-server.service nfs-mountd.service rpc-statd.service \
  nfs-idmapd.service nfsdcld.service rpcbind.socket rpcbind.service 2>/dev/null || true

if ip link show tap0 >/dev/null 2>&1; then
  echo '==> sudo: removing tap0'
  sudo ip link del tap0
fi

rc=0
open=$(ss -H -tuln 2>/dev/null | awk '{print $1, $5}' | grep -E ':(111|2049)$' || true)
if [ -n "$open" ]; then
  echo 'ERROR: these ports are still open:' >&2
  echo "$open" >&2
  rc=1
else
  echo 'OK: ports 111 and 2049 are closed.'
fi
for u in nfs-server.service rpcbind.service rpcbind.socket; do
  if [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ]; then
    echo "WARNING: $u is enabled at boot. To fix: sudo systemctl disable $u" >&2
  fi
done
if ip link show tap0 >/dev/null 2>&1; then echo 'ERROR: tap0 still exists.' >&2; rc=1; fi
exit $rc
