#!/usr/bin/env bash
# start-lab.sh: brings the lab up, runs QEMU, and always tears it down on exit.
# If the lab was already up (./lab-up.sh run by hand), it is left running.
cd "$(dirname "$0")" || exit 1

# --initramfs needs no network and no sudo: just run it.
if [ "${1:-}" = "--initramfs" ]; then exec ./run_qemu "$@"; fi

started=0
if ip link show tap0 >/dev/null 2>&1; then
    echo "==> tap0 already exists; using the lab that is already up."
else
    ./lab-up.sh || exit 1
    started=1
fi

cleanup() {
    if [ "$started" = 1 ]; then
        echo "==> shutting the lab down"
        ./lab-down.sh
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

./run_qemu "$@"
