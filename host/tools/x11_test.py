"""X11 backend test: the real host capturing and driving a private Xvfb.

    python3 host/tools/x11_test.py

Linux only; needs Xvfb, xrandr, xsetroot, xdotool, xev and Python's PIL.
Nothing touches your desktop: everything runs on a throwaway X server.

Builds the host (incremental) and checks, on a 1600x900 screen split into two
RandR monitors (left painted red, right blue):
  1. MONITOR_LIST reports both monitors with their RandR names and sizes.
  2. Each stream decodes to its own monitor's colour (right crop, no mix-up).
  3. A mouse event on monitor 1 lands at monitor 1's origin + (x, y).
  4. Shift+A from the VR keyboard (VK 0x41 + shift bit) types 'A', and two
     wheel notches produce two button-4 clicks.
  5. Virtual screens: a stale IM2-VIRTUAL-* monitor from a killed host is
     cleared at start-up; a new one becomes RandR monitor IM2-VIRTUAL-0 in
     the framebuffer space right of the monitors (the screen is wider than
     them), streams that region, takes the pointer, and goes away on remove;
     one too big for Xvfb's fixed framebuffer is refused (FAILED).
  6. H.264 / HEVC / AV1 (needs ffmpeg) on that real red/blue content, via
     codec_test.check_codecs(): chroma survives the encoder colour pipeline.
"""
import io
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
from smoke_client import (CLIENT_IP, HOST, TCP_PORT, UDP_PORT, recv_msg,  # noqa: E402
                          send_multi_select, vdisplay, wait_for)
import codec_test  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HOST_BIN = os.path.join(ROOT, "host", "build", "immersive2_host")
W, H = 1600, 900
EXTRA = 800  # framebuffer width no monitor covers: room for a virtual screen
procs = []


host_log = None


def fail(msg):
    print(f"[x11] FAIL: {msg}")
    for p in procs:
        p.kill()
    if host_log:
        host_log.seek(0)
        print("[x11] host log (tail):\n" + "".join(host_log.readlines()[-25:]))
    sys.exit(1)


def start_xvfb():
    r, w = os.pipe()
    # -noreset: otherwise the server wipes the RandR monitors and the root
    # background as soon as xrandr/xsetroot disconnect.
    p = subprocess.Popen(["Xvfb", "-displayfd", str(w), "-noreset", "-screen", "0",
                          f"{W + EXTRA}x{H}x24", "-nolisten", "tcp"], pass_fds=[w],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    procs.append(p)
    os.close(w)
    num = os.read(r, 16).decode().strip()
    os.close(r)
    return f":{num}"


def x(env, *cmd, **kw):
    return subprocess.run(cmd, env=env, check=True, capture_output=True, text=True, **kw).stdout


def paint_halves(env):
    """Root background: left half red, right half blue (a 1-px-tall XBM tile)."""
    row = bytes(0xFF if i < (W // 2) // 8 else 0x00 for i in range(W // 8))
    # XReadBitmapFile wants the data on its own short lines.
    xbm = (f"#define t_width {W}\n#define t_height 1\nstatic char t_bits[] = {{\n"
           + ",\n".join(f"0x{b:02x}" for b in row) + "};\n")
    with tempfile.NamedTemporaryFile("w", suffix=".xbm", delete=False) as f:
        f.write(xbm)
    x(env, "xsetroot", "-bitmap", f.name, "-fg", "#ff0000", "-bg", "#0000ff")
    os.unlink(f.name)


def recv_frames(udp, want, seconds):
    """First fully reassembled JPEG per monitor."""
    chunks, out = {}, {}
    end = time.time() + seconds
    while time.time() < end and len(out) < len(want):
        try:
            pkt, _ = udp.recvfrom(2048)
        except socket.timeout:
            continue
        mon, num, idx, cnt = struct.unpack_from("<BIHH", pkt, 0)
        c = chunks.setdefault((mon, num), {})
        c[idx] = pkt[9:]
        if len(c) == cnt and mon in want and mon not in out:
            out[mon] = b"".join(c[i] for i in range(cnt))
    return out


def main():
    try:
        run()
    finally:
        for p in procs:
            p.kill()


def run():
    for tool in ("Xvfb", "xrandr", "xsetroot", "xdotool", "xev"):
        if not shutil.which(tool):
            print(f"[x11] SKIP: {tool} not installed")
            return
    try:
        from PIL import Image
    except ImportError:
        print("[x11] SKIP: Python PIL not installed")
        return

    subprocess.run(["cmake", "--build", os.path.join(ROOT, "host", "build"), "-j"],
                   check=True, stdout=subprocess.DEVNULL)

    env = {k: v for k, v in os.environ.items() if k != "WAYLAND_DISPLAY"}
    env["DISPLAY"] = start_xvfb()
    env["XDG_SESSION_TYPE"] = "x11"
    x(env, "xrandr", "--setmonitor", "LEFT", f"{W//2}/200x{H}/200+0+0", "screen")
    x(env, "xrandr", "--setmonitor", "RIGHT", f"{W//2}/200x{H}/200+{W//2}+0", "none")
    # Left behind by a host that was killed: the next host must clear it.
    x(env, "xrandr", "--setmonitor", "IM2-VIRTUAL-2", f"200/50x200/50+{W}+0", "none")
    paint_halves(env)
    xev = subprocess.Popen(["stdbuf", "-oL", "xev", "-root", "-event", "keyboard",
                            "-event", "button"], env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True)
    procs.append(xev)

    global host_log
    host_log = tempfile.TemporaryFile("w+")
    host = subprocess.Popen(["stdbuf", "-oL", HOST_BIN, "--no-audio", "--no-usb", "--no-pin",
                             "--tcp-port", str(TCP_PORT), "--udp-port", str(UDP_PORT)], env=env,
                            stdout=host_log, stderr=subprocess.STDOUT)
    procs.append(host)
    time.sleep(1.0)

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind((CLIENT_IP, UDP_PORT))
    udp.settimeout(0.5)
    s = socket.create_connection((HOST, TCP_PORT), timeout=5, source_address=(CLIENT_IP, 0))
    s.sendall(struct.pack("<BI", 0x01, 33) + bytes([1]) + b"X11Test".ljust(32, b"\0"))

    # 1. Monitor list
    monitors = {}
    end = time.time() + 5
    while time.time() < end and not monitors:
        mtype, payload = recv_msg(s)
        if mtype == 0x03:
            for i in range(payload[0]):
                off = 1 + i * 70
                mid, w, h, _ = struct.unpack_from("<BHHB", payload, off)
                monitors[mid] = (w, h, payload[off + 6:off + 70].split(b"\0")[0].decode())
    print(f"[x11] monitors: {monitors}")
    if monitors != {0: (W // 2, H, "LEFT"), 1: (W // 2, H, "RIGHT")}:
        fail("expected LEFT and RIGHT 800x900 RandR monitors")

    # 2. Each stream shows its own half of the root window
    send_multi_select(s, [0, 1])
    frames = recv_frames(udp, [0, 1], 10)
    for mid, want in ((0, (255, 0, 0)), (1, (0, 0, 255))):
        if mid not in frames:
            fail(f"no frame from monitor {mid}")
        img = Image.open(io.BytesIO(frames[mid])).convert("RGB")
        got = img.getpixel((img.width * 3 // 4, img.height // 2))
        print(f"[x11] monitor {mid}: {img.size} pixel {got}")
        if img.size != (W // 2, H) or any(abs(a - b) > 40 for a, b in zip(got, want)):
            fail(f"monitor {mid} expected {want}, got {got}")

    # 3. Mouse lands on the right monitor, offset by its origin
    s.sendall(struct.pack("<BIBHHBhh", 0x10, 10, 1, 100, 50, 0, 0, 0))
    time.sleep(0.3)
    loc = x(env, "xdotool", "getmouselocation")
    print(f"[x11] pointer: {loc.strip()}")
    if not loc.startswith(f"x:{W // 2 + 100} y:50 "):
        fail("pointer did not land at monitor 1 origin + (100, 50)")

    # 4. Shift+A and two wheel notches
    for pressed in (1, 0):
        s.sendall(struct.pack("<BIBHBB", 0x11, 5, 1, 0x41, pressed, 0x01))
    s.sendall(struct.pack("<BIBHHBhh", 0x10, 10, 1, 100, 50, 0, 240, 0))
    time.sleep(0.5)
    xev.terminate()
    log = xev.communicate(timeout=5)[0]
    if "keysym 0x41, A)" not in log:
        fail("Shift+A did not type 'A':\n" + log)
    if log.count("button 4,") != 4:  # press + release per notch
        fail("expected two button-4 clicks for 240 wheel units")

    # 5. A virtual screen right of the monitors
    if "IM2-VIRTUAL" in x(env, "xrandr", "--listmonitors"):
        fail("the stale IM2-VIRTUAL-2 monitor was not cleared at start-up")
    status, _, vid, mons = vdisplay(s, create=(640, 480))
    print(f"[x11] virtual screen: status {status} id {vid} list {mons}")
    if status != 0 or vid != 100 or (100, 640, 480, "Virtual screen 1", 1) not in mons:
        fail("could not create a 640x480 virtual screen 100")
    if f"640/" not in x(env, "xrandr", "--listmonitors"):
        fail("no IM2-VIRTUAL RandR monitor")
    send_multi_select(s, [vid])
    frames = recv_frames(udp, [vid], 10)
    if vid not in frames:
        fail("no frame from the virtual screen")
    img = Image.open(io.BytesIO(frames[vid])).convert("RGB")
    got = img.getpixel((img.width // 2, img.height // 2))
    # x = W + 320 falls in the red half of the tiled root background.
    print(f"[x11] virtual screen frame {img.size} pixel {got}")
    if img.size != (640, 480) or any(abs(a - b) > 40 for a, b in zip(got, (255, 0, 0))):
        fail(f"virtual screen shows {got}, expected the red root tile at x={W + 320}")
    s.sendall(struct.pack("<BIBHHBhh", 0x10, 10, vid, 100, 50, 0, 0, 0))
    time.sleep(0.3)
    loc = x(env, "xdotool", "getmouselocation")
    if not loc.startswith(f"x:{W + 100} y:50 "):
        fail(f"pointer on the virtual screen: {loc.strip()}")
    status, _, _, mons = vdisplay(s, remove=vid, also=[0x06])
    if status != 0 or any(m[0] == vid for m in mons) or "IM2-VIRTUAL" in x(env, "xrandr", "--listmonitors"):
        fail("removing the virtual screen left it behind")
    if vdisplay(s, create=(2000, 1000))[0] != 2:
        fail("a virtual screen beyond Xvfb's fixed framebuffer should fail (2)")
    print("[x11] virtual screen: created, streamed, pointer, removed; oversize refused")
    send_multi_select(s, [0, 1])  # back to the two monitors for the codec check

    # 6. Inter-frame codecs, decoded for real
    if shutil.which("ffmpeg"):
        codec_test.fail = fail  # clean up Xvfb on failure too
        codec_test.check_codecs(s, udp, {0: (255, 0, 0), 1: (0, 0, 255)},
                                {0: (640, 720), 1: (640, 720)})
        host_log.seek(0)
        for line in host_log:
            if "Encoder]" in line:
                print("[x11]   host: " + line.strip())
    else:
        print("[x11] (ffmpeg not installed: H.264/HEVC/AV1 check skipped)")

    s.close()
    host.terminate()
    if host.wait(timeout=5) != 0:
        fail("host did not exit cleanly")
    print("[x11] OK: RandR monitors, per-monitor capture, mouse, keyboard, wheel, "
          "virtual screens, codecs")


if __name__ == "__main__":
    main()
