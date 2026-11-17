#!/bin/bash
# OPTIONAL extras for course module 3 (network analysis): tshark + wireshark.
# NOT run by install.sh. Needs sudo. Untested until run on a clean VM.
#   ./extras.sh
set -euo pipefail
[ "$EUID" -ne 0 ] || { echo 'Run as your normal user, not root; the script uses sudo itself.' >&2; exit 1; }
USER_NAME=$(id -un)
PKGS=(tshark wireshark)

sudo -v || { echo 'extras.sh: sudo is required.' >&2; exit 1; }

# Allow non-root capture (members of group "wireshark").
echo 'wireshark-common wireshark-common/install-setuid boolean true' | sudo debconf-set-selections
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}"
sudo usermod -aG wireshark "$USER_NAME"

echo
echo "Installed: ${PKGS[*]} (non-root capture enabled)"
for p in "${PKGS[@]}"; do dpkg-query -W -f='  ${Package} ${Version}\n' "$p" || true; done
echo "User '$USER_NAME' was added to group 'wireshark'."
echo 'A NEW LOGIN is required (log out and in, or reboot) before capture works without sudo.'
