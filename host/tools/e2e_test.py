"""End-to-end test: the real host (portable build) + the real Godot client.

    python3 host/tools/e2e_test.py

No headset needed. Ports: IM2_TCP_PORT / IM2_UDP_PORT (default 19800 / 19801;
audio on UDP + 1), so it can run beside a host already using the defaults. Builds host/build/immersive2_host with cmake (incremental),
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
  6. Automatic USB: a client streaming over the LAN moves to the cable when
     it appears (a local forwarder stands in for `adb reverse`), back to the
     LAN when the cable is pulled, and to the cable again when replugged.
  7. LAN discovery finds the host (client/tests/discovery_test.gd), and PIN
     pairing: over the PC's LAN address the client is refused without the
     PIN (and stops retrying), and streams with it.
  8. A virtual screen asked for from the headset streams.
  9. Multiplayer: a second PC (host) and two clients in one room. A wrong
     room PIN is refused; each sees the other's avatar (poses) and hears the
     other's voice (a test tone), each watches the screens the other shares,
     straight from the other's PC (protocol.h WatchCode, an MJPEG copy): the
     right greys; Ben sees Ana's whiteboard with her line on it, and draws on
     it (she lets whoever joins): his line lands on hers. Leaving shows on the
     other side.
  10. Ctrl+C on the host exits promptly.
  11. The in-VR menu works with pointer clicks (keypads, PIN, tabs, layout,
     the Room tab), via client/tests/overlay_test.gd. Needs xvfb-run;
     skipped without it.
  12. Headless unit checks: hand tracking (a pinch clicks where the hand
     points), controllers (clicks, grip right-click vs grab, idle hiding),
     curved-screen ray hits, grabbing and the VR keyboard, the video FEC
     (lost UDP chunks rebuilt from parity, client/tests/fec_test.gd) and the
     room's pose/voice packets and seats (client/tests/room_test.gd).
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
TCP_PORT = int(os.environ.get("IM2_TCP_PORT", 19800))
UDP_PORT = int(os.environ.get("IM2_UDP_PORT", 19801))
# The client, headless, pointed at this run's ports.
CLIENT = ["godot", "--headless", "--xr-mode", "off", "--path", CLIENT_DIR, "--",
          f"--im2-port={TCP_PORT}", f"--im2-udp-port={UDP_PORT}"]


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


class Tunnel:
    """Stands in for `adb reverse`: 127.0.0.1:<port> forwards to the host's
    TCP port, and stop() drops every connection, as pulling the cable
    does."""

    def __init__(self, port):
        self.srv = socket.socket()
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", port))
        self.srv.listen(8)
        self.conns = []
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                c, _ = self.srv.accept()
                u = socket.create_connection(("127.0.0.1", TCP_PORT))
            except OSError:
                return
            self.conns += [c, u]
            for a, b in ((c, u), (u, c)):
                threading.Thread(target=self._pipe, args=(a, b), daemon=True).start()

    @staticmethod
    def _pipe(a, b):
        try:
            while True:
                d = a.recv(65536)
                if not d:
                    break
                b.sendall(d)
        except OSError:
            pass
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def stop(self):
        for s in [self.srv] + self.conns:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()


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


def start_host(name="host", tcp=TCP_PORT, udp=UDP_PORT):
    # stdbuf: the host's stdout is block-buffered into a pipe otherwise.
    # --no-usb: USB is simulated here (Tunnel); leave real headsets alone.
    host = Proc(name, ["stdbuf", "-oL", HOST_BIN, "--stub", "--no-ui", "--pin", PIN, "--no-usb",
                       "--tcp-port", str(tcp), "--udp-port", str(udp),
                       "--audio-port", str(udp + 1)])
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


def expect_shade(client, mid, want, since, peer=None):
    """Monitor `mid`'s panel shows grey `want` within 20 s (the one `peer`
    shares in a room, if given)."""
    rx = re.compile((rf"remote panel peer={peer} " if peer else "panel ") + rf"mon={mid} \d+x\d+ center=(\w{{6}})")
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
    fail(f"monitor {mid} panel{' of ' + peer if peer else ''} shows #{seen}, expected grey {want}")


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
        *CLIENT,
        "--im2-host=127.0.0.1", "--im2-capture",
        "--im2-monitors=" + ",".join(map(str, MONITORS))])
    procs.append(client)

    step("1/12 connect, stream and decode 3 monitors")
    expect_streaming(client, 0)

    step("2/12 host killed -> client reconnects to a new host")
    mark = client.mark()
    host.stop()
    client.wait_for(r"\[Immersive-2\] Disconnected from host", 10, mark)
    host = start_host()
    expect_streaming(client, mark)

    step("3/12 host frozen -> client times out, then recovers")
    mark = client.mark()
    host.signal(signal.SIGSTOP)
    client.wait_for(r"\[Immersive-2\] Disconnected from host", 20, mark)
    host.signal(signal.SIGCONT)
    expect_streaming(client, mark)

    step("4/12 host sockets use TCP keepalive")
    if shutil.which("ss"):
        # ss shows one timer: while a control message waits for its ACK that
        # is the retransmit timer ("on"), so look a few times.
        for _ in range(20):
            out = subprocess.run(["ss", "-tno", "state", "established", f"( sport = :{TCP_PORT} )"],
                                 capture_output=True, text=True).stdout
            if "keepalive" in out:
                break
            time.sleep(0.1)
        else:
            fail(f"no keepalive timer on the host's client socket:\n{out}")
    else:
        print("      (skipped: `ss` not available)")

    step("5/12 USB mode: video over the TCP control socket")
    # Same thing a headset on a cable does through `adb reverse`.
    client.stop()
    procs.remove(client)
    mark = host.mark()
    usb = Proc("client-usb", [
        *CLIENT,
        "--im2-host=127.0.0.1", "--im2-usb", "--im2-capture",
        "--im2-monitors=" + ",".join(map(str, MONITORS))])
    procs.append(usb)
    host.wait_for(r"says hello: .*\(video/audio over TCP\)", 20, mark)
    expect_streaming(usb, 0)
    client_lines = client.lines + usb.lines

    step("6/12 automatic USB: cable found, pulled and plugged back in")
    usb.stop()
    procs.remove(usb)
    lan = lan_ip()
    if lan:
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            usb_port = s.getsockname()[1]
        auto = Proc("client-auto", [
            *CLIENT,
            "--im2-host=" + lan, "--im2-pin=" + PIN, "--im2-usb-port=" + str(usb_port),
            "--im2-capture", "--im2-monitors=" + ",".join(map(str, MONITORS))])
        procs.append(auto)
        expect_streaming(auto, 0)  # over the LAN: no cable yet
        # (The probe's own HELLO says "USB check"; the real one does not.)
        real_usb_hello = r"says hello: (?!.*USB check).*\(video/audio over TCP\)"
        mark, hmark = auto.mark(), host.mark()
        tunnel = Tunnel(usb_port)
        auto.wait_for(r"USB: the PC answers through the cable", 10, mark)
        host.wait_for(real_usb_hello, 10, hmark)
        expect_streaming(auto, mark)
        mark, hmark = auto.mark(), host.mark()
        pulled = time.time()
        tunnel.stop()
        auto.wait_for(r"USB link lost, back to Wi-Fi", 10, mark)
        host.wait_for(r"says hello: (?!.*USB check)(?!.*over TCP)", 10, hmark)
        print(f"      back on the LAN {time.time() - pulled:.1f} s after the cable was pulled")
        expect_streaming(auto, mark)
        mark, hmark = auto.mark(), host.mark()
        tunnel = Tunnel(usb_port)
        host.wait_for(real_usb_hello, 15, hmark)
        expect_streaming(auto, mark)
        tunnel.stop()
        auto.stop()
        procs.remove(auto)
        client_lines += auto.lines
    else:
        print("      (skipped: this machine has no LAN address)")

    step("7/12 LAN discovery and PIN pairing")
    run_godot_test("discovery_test.gd")
    if lan:
        mark = host.mark()
        nopin = Proc("client-nopin", [
            *CLIENT,
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
            *CLIENT,
            "--im2-host=" + lan, "--im2-pin=" + PIN, "--im2-capture",
            "--im2-monitors=" + ",".join(map(str, MONITORS))])
        procs.append(paired)
        expect_streaming(paired, 0)
        client_lines += nopin.lines + paired.lines
    else:
        print("      (PIN over the network skipped: this machine has no LAN address)")

    step("8/12 a virtual screen asked for from the headset")
    for p in procs:
        if p is not host:
            p.stop()
    mark = host.mark()
    virt = Proc("client-virtual", [
        *CLIENT,
        "--im2-host=127.0.0.1", "--im2-capture", "--im2-monitors=0",
        "--im2-virtual=1280x720"])
    procs.append(virt)
    host.wait_for(r"asked for a 1280x720 virtual screen: monitor 100", 20, mark)
    virt.wait_for(r"Streaming monitor 100 ", 20)
    expect_shade(virt, 100, 208, 0)  # the --stub virtual screens' grey
    client_lines += virt.lines

    step("9/12 multiplayer room: avatars, voice, each PC's screens shared")
    virt.stop()
    procs.remove(virt)
    if lan:
        client_lines += multiplayer(host)
    else:
        print("      (skipped: this machine has no LAN address, which watching another PC needs)")

    step("10/12 Ctrl+C -> host exits")
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

    step("11/12 in-VR menu: keypads, PIN, tabs, layout and the Room tab")
    if shutil.which("xvfb-run"):
        menu = Proc("menu", ["xvfb-run", "-a", "godot", "--rendering-driver", "opengl3",
                             "--xr-mode", "off", "--audio-driver", "Dummy", "--path", CLIENT_DIR,
                             "-s", os.path.join(ROOT, "client", "tests", "overlay_test.gd")])
        procs.append(menu)
        menu.wait_for(r"RESULT fails=0", 60)
        menu.stop()
    else:
        print("      (skipped: `xvfb-run` not available)")

    step("12/12 hand tracking, controllers, screens, keyboard and whiteboard, video FEC, room packets")
    for test in ("hand_input_test.gd", "controller_idle_test.gd", "workspace_test.gd",
                 "groups_test.gd", "virtual_match_test.gd", "whiteboard_test.gd", "fec_test.gd",
                 "room_test.gd"):
        run_godot_test(test)
    print("\nOK: end-to-end host <-> client checks passed")


def multiplayer(host):
    """Ana (on `host`) opens a room and shares monitors 0 and 1; Ben, on a
    second PC, joins with the room's PIN and shares monitor 2."""
    tcp2, udp2, room_port, room_pin = TCP_PORT + 20, UDP_PORT + 20, TCP_PORT + 40, "135790"
    host2 = start_host("host2", tcp2, udp2)
    room = [f"--im2-room-port={room_port}", "--im2-capture"]
    ana = Proc("ana", [*CLIENT, "--im2-host=127.0.0.1", "--im2-monitors=0,1", "--im2-name=Ana",
                       "--im2-room=open", f"--im2-room-pin={room_pin}", "--im2-share", "--im2-tone",
                       "--im2-board", "--im2-board-open", *room])
    procs.append(ana)
    ana.wait_for(r"\[Room\] opened on UDP", 20)
    eve = Proc("eve", [*CLIENT, "--im2-name=Eve", "--im2-room=127.0.0.1", "--im2-room-pin=111111", *room])
    procs.append(eve)
    eve.wait_for(r"Wrong PIN for the room", 20)
    ana.wait_for(r"gave a wrong PIN", 5)
    eve.stop()
    procs.remove(eve)
    ben = Proc("ben", [*CLIENT, f"--im2-port={tcp2}", f"--im2-udp-port={udp2}", "--im2-host=127.0.0.1",
                       "--im2-monitors=2", "--im2-name=Ben", "--im2-room=127.0.0.1",
                       f"--im2-room-pin={room_pin}", "--im2-share", "--im2-draw-remote", *room])
    procs.append(ben)
    ben.wait_for(r"room peer=Ana poses=[1-9]\d* voice=[1-9]", 30)
    ana.wait_for(r"room peer=Ben poses=[1-9]", 30)
    print("      each sees the other's avatar, Ben hears Ana")
    expect_shade(ben, 0, 64, 0, "Ana")
    expect_shade(ben, 1, 112, 0, "Ana")
    expect_shade(ana, 2, 160, 0, "Ben")
    host.wait_for(r"watches client \d+'s screens", 5)
    host2.wait_for(r"watches client \d+'s screens", 5)
    print("      each watches the other's screens, straight from the other's PC")
    ben.wait_for(r"remote board peer=Ana shown=true strokes=[1-9]", 20)
    print("      Ben sees Ana's whiteboard and what she drew on it")
    ana.wait_for(r"my board strokes=2", 20)
    ben.wait_for(r"remote board peer=Ana shown=true strokes=2", 20)
    print("      Ana let Ben draw on her board: his line is on hers, and on his copy")
    mark = ana.mark()
    ben.signal(signal.SIGINT)  # quits cleanly: leaves the room
    ana.wait_for(r"\[Room\] Ben left", 40, mark)
    lines = ana.lines + ben.lines + eve.lines
    for p in (ana, ben, host2):
        p.stop()
        procs.remove(p)
    return lines


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
