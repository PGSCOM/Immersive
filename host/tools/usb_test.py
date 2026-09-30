"""USB tunnel check: the host's `adb reverse` upkeep, against a fake adb.

    python3 host/tools/usb_test.py [path/to/immersive2_host]

Linux/macOS, no device needed (and a real adb is never run: PATH and HOME are
replaced). The fake adb lists two headsets, one that has not allowed USB
debugging, and records every call. Checks that the host:
  - finds adb on PATH, and without PATH in ~/Android/Sdk/platform-tools;
  - arms `adb -s <serial> reverse tcp:P tcp:P` on the authorised headset
    only, and tells the person to accept the prompt on the other;
  - logs changes only, and does not re-arm a tunnel that is still there;
  - arms the second headset once it is authorised, and re-arms a headset
    that was unplugged and plugged back in;
  - keeps its sockets out of adb (an adb server it starts would otherwise
    hold the host's port after it exits);
  - exits promptly on Ctrl+C.
Ports: IM2_TCP_PORT / IM2_UDP_PORT (default 51860 / 51861).
"""
import os
import pty
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HOST_BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "host", "build", "immersive2_host")
TCP_PORT = int(os.environ.get("IM2_TCP_PORT", 51860))
UDP_PORT = int(os.environ.get("IM2_UDP_PORT", 51861))

FAKE_ADB = r'''
import os, sys
state = os.environ["FAKE_ADB_STATE"]
args = sys.argv[1:]
with open(os.path.join(state, "calls.log"), "a") as f:
    f.write(" ".join(args) + "\n")
    if os.path.isdir("/proc/self/fd"):
        for fd in os.listdir("/proc/self/fd"):
            try:
                if os.readlink("/proc/self/fd/" + fd).startswith("socket:"):
                    f.write("INHERITED SOCKET fd %s\n" % fd)
            except OSError:
                pass
def devices():
    with open(os.path.join(state, "devices")) as f:
        return dict(l.rstrip("\n").split("\t") for l in f if "\t" in l)
if args == ["start-server"]:
    sys.exit(0)
if args == ["devices"]:
    print("List of devices attached")
    for s, st in devices().items():
        print(s + "\t" + st)
    print()
    sys.exit(0)
if len(args) >= 3 and args[0] == "-s" and args[2] == "reverse":
    serial, rules = args[1], os.path.join(state, "rules_" + args[1])
    if devices().get(serial) != "device":
        print("error: device unauthorized.")
        sys.exit(1)
    if args[3:] == ["--list"]:
        if os.path.exists(rules):
            print(open(rules).read(), end="")
        sys.exit(0)
    with open(rules, "a") as f:
        f.write("UsbFfs %s %s\n" % (args[3], args[4]))
    print(args[3].split(":")[1])
    sys.exit(0)
print("fake adb: unexpected " + " ".join(args))
sys.exit(1)
'''


hosts = []


def fail(msg):
    print(f"FAIL: {msg}")
    for h in hosts:
        h.p.kill()
    sys.exit(1)


class Host:
    def __init__(self, env):
        cmd = [HOST_BIN, "--stub", "--no-pin", "--tcp-port", str(TCP_PORT),
               "--udp-port", str(UDP_PORT), "--audio-port", str(UDP_PORT + 1)]
        self.lines = []
        # A terminal, so the host's stdout is line-buffered (no stdbuf on macOS).
        self.master, slave = pty.openpty()
        self.p = subprocess.Popen(cmd, env=env, stdin=subprocess.DEVNULL, stdout=slave,
                                  stderr=slave)
        os.close(slave)
        threading.Thread(target=self._pump, daemon=True).start()
        hosts.append(self)

    def _pump(self):
        buf = b""
        while True:
            try:
                data = os.read(self.master, 4096)
            except OSError:
                break
            if not data:
                break
            buf += data
            *done, buf = buf.split(b"\n")
            self.lines += [l.decode(errors="replace").rstrip() for l in done]

    def wait_for(self, pattern, timeout=10):
        rx = re.compile(pattern)
        end = time.time() + timeout
        while time.time() < end:
            for l in self.lines:
                if rx.search(l):
                    return l
            time.sleep(0.05)
        fail(f"host: no line matching {pattern!r} in {timeout}s\n  " + "\n  ".join(self.lines[-20:]))

    def count(self, pattern):
        return sum(1 for l in self.lines if re.search(pattern, l))

    def stop(self):
        hosts.remove(self)
        self.p.send_signal(signal.SIGINT)
        try:
            self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.p.kill()
            fail("host still running 5 s after SIGINT")


def main():
    if not os.path.exists(HOST_BIN):
        fail(f"{HOST_BIN} not built")
    tmp = tempfile.mkdtemp(prefix="im2-usb-")
    try:
        run(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("OK: adb tunnel upkeep checks passed")


def run(tmp):
    state = os.path.join(tmp, "state")
    fakebin = os.path.join(tmp, "bin")
    home = os.path.join(tmp, "home")
    nothing = os.path.join(tmp, "empty")  # PATH with no adb (nor anything else)
    for d in (state, fakebin, home, nothing):
        os.makedirs(d)
    adb = os.path.join(fakebin, "adb")
    with open(adb, "w") as f:
        f.write("#!" + sys.executable + FAKE_ADB)
    os.chmod(adb, 0o755)

    def set_devices(text):
        with open(os.path.join(state, "devices"), "w") as f:
            f.write(text)

    def calls():
        with open(os.path.join(state, "calls.log")) as f:
            return f.read().splitlines()

    rule = f"tcp:{TCP_PORT} tcp:{TCP_PORT}"
    base_env = dict(os.environ, FAKE_ADB_STATE=state, HOME=home, PATH=nothing)
    base_env.pop("ANDROID_HOME", None)
    base_env.pop("ANDROID_SDK_ROOT", None)

    print("[usb] adb on PATH, two headsets, one not authorised")
    set_devices("AAA111\tdevice\nBBB222\tunauthorized\n")
    host = Host(dict(base_env, PATH=fakebin))
    host.wait_for(re.escape(f"by itself ({adb})"))
    host.wait_for(r"headset AAA111 is on the cable")
    host.wait_for(r"headset BBB222 is plugged in but has not allowed USB debugging: .*accept the prompt")
    time.sleep(7)  # two more rounds: nothing new to say, nothing to re-arm
    c = calls()
    if c.count(f"-s AAA111 reverse {rule}") != 1:
        fail(f"AAA111 should be armed exactly once, calls:\n{c}")
    if any(l.startswith("-s BBB222 reverse tcp") for l in c):
        fail("tried to arm the unauthorised headset")
    if host.count("AAA111") != 1 or host.count("BBB222") != 1:
        fail("repeated log lines for an unchanged state:\n  " + "\n  ".join(host.lines[-15:]))
    if any("INHERITED" in l for l in c):
        fail("adb inherited the host's sockets: " + next(l for l in c if "INHERITED" in l))

    print("[usb] the second headset is authorised")
    set_devices("AAA111\tdevice\nBBB222\tdevice\n")
    host.wait_for(r"headset BBB222 is on the cable")
    if f"-s BBB222 reverse {rule}" not in calls():
        fail("BBB222 not armed once authorised")

    print("[usb] AAA111 unplugged and plugged back in")
    set_devices("BBB222\tdevice\n")
    host.wait_for(r"headset AAA111 unplugged")
    os.remove(os.path.join(state, "rules_AAA111"))  # a fresh connection has no rules
    set_devices("AAA111\tdevice\nBBB222\tdevice\n")
    end = time.time() + 10
    while calls().count(f"-s AAA111 reverse {rule}") < 2:
        if time.time() > end:
            fail("AAA111 not re-armed after replug")
        time.sleep(0.1)
    end = time.time() + 5  # the line follows the reverse call; give it a moment
    while host.count("headset AAA111 is on the cable") < 2 and time.time() < end:
        time.sleep(0.05)
    if host.count("headset AAA111 is on the cable") != 2:
        fail("replug not reported")
    host.stop()

    print("[usb] no adb on PATH: found in ~/Android/Sdk/platform-tools")
    sdk = os.path.join(home, "Android", "Sdk", "platform-tools")
    os.makedirs(sdk)
    shutil.copy(adb, sdk)
    host = Host(base_env)
    host.wait_for(re.escape(f"by itself ({os.path.join(sdk, 'adb')})"))
    host.wait_for(r"headset AAA111 is on the cable")
    host.stop()

    print("[usb] no adb anywhere")
    shutil.rmtree(os.path.join(home, "Android"))
    if not any(os.path.exists(os.path.join(d, "adb")) for d in
               ("/usr/bin", "/usr/local/bin", "/opt/homebrew/bin",
                "/usr/lib/android-sdk/platform-tools", "/opt/android-sdk/platform-tools")):
        host = Host(base_env)
        host.wait_for(r"USB: adb not found")
        host.stop()
    else:
        print("      (skipped: this machine has adb in a system folder)")


if __name__ == "__main__":
    main()
