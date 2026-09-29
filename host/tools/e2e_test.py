"""End-to-end test: the real host (portable build) + the real Godot client.

    python3 host/tools/e2e_test.py

No headset needed. Builds host/build/immersive2_host with cmake if it is
missing, and runs the client headless with `godot` from PATH (Godot 4.7).

Checks, in order:
  1. The client connects, streams all three stub monitors and decodes each one
     onto its own panel (each stub monitor is a distinct grey shade).
  2. Host killed      -> the client notices and reconnects to a new host.
  3. Host frozen      -> the client times out instead of hanging forever, and
                         reconnects once the host is back.
  4. The host turns on TCP keepalive, so a headset that vanishes without
     closing the socket (Wi-Fi drop, battery) does not leave a ghost client.
  5. Ctrl+C on the host exits promptly.
  6. The in-VR menu works with pointer clicks (IP keypad, layout), via
     client/tests/overlay_test.gd. Needs xvfb-run; skipped without it.
"""
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HOST_BIN = os.path.join(ROOT, "host", "build", "immersive2_host")
CLIENT_DIR = os.path.join(ROOT, "client", "project")
MONITORS = [0, 1, 2]


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
    host = Proc("host", ["stdbuf", "-oL", HOST_BIN, "--no-audio"])
    procs.append(host)
    host.wait_for(r"\[Host\] Ready", 10)
    return host


def expect_streaming(client, since):
    """All monitors streaming and each panel showing that monitor's shade."""
    for mid in MONITORS:
        client.wait_for(rf"Streaming monitor {mid} ", 20, since)
    for mid in MONITORS:
        m = client.wait_for(rf"panel mon={mid} \d+x\d+ center=(\w{{6}})", 20, since)
        # The portable capture stub fills monitor i with grey 64 + 48*i.
        want = 64 + 48 * mid
        got = [int(m.group(1)[k:k + 2], 16) for k in (0, 2, 4)]
        if any(abs(c - want) > 8 for c in got):
            fail(f"monitor {mid} panel shows #{m.group(1)}, expected grey {want}")


def main():
    if not shutil.which("godot"):
        fail("`godot` (4.7) not found on PATH")
    if not os.path.exists(HOST_BIN):
        step("building host")
        subprocess.run(["cmake", "-B", "build", "-DCMAKE_BUILD_TYPE=Release",
                        "-DENABLE_NVENC=OFF", "-DENABLE_AMF=OFF", "-DENABLE_QSV=OFF"],
                       cwd=os.path.join(ROOT, "host"), check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["cmake", "--build", "build", "-j"],
                       cwd=os.path.join(ROOT, "host"), check=True, stdout=subprocess.DEVNULL)

    # Class names (SoftwareVideoDecoder, ...) need the import cache.
    if not os.path.isdir(os.path.join(CLIENT_DIR, ".godot")):
        step("importing Godot project")
        subprocess.run(["godot", "--headless", "--path", CLIENT_DIR, "--import"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    host = start_host()
    client = Proc("client", [
        "godot", "--headless", "--xr-mode", "off", "--path", CLIENT_DIR, "--",
        "--im2-host=127.0.0.1", "--im2-capture",
        "--im2-monitors=" + ",".join(map(str, MONITORS))])
    procs.append(client)

    step("1/6 connect, stream and decode 3 monitors")
    expect_streaming(client, 0)

    step("2/6 host killed -> client reconnects to a new host")
    mark = client.mark()
    host.stop()
    client.wait_for(r"\[Immersive-2\] Disconnected from host", 10, mark)
    host = start_host()
    expect_streaming(client, mark)

    step("3/6 host frozen -> client times out, then recovers")
    mark = client.mark()
    host.signal(signal.SIGSTOP)
    client.wait_for(r"\[Immersive-2\] Disconnected from host", 20, mark)
    host.signal(signal.SIGCONT)
    expect_streaming(client, mark)

    step("4/6 host sockets use TCP keepalive")
    if shutil.which("ss"):
        out = subprocess.run(["ss", "-tno", "state", "established", "( sport = :19800 )"],
                             capture_output=True, text=True).stdout
        if "keepalive" not in out:
            fail(f"no keepalive timer on the host's client socket:\n{out}")
    else:
        print("      (skipped: `ss` not available)")

    step("5/6 Ctrl+C -> host exits")
    host.signal(signal.SIGINT)
    try:
        host.p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        fail("host still running 5 s after SIGINT")

    errors = [l for l in client.lines if "SCRIPT ERROR" in l]
    if errors:
        fail("client raised script errors:\n" + "\n".join(errors[:10]))
    for p in procs:
        p.stop()
    procs.clear()

    step("6/6 in-VR menu: IP keypad and layout")
    if shutil.which("xvfb-run"):
        menu = Proc("menu", ["xvfb-run", "-a", "godot", "--rendering-driver", "opengl3",
                             "--xr-mode", "off", "--audio-driver", "Dummy", "--path", CLIENT_DIR,
                             "-s", os.path.join(ROOT, "client", "tests", "overlay_test.gd")])
        procs.append(menu)
        menu.wait_for(r"RESULT fails=0", 60)
        menu.stop()
    else:
        print("      (skipped: `xvfb-run` not available)")
    print("\nOK: end-to-end host <-> client checks passed")


if __name__ == "__main__":
    main()
