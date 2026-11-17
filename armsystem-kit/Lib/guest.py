#!/usr/bin/env python3
"""Drive the ARM guest over its console (ttyAMA1 on QEMU's stdio).

Used by verify.sh, and usable on its own:
  guest.py --prefix ~/armsystem --mode initramfs -- 'uname -a' '/root/hello'
Modes:
  nfs        NFS root over tap0 (needs lab-up.sh first)
  initramfs  rootfs.cpio in RAM, QEMU user networking, no sudo at all
"""
import argparse
import os
import select
import subprocess
import sys
import time

QEMU = "qemu-system-arm"
UART_SOCK = "/tmp/qemu-uart"


class Guest:
    def __init__(self, prefix, mode="nfs", log=None, extra_cpio=None,
                 kernel=None, hostfwd=None, uart_sock=UART_SOCK):
        self.prefix = os.path.abspath(prefix)
        self.mode = mode
        self.buf = b""
        self.n = 0
        self.log = open(log, "wb") if log else None
        img = os.path.join(self.prefix, "images")
        kernel = kernel or os.path.join(img, "zImage")
        cmd = [QEMU, "-M", "vexpress-a15", "-cpu", "cortex-a15", "-smp", "1",
               "-m", "512", "-display", "none", "-monitor", "none",
               "-audio", "driver=none", "-no-reboot",
               "-serial", "unix:%s,server=on,wait=off" % uart_sock,
               "-serial", "stdio",
               "-kernel", kernel,
               "-dtb", os.path.join(img, "vexpress-v2p-ca15-tc1.dtb")]
        if mode == "nfs":
            cmd += ["-netdev", "tap,id=n0,ifname=tap0,script=no,downscript=no",
                    "-net", "nic,model=lan9118,netdev=n0",
                    "-append",
                    "console=ttyAMA1 root=/dev/nfs "
                    "nfsroot=192.168.0.1:%s/outfs2,vers=3,tcp,nolock "
                    "ip=192.168.0.2:192.168.0.1:192.168.0.1:255.255.255.0:qemu:eth0 "
                    "rw init=/sbin/init panic=-1" % self.prefix]
        else:
            initrd = os.path.join(img, "rootfs.cpio")
            if extra_cpio:
                # initramfs = shipped rootfs.cpio followed by a second archive
                merged = extra_cpio + ".merged"
                with open(merged, "wb") as out:
                    for part in (initrd, extra_cpio):
                        with open(part, "rb") as f:
                            out.write(f.read())
                initrd = merged
            # user networking on the lab subnet, so the guest's static
            # 192.168.0.2 works and 192.168.0.1 answers ping; no sudo needed
            net = "user,id=n0,net=192.168.0.0/24,host=192.168.0.1"
            for port in hostfwd or []:
                net += ",hostfwd=tcp:127.0.0.1:%d-192.168.0.2:%d" % (port, port)
            cmd += ["-netdev", net, "-net", "nic,model=lan9118,netdev=n0",
                    "-initrd", initrd,
                    "-append", "console=ttyAMA1 rdinit=/sbin/init panic=-1"]
        self.cmd = cmd
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT)
        self.t0 = time.time()

    def _read(self, timeout):
        if not select.select([self.proc.stdout], [], [], max(timeout, 0))[0]:
            return False
        data = os.read(self.proc.stdout.fileno(), 4096)
        if not data:
            return False
        if self.log:
            self.log.write(data)
            self.log.flush()
        self.buf += data
        return True

    def expect(self, pat, timeout):
        """Wait for bytes `pat`; return everything before it, or None."""
        end = time.time() + timeout
        while pat not in self.buf:
            if not self._read(end - time.time()):
                if pat in self.buf:
                    break
                return None
        before, self.buf = self.buf.split(pat, 1)
        return before

    def send(self, text):
        self.proc.stdin.write(text.encode())
        self.proc.stdin.flush()

    def login(self, timeout=180):
        """Wait for the login prompt, log in as root. Returns seconds or None."""
        if self.expect(b"login: ", timeout) is None:
            return None
        took = time.time() - self.t0
        self.send("root\n")
        if self.expect(b"# ", 30) is None:
            return None
        return took

    def start(self, command):
        """Start a shell command; collect its result later with finish()."""
        self.n += 1
        # typed as @@"ENDn" so the echo of the command line never matches
        self.send('%s; echo @@"END%d" rc=$?\n' % (command, self.n))

    def run(self, command, timeout=60):
        """Run a shell command in the guest. Returns (rc, output); rc None on timeout."""
        self.start(command)
        return self.finish(timeout)

    def finish(self, timeout=60):
        """Wait for the command begun by start(). Returns (rc, output)."""
        mark = "@@END%d" % self.n
        out = self.expect((mark + " rc=").encode(), timeout)
        if out is None:
            return None, ""
        rc_line = self.expect(b"\n", 10) or b"1"
        self.expect(b"# ", 10)
        text = out.decode(errors="replace").replace("\r", "")
        text = text.split("\n", 1)[1] if "\n" in text else ""  # drop the echo
        try:
            return int(rc_line.strip() or b"1"), text
        except ValueError:
            return None, text

    def poweroff(self, timeout=40):
        """Power off cleanly; kill QEMU if it does not exit. Returns exit code."""
        try:
            self.send("poweroff\n")
            end = time.time() + timeout
            while self.proc.poll() is None and time.time() < end:
                self._read(1)
        except (OSError, ValueError):
            pass
        return self.kill()

    def kill(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        if self.log:
            self.log.close()
            self.log = None
        return self.proc.returncode


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prefix", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--mode", choices=["nfs", "initramfs"], default="nfs")
    ap.add_argument("--kernel")
    ap.add_argument("--extra-cpio", help="second cpio archive appended to rootfs.cpio (initramfs mode)")
    ap.add_argument("--log")
    ap.add_argument("--uart-sock", default=UART_SOCK)
    ap.add_argument("commands", nargs="*")
    a = ap.parse_args()
    g = Guest(a.prefix, a.mode, a.log, a.extra_cpio, a.kernel, uart_sock=a.uart_sock)
    worst = 0
    try:
        took = g.login()
        if took is None:
            print("guest did not reach a login prompt", file=sys.stderr)
            return 2
        print("[login after %.1fs]" % took)
        for c in a.commands:
            rc, out = g.run(c)
            print("# %s\n%s[rc=%s]" % (c, out, rc))
            if rc != 0:
                worst = 1
    finally:
        g.poweroff()
    return worst


if __name__ == "__main__":
    sys.exit(main())
