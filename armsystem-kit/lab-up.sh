#!/bin/bash
# Start the lab network: tap0 (192.168.0.1/24) and an NFS export of outfs2 that
# only 192.168.0.2 (the guest) may mount. Run as your user; every command below
# needs root (network devices, /etc/exports.d, system services) and is run via sudo.
# Nothing is enabled at boot: after a reboot the lab is down until you run this again.
set -euo pipefail
A=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
EXPORTS=/etc/exports.d/armsystem.exports
[ "$EUID" -ne 0 ] || { echo 'Run as your normal user; the script calls sudo itself.' >&2; exit 1; }
[ -e "$A/outfs2/bin/busybox" ] || { echo "NFS root $A/outfs2 is not unpacked; run install.sh first." >&2; exit 1; }
command -v exportfs >/dev/null || [ -x /usr/sbin/exportfs ] || { echo 'nfs-kernel-server is not installed; run install.sh.' >&2; exit 1; }

# 192.168.0.0/24 must not already be used by another interface (home routers often use it).
if ip -4 -o addr show | grep -v ' tap0 ' | grep -q 'inet 192\.168\.0\.'; then
  echo 'Another interface already uses 192.168.0.x; the lab network would conflict. Aborting.' >&2
  ip -4 -o addr show | grep 'inet 192\.168\.0\.' >&2
  exit 1
fi

echo '==> sudo: creating tap0 owned by you, so QEMU can run without root'
if ! ip link show tap0 >/dev/null 2>&1; then
  sudo ip tuntap add dev tap0 mode tap user "$(id -un)"
fi
sudo ip addr replace 192.168.0.1/24 dev tap0
sudo ip link set tap0 up

echo "==> sudo: exporting $A/outfs2 to 192.168.0.2 only"
sudo mkdir -p /etc/exports.d
echo "$A/outfs2 192.168.0.2(rw,sync,no_root_squash,no_subtree_check)" | sudo tee "$EXPORTS" >/dev/null

echo '==> sudo: starting the NFS server for this session (not enabled at boot)'
sudo systemctl start nfs-server.service
sudo exportfs -ra
sudo exportfs -v

others=$(sudo exportfs -s | grep -c -v -F "$A/outfs2 " || true)
[ "$others" -eq 0 ] || echo "WARNING: $others other NFS export line(s) exist on this machine (see above)." >&2
for u in nfs-server.service rpcbind.service rpcbind.socket; do
  if [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ]; then
    echo "WARNING: $u is enabled at boot. To fix: sudo systemctl disable $u" >&2
  fi
done
echo
echo 'Lab is up. Ports 111 and 2049 are open until you run ./lab-down.sh.'
echo 'Next: ./run_qemu   (or ./verify.sh)'
