"""Inter-frame codec test: H.264 / HEVC / AV1 from the host, decoded for real.

    python3 host/tools/codec_test.py [path/to/immersive2_host]

Any OS; needs `ffmpeg` on PATH. Starts the host with --stub (three solid-grey
fake monitors) and, for each codec: the host streams it or announces the
H.264 fallback, downscaled to 640 px wide by the encoder; a keyframe asked
for mid-stream (REQUEST_KEYFRAME) arrives within a few frames, carries its
parameter sets and decodes on its own — what a headset joining late or
recovering from Wi-Fi loss relies on — to the right grey on every monitor.
A still screen gets P-frames after that keyframe (refining it), and then no
keyframe arrives that nobody asked for (no periodic or keepalive IDR). Last,
a 7680x2160 virtual screen: H.264 carries it at 4096x1152, HEVC whole.
host/tools/x11_test.py reuses check_codecs() on real red/blue X11 content.
"""
import os
import shutil
import socket
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from smoke_client import (CLIENT_IP, HOST, TCP_PORT, UDP_PORT, recv_msg,  # noqa: E402
                          send_multi_select, send_stream_config, vdisplay)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def fail(msg):
    print(f"[codec] FAIL: {msg}")
    sys.exit(1)


def is_keyframe(codec, data):
    """IDR with in-band parameter sets, per the encoder contract."""
    if codec == 3:  # AV1: a sequence header OBU (type 1) somewhere in the TU
        i = 0
        while i < len(data):
            h = data[i]
            i += 1 + ((h >> 2) & 1)
            size = shift = 0
            while True:
                b = data[i]
                i += 1
                size |= (b & 0x7F) << shift
                shift += 7
                if not b & 0x80:
                    break
            if (h >> 3) & 0xF == 1:
                return True
            i += size
        return False
    nal = [data[m + 3] for m in range(len(data) - 3) if data[m:m + 3] == b"\0\0\1"]
    if codec == 0:
        types = {n & 0x1F for n in nal}
        return {5, 7, 8} <= types
    types = {(n >> 1) & 0x3F for n in nal}
    return {32, 33, 34} <= types and bool(types & {19, 20})


def drain(s):
    try:
        while True:
            recv_msg(s)
    except socket.timeout:
        pass


def wait_stream_starts(s, ids, timeout=10):
    starts = {}
    end = time.time() + timeout
    while time.time() < end and len(starts) < len(ids):
        try:
            mtype, payload = recv_msg(s)
        except socket.timeout:
            continue
        if mtype == 0x05:
            mid, w, h, codec = struct.unpack_from("<BHHB", payload)
            starts[mid] = (w, h, codec)
    return starts


def collect(udp, seconds):
    """{monitor: {frame_number: bytes}} of every fully reassembled frame."""
    chunks, out = {}, {}
    end = time.time() + seconds
    while time.time() < end:
        try:
            pkt, _ = udp.recvfrom(2048)
        except socket.timeout:
            continue
        mon, num, idx, cnt = struct.unpack_from("<BIHH", pkt, 0)
        c = chunks.setdefault((mon, num), {})
        c[idx] = pkt[9:]
        if len(c) == cnt:
            out.setdefault(mon, {})[num] = b"".join(c[i] for i in range(cnt))
    return out


def decode_last_pixel(codec, stream, w, h):
    fmt = {0: "h264", 1: "hevc", 3: "obu"}[codec]
    r = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", fmt, "-i", "pipe:",
                        "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:"],
                       input=stream, capture_output=True)
    if r.returncode != 0:
        fail(f"ffmpeg could not decode the {fmt} stream (starts {stream[:8].hex()}): "
             + r.stderr.decode(errors="replace")[-500:])
    raw = r.stdout
    n = len(raw) // (w * h * 3)
    if n == 0:
        return None, 0
    last = raw[(n - 1) * w * h * 3:]
    off = ((h // 2) * w + w * 3 // 4) * 3
    return tuple(last[off:off + 3]), n


def check_codecs(s, udp, want_rgb, sizes):
    """want_rgb: {monitor: (r, g, b)} streamed; sizes: {monitor: (w, h)} expected
    after the 640-px downscale. Every codec must decode to those colours."""
    ids = sorted(want_rgb)
    s.settimeout(0.5)
    for req, label in ((0, "H.264"), (1, "HEVC"), (3, "AV1")):
        drain(s)  # earlier STREAM_STARTs still queued on the socket
        # 1 Mbps: the host's floor, so the adaptive rate never changes it (on
        # VAAPI each change is a re-open, whose IDR the checks below would see).
        send_stream_config(s, req, 1000, 0, 640, 30)
        starts = wait_stream_starts(s, ids)
        if set(starts) != set(ids):
            fail(f"{label}: no STREAM_START for every monitor: {starts}")
        codec = starts[ids[0]][2]
        if (any(starts[m][:2] != sizes[m] or starts[m][2] != codec for m in ids)
                or codec not in (req, 0)):
            fail(f"{label}: unexpected STREAM_START {starts}")
        if req == 0 and codec != 0:
            fail("H.264 requested but not delivered: host built without a hardware encoder?")
        collect(udp, 0.5)  # let the stream settle
        for mid in ids:
            s.sendall(struct.pack("<BIB", 0x31, 1, mid))  # REQUEST_KEYFRAME
        frames = collect(udp, 1.5)
        for mid, want in want_rgb.items():
            w, h = sizes[mid]
            nums = sorted(frames.get(mid, {}))
            keys = [n for n in nums if is_keyframe(codec, frames[mid][n])]
            if not keys or keys[0] - nums[0] > 6:
                fail(f"{label}: monitor {mid}: no keyframe with parameter sets soon "
                     f"after REQUEST_KEYFRAME (frames {nums[:3]}.., keys {keys})")
            # Decode starting AT that keyframe only, like a late joiner.
            tail = [n for n in nums if n >= keys[0]]
            if tail != list(range(keys[0], keys[0] + len(tail))):
                fail(f"{label}: gap in received frames {tail}")
            pix, n = decode_last_pixel(codec, b"".join(frames[mid][k] for k in tail), w, h)
            print(f"[codec] {label} -> codec {codec} monitor {mid}: {n} frames decoded "
                  f"from keyframe #{keys[0]}, pixel {pix}")
            if n < len(tail) or any(abs(a - b) > 40 for a, b in zip(pix, want)):
                fail(f"{label}: monitor {mid} decoded {n}/{len(tail)} frames, "
                     f"pixel {pix}, expected {want}")
            # A still screen (the stub's monitors 0-1 send one frame, then
            # nothing) is refined after that IDR with P-frames, not left at
            # the IDR's blurred quality.
            if len(tail) < 10:
                fail(f"{label}: monitor {mid}: {len(tail)} frames after the keyframe, "
                     "a still screen should be refined with P-frames")
        # Then no IDR unless asked: not a periodic one, not the 1 s keepalive
        # of a still screen (each would blur its text again).
        quiet = collect(udp, 2.5)
        for mid in ids:
            got = quiet.get(mid, {})
            keys = [n for n in sorted(got) if is_keyframe(codec, got[n])]
            if not got or keys:
                fail(f"{label}: monitor {mid}: {len(got)} frames, keyframes {keys} "
                     "in 2.5 s nobody asked for one")
        print(f"[codec] {label}: still screens refined, then kept alive without IDRs")


def check_big_virtual(s, udp):
    """A 7680x2160 virtual screen (--stub: grey 208) streamed at its own size:
    H.264 scaled into Level 5.2 (4096x1152; VAAPI and the Pico's decoder stop
    at 4096), HEVC whole where the host has it, else that H.264 fallback."""
    status, _, vid, _ = vdisplay(s, create=(7680, 2160))
    if status != 0:
        fail(f"could not make a 7680x2160 virtual screen: status {status}")
    send_multi_select(s, [vid])
    for req, label in ((0, "H.264"), (1, "HEVC")):
        drain(s)
        send_stream_config(s, req, 1000, 0, 0, 30)
        w, h, codec = wait_stream_starts(s, [vid]).get(vid, (0, 0, None))
        if codec not in (req, 0) or (w, h) != ((4096, 1152) if codec == 0 else (7680, 2160)):
            fail(f"{label}: 7680x2160 virtual screen started as {w}x{h} codec {codec}")
        collect(udp, 0.5)
        s.sendall(struct.pack("<BIB", 0x31, 1, vid))  # REQUEST_KEYFRAME
        frames = collect(udp, 1.5).get(vid, {})
        keys = [n for n in sorted(frames) if is_keyframe(codec, frames[n])]
        if not keys:
            fail(f"{label}: no keyframe from the 7680x2160 virtual screen")
        pix, n = decode_last_pixel(codec, frames[keys[0]], w, h)
        print(f"[codec] {label} -> codec {codec}: 7680x2160 virtual screen as {w}x{h}, pixel {pix}")
        if n != 1 or any(abs(a - 208) > 12 for a in pix):
            fail(f"{label}: the big virtual screen decoded to {pix}, expected grey 208")
    vdisplay(s, remove=vid)


def main():
    if not shutil.which("ffmpeg"):
        print("[codec] SKIP: ffmpeg not installed")
        return
    exe = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        ROOT, "host", "build", "immersive2_host")
    host = subprocess.Popen([exe, "--stub", "--no-usb", "--no-ui", "--no-pin",
                             "--tcp-port", str(TCP_PORT), "--udp-port", str(UDP_PORT)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2)
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.bind((CLIENT_IP, UDP_PORT))
        udp.settimeout(0.5)
        s = socket.create_connection((HOST, TCP_PORT), timeout=5,
                                     source_address=(CLIENT_IP, 0))
        s.sendall(struct.pack("<BI", 0x01, 33) + bytes([1]) + b"CodecTest".ljust(32, b"\0"))
        send_multi_select(s, [0, 1, 2])
        # The --stub monitors: 1920x1080, 1920x1200, 1280x720, grey 64 + 48*i.
        grey = {i: (64 + 48 * i,) * 3 for i in range(3)}
        check_codecs(s, udp, grey, {0: (640, 360), 1: (640, 400), 2: (640, 360)})
        check_big_virtual(s, udp)
        s.close()
        print("[codec] OK: every codec decodes from a mid-stream keyframe, colours intact")
    finally:
        host.terminate()
        host.wait(timeout=10)


if __name__ == "__main__":
    main()
