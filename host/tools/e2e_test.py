"""End-to-end test: the real host (portable build) + the real Godot client.

    python3 host/tools/e2e_test.py

No headset needed. Builds host/build/immersive2_host with cmake (incremental),
runs it with --stub (three fake grey monitors, input only logged), and runs the client headless with `godot` from PATH (Godot 4.7).

Checks, in order:
  1. The client connects, streams all three stub monitors and decodes each one
     onto its own panel (each stub monitor is a distinct grey shade).
  2. Host killed      -> the client notices and reconnects to a new host.
  3. Host frozen      -> the client times out instead of hanging forever, and
                         reconnects once the host is back.
  4. The host turns on TCP keepalive, so a headset that vanishes without
     closing the socket (Wi-Fi drop, battery) does not leave a ghost client.
  5. USB mode: video and audio in-band on the TCP control socket.
  6. LAN discovery finds the host (client/tests/discovery_test.gd), and PIN
     pairing: over the PC's LAN address the client is refused without the
     PIN (and stops retrying), and streams with it.
  7. Ctrl+C on the host exits promptly.
  8. The in-VR menu works with pointer clicks (keypads, PIN, tabs, layout),
     via client/tests/overlay_test.gd. Needs xvfb-run; skipped without it.
  9. Headless unit checks: hand tracking (a pinch clicks where the hand
     points), controllers (clicks, grip right-click vs grab, idle hiding),
     curved-screen ray hits, grabbing and the VR keyboard.
"""
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HOST_BIN = os.path.join(ROOT, "host", "build", "immersive2_host")
CLIENT_DIR = os.path.join(ROOT, "client", "project")
MONITORS = [0, 1, 2]
PIN = "246810"


class Proc:
    """A child process whose output is collected line by line for wait_for()."""

    def __init__(self, name, cmd):
        self.name = name
        self.lines = []
        self.p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  text=True, errors="replace", bufsize=1)
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.p.stdout:
            self.lines.append(line.rstrip())
            if os.environ.get("E2E_VERBOSE"):
                print(f"  {self.name}| {line.rstrip()}")

    def mark(self):
        return len(self.lines)

    def wait_for(self, pattern, timeout, since=0):
        """Return the regex match of the first line after `since` matching `pattern`."""
        rx = re.compile(pattern)
        end = time.time() + timeout
        i = since
        while time.time() < end:
            while i < len(self.lines):
                m = rx.search(self.lines[i])
                if m:
                    return m
                i += 1
            time.sleep(0.05)
        fail(f"{self.name}: no line matching {pattern!r} within {timeout}s")

    def signal(self, sig):
        if self.p.poll() is None:
            self.p.send_signal(sig)

    def stop(self):
        self.signal(signal.SIGCONT)
        self.signal(signal.SIGKILL)
        self.p.wait()


procs = []


def fail(msg):
    print(f"\nFAIL: {msg}")
    for p in procs:
        print(f"--- last lines of {p.name} ---")
        print("\n".join(p.lines[-25:]))
    for p in procs:
        p.stop()
    sys.exit(1)


def step(msg):
    print(f"[e2e] {msg}")


def start_host():
    # stdbuf: the host's stdout is block-buffered into a pipe otherwise.
    host = Proc("host", ["stdbuf", "-oL", HOST_BIN, "--stub", "--no-ui", "--pin", PIN])
    procs.append(host)
    host.wait_for(r"\[Host\] Ready", 10)
    return host


def expect_streaming(client, since):
    """All monitors streaming and, soon after, each panel showing that
    monitor's shade (a capture taken between STREAM_START and the first
    decoded frame still shows the empty screen)."""
    for mid in MONITORS:
        client.wait_for(rf"Streaming monitor {mid} ", 20, since)
    start = client.mark()
    for mid in MONITORS:
        # The --stub capture fills monitor i with grey 64 + 48*i.
        expect_shade(client, mid, 64 + 48 * mid, start)


def expect_shade(client, mid, want, since):
    """Monitor `mid`'s panel shows grey `want` within 20 s."""
    rx = re.compile(rf"panel mon={mid} \d+x\d+ center=(\w{{6}})")
    end = time.time() + 20
    seen = None
    i = since
    while time.time() < end:
        while i < len(client.lines):
            m = rx.search(client.lines[i])
            i += 1
            if m:
                seen = m.group(1)
                got = [int(seen[k:k + 2], 16) for k in (0, 2, 4)]
                if all(abs(c - want) <= 8 for c in got):
                    return
        time.sleep(0.05)
    fail(f"monitor {mid} panel shows #{seen}, expected grey {want}")


def main():
    if not shutil.which("godot"):
        fail("`godot` (4.7) not found on PATH")
    step("building host")
    if not os.path.isdir(os.path.join(ROOT, "host", "build")):
        subprocess.run(["cmake", "-B", "build", "-DCMAKE_BUILD_TYPE=Release",
                        "-DENABLE_NVENC=OFF", "-DENABLE_AMF=OFF", "-DENABLE_QSV=OFF"],
                       cwd=os.path.join(ROOT, "host"), check=True, stdout=subprocess.DEVNULL)
    # Always (incremental): a stale binary predating --stub would fail oddly.
    subprocess.run(["cmake", "--build", "build", "-j"],
                       cwd=os.path.join(ROOT, "host"), check=True, stdout=subprocess.DEVNULL)

    # Class names (SoftwareVideoDecoder, ...) need an up-to-date import cache.
    step("importing Godot project")
    subprocess.run(["godot", "--headless", "--path", CLIENT_DIR, "--import"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    host = start_host()
    client = Proc("client", [
        "godot", "--headless", "--xr-mode", "off", "--path", CLIENT_DIR, "--",
        "--im2-host=127.0.0.1", "--im2-capture",
        "--im2-monitors=" + ",".join(map(str, MONITORS))])
    procs.append(client)

    step("1/10 connect, stream and decode 3 monitors")
    expect_streaming(client, 0)

    step("2/10 host killed -> client reconnects to a new host")
    mark = client.mark()
    host.stop()
    client.wait_for(r"\[Immersive-2\] Disconnected from host", 10, mark)
    host = start_host()
    expect_streaming(client, mark)

    step("3/10 host frozen -> client times out, then recovers")
    mark = client.mark()
    host.signal(signal.SIGSTOP)
    client.wait_for(r"\[Immersive-2\] Disconnected from host", 20, mark)
    host.signal(signal.SIGCONT)
    expect_streaming(client, mark)

    step("4/10 host sockets use TCP keepalive")
    if shutil.which("ss"):
        out = subprocess.run(["ss", "-tno", "state", "established", "( sport = :19800 )"],
                             capture_output=True, text=True).stdout
        if "keepalive" not in out:
            fail(f"no keepalive timer on the host's client socket:\n{out}")
    else:
        print("      (skipped: `ss` not available)")

    step("5/10 USB mode: video over the TCP control socket")
    # Same thing a headset on a cable does through `adb reverse`.
    client.stop()
    procs.remove(client)
    mark = host.mark()
    usb = Proc("client-usb", [
        "godot", "--headless", "--xr-mode", "off", "--path", CLIENT_DIR, "--",
        "--im2-host=127.0.0.1", "--im2-usb", "--im2-capture",
        "--im2-monitors=" + ",".join(map(str, MONITORS))])
    procs.append(usb)
    host.wait_for(r"says hello: .*\(video/audio over TCP\)", 20, mark)
    expect_streaming(usb, 0)
    client_lines = client.lines + usb.lines

    step("6/10 LAN discovery and PIN pairing")
    run_godot_test("discovery_test.gd")
    lan = lan_ip()
    if lan:
        usb.stop()
        procs.remove(usb)
        mark = host.mark()
        nopin = Proc("client-nopin", [
            "godot", "--headless", "--xr-mode", "off", "--path", CLIENT_DIR, "--",
            "--im2-host=" + lan, "--im2-monitors=0"])
        procs.append(nopin)
        nopin.wait_for(r"host refused the connection \(reason 1\)", 20)
        host.wait_for(r"refused: no PIN", 5, mark)
        time.sleep(7)  # longer than the reconnect delay
        if any("Attempting auto-reconnect" in l for l in nopin.lines):
            fail("client kept retrying after the host asked for a PIN")
        nopin.stop()
        procs.remove(nopin)
        paired = Proc("client-pin", [
            "godot", "--headless", "--xr-mode", "off", "--path", CLIENT_DIR, "--",
            "--im2-host=" + lan, "--im2-pin=" + PIN, "--im2-capture",
            "--im2-monitors=" + ",".join(map(str, MONITORS))])
        procs.append(paired)
        expect_streaming(paired, 0)
        client_lines += nopin.lines + paired.lines
    else:
        print("      (PIN over the network skipped: this machine has no LAN address)")

    step("7/10 a virtual screen asked for from the headset")
    for p in procs:
        if p is not host:
            p.stop()
    mark = host.mark()
    virt = Proc("client-virtual", [
        "godot", "--headless", "--xr-mode", "off", "--path", CLIENT_DIR, "--",
        "--im2-host=127.0.0.1", "--im2-capture", "--im2-monitors=0",
        "--im2-virtual=1280x720"])
    procs.append(virt)
    host.wait_for(r"asked for a 1280x720 virtual screen: monitor 100", 20, mark)
    virt.wait_for(r"Streaming monitor 100 ", 20)
    expect_shade(virt, 100, 208, 0)  # the --stub virtual screens' grey
    client_lines += virt.lines

    step("8/10 Ctrl+C -> host exits")
    host.signal(signal.SIGINT)
    try:
        host.p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        fail("host still running 5 s after SIGINT")

    errors = [l for l in client_lines if "SCRIPT ERROR" in l]
    if errors:
        fail("client raised script errors:\n" + "\n".join(errors[:10]))
    for p in procs:
        p.stop()
    procs.clear()

    step("9/10 in-VR menu: keypads, PIN, tabs and layout")
    if shutil.which("xvfb-run"):
        menu = Proc("menu", ["xvfb-run", "-a", "godot", "--rendering-driver", "opengl3",
                             "--xr-mode", "off", "--audio-driver", "Dummy", "--path", CLIENT_DIR,
                             "-s", os.path.join(ROOT, "client", "tests", "overlay_test.gd")])
        procs.append(menu)
        menu.wait_for(r"RESULT fails=0", 60)
        menu.stop()
    else:
        print("      (skipped: `xvfb-run` not available)")

    step("10/10 hand tracking, controllers, screens and keyboard")
    for test in ("hand_input_test.gd", "controller_idle_test.gd", "workspace_test.gd"):
        run_godot_test(test)
    print("\nOK: end-to-end host <-> client checks passed")


def run_godot_test(test):
    """A headless GDScript check from client/tests that prints RESULT fails=N."""
    t = Proc(test, ["godot", "--headless", "--xr-mode", "off", "--fixed-fps", "72",
                    "--path", CLIENT_DIR, "-s", os.path.join(ROOT, "client", "tests", test)])
    procs.append(t)
    t.wait_for(r"RESULT fails=0", 60)
    t.stop()
    procs.remove(t)


def lan_ip():
    """This machine's LAN address (source of its default route), or None."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 53))  # nothing is sent
        ip = s.getsockname()[0]
        return None if ip.startswith("127.") else ip
    except OSError:
        return None
    finally:
        s.close()


if __name__ == "__main__":
    main()
