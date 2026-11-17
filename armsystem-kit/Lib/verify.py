#!/usr/bin/env python3
"""Acceptance test body; started by verify.sh (which also handles cleanup).

Prints one line per item: PASS / FAIL / SKIP. Exit status 0 only if nothing failed.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from guest import Guest  # noqa: E402

results = []


def report(status, item, detail=""):
    results.append(status)
    print("%-4s  %-34s %s" % (status, item, detail), flush=True)


def sh(cmd, timeout=120, **kw):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, timeout=timeout, **kw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--mode", choices=["nfs", "initramfs"], required=True)
    ap.add_argument("--tmp", required=True, help="host scratch directory")
    ap.add_argument("--share", help="host directory the guest sees (nfs mode)")
    ap.add_argument("--guest-share", help="the same directory as seen in the guest")
    a = ap.parse_args()
    nfs = a.mode == "nfs"
    gcc = os.path.join(a.prefix, "toolchain/bin/arm-linux-gcc")
    sysroot = os.path.join(a.prefix, "toolchain/arm-buildroot-linux-gnueabi/sysroot")
    uart_sock = os.path.join(a.tmp, "qemu-uart")
    uart_pty = os.path.join(a.tmp, "virtual-uart")

    # ---- build the test program on the host (needed before boot in initramfs mode)
    hello = os.path.join(a.tmp, "hello")
    cc = sh([gcc, "-g", "-O0", "-o", hello, os.path.join(a.prefix, "examples/hello.c")])
    built = cc.returncode == 0
    dynamic = built and "ld-linux.so.3" in sh(["file", "-b", hello]).stdout
    extra = None
    if nfs:
        gdir = a.guest_share
        if built:
            shutil.copy(hello, os.path.join(a.share, "hello"))
    else:
        gdir = "/root/verify"
        if built:
            tree = os.path.join(a.tmp, "cpio")
            os.makedirs(os.path.join(tree, "root/verify"))
            shutil.copy(hello, os.path.join(tree, "root/verify/hello"))
            extra = os.path.join(a.tmp, "extra.cpio")
            with open(extra, "wb") as out:
                subprocess.run(["cpio", "-o", "-H", "newc", "--owner=+0:+0", "--quiet"],
                               cwd=tree, input=b"root/verify\nroot/verify/hello\n",
                               stdout=out, check=True)

    g = Guest(a.prefix, a.mode, log=os.path.join(a.tmp, "console.log"),
              extra_cpio=extra, hostfwd=[2345], uart_sock=uart_sock)
    socat = None
    try:
        # ---- 1. boot to shell
        took = g.login(timeout=150)
        if took is None:
            report("FAIL", "boot to shell (%s root)" % a.mode, "no login prompt within 150 s")
            for item in ("ping guest -> host", "ping host -> guest", "dynamic hello runs in guest",
                         "UART0 echo (socat + pyserial)", "gdbserver breakpoint"):
                report("SKIP", item, "guest did not boot")
            return
        rc, out = g.run("grep ' / ' /proc/mounts")
        want = " nfs " if nfs else "rootfs"
        ok = rc == 0 and want in out
        report("PASS" if ok else "FAIL", "boot to shell (%s root)" % a.mode,
               "login after %.1f s; %s" % (took, out.strip().splitlines()[-1][:60] if out.strip() else "no / mount"))

        # ---- 2. ping both ways
        rc, out = g.run("ping -c 3 -W 2 192.168.0.1", timeout=30)
        line = [x for x in out.splitlines() if "packets" in x]
        report("PASS" if rc == 0 else "FAIL", "ping guest -> host", line[0] if line else out.strip()[-60:])
        if nfs:
            r = sh(["ping", "-c", "3", "-W", "2", "192.168.0.2"], timeout=30)
            line = [x for x in r.stdout.splitlines() if "packets" in x]
            report("PASS" if r.returncode == 0 else "FAIL", "ping host -> guest",
                   line[0] if line else r.stdout.strip()[-60:])
        else:
            report("SKIP", "ping host -> guest", "not possible with QEMU user networking")

        # ---- 3. cross-compiled dynamic hello
        if not built:
            report("FAIL", "dynamic hello runs in guest", "SDK compile failed: " + cc.stdout.strip()[-80:])
        else:
            rc, out = g.run("%s/hello" % gdir)
            ok = rc == 0 and "answer=42" in out and dynamic
            report("PASS" if ok else "FAIL", "dynamic hello runs in guest",
                   "%s%s" % (out.strip()[:50], "" if dynamic else " (binary is not dynamically linked!)"))

        # ---- 4. UART0 echo through socat + pyserial
        try:
            import serial
            socat = subprocess.Popen(["socat", "PTY,link=%s,raw,echo=0" % uart_pty,
                                      "UNIX-CONNECT:%s" % uart_sock],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(50):
                if os.path.exists(uart_pty):
                    break
                time.sleep(0.1)
            payload = bytes([0x00, 0x80, 0xff]) + b"armsystem-uart\n"
            # The guest prints READY once ttyAMA0 is open (opening flushes input).
            # It is typed as 'REA'+'DY' so the echo of the command line cannot match.
            g.start("python3 -c \"import serial; s=serial.Serial('/dev/ttyAMA0',115200,timeout=15); "
                    "print('REA'+'DY',flush=True); d=s.read(%d); s.write(d); s.flush(); "
                    "print('guest got',d.hex())\"" % len(payload))
            if g.expect(b"READY", 30) is None:
                raise RuntimeError("guest did not open /dev/ttyAMA0")
            with serial.Serial(uart_pty, 115200, timeout=10) as port:
                port.write(payload)
                port.flush()
                back = port.read(len(payload))
            rc, out = g.finish(30)
            ok = back == payload and payload.hex() in out
            report("PASS" if ok else "FAIL", "UART0 echo (socat + pyserial)",
                   "%d bytes sent incl. 00 80 ff, %d echoed back%s"
                   % (len(payload), len(back), "" if ok else " MISMATCH"))
        except Exception as e:  # noqa: BLE001 - report any failure as FAIL
            report("FAIL", "UART0 echo (socat + pyserial)", str(e)[:80])
            g.finish(20)

        # ---- 5. gdbserver + gdb-multiarch breakpoint
        if not built:
            report("SKIP", "gdbserver breakpoint", "no test program")
        else:
            target = "192.168.0.2:2345" if nfs else "127.0.0.1:2345"
            g.start("gdbserver :2345 %s/hello" % gdir)
            if g.expect(b"Listening on port 2345", 30) is None:
                report("FAIL", "gdbserver breakpoint", "gdbserver did not start in the guest")
                g.finish(10)
            else:
                r = sh(["gdb-multiarch", "-nx", "-batch", hello,
                        "-ex", "set sysroot %s" % sysroot,
                        "-ex", "target remote %s" % target,
                        "-ex", "break main", "-ex", "continue", "-ex", "next",
                        "-ex", "print answer", "-ex", "continue"], timeout=90)
                with open(os.path.join(a.tmp, "gdb.log"), "w") as f:
                    f.write(r.stdout)
                g.finish(30)
                hit = "Breakpoint 1, main" in r.stdout
                val = "$1 = 42" in r.stdout
                done = "exited normally" in r.stdout
                report("PASS" if hit and val and done else "FAIL", "gdbserver breakpoint",
                       "breakpoint at main %s, print answer %s, exit %s"
                       % ("hit" if hit else "NOT hit", "= 42" if val else "wrong", "normal" if done else "abnormal"))
    finally:
        if socat:
            socat.terminate()
            socat.wait()
        code = g.poweroff()
        print("      QEMU exit code after poweroff: %s" % code)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        report("FAIL", "verify.py internal error", repr(e)[:100])
    n_fail = results.count("FAIL")
    print("\n%d PASS, %d FAIL, %d SKIP" % (results.count("PASS"), n_fail, results.count("SKIP")))
    sys.exit(1 if n_fail or not results else 0)
