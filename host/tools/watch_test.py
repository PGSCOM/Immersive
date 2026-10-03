"""Watchers (protocol.h WatchCode): headsets in a multiplayer room watch the
screens another headset streams from this PC, and do nothing else.

    python3 host/tools/watch_test.py [path/to/immersive2_host]

Starts the host with --stub --pin 246810 (IM2_TCP_PORT / IM2_UDP_PORT choose
the ports). The owner (127.0.0.2, with the PIN) streams monitors 0 and 2.
Checks: nobody may watch before WATCH_CODE, a wrong code is refused, the
right one gets HELLO_ACK (view-only), STREAM_START for each live stream and
the frames at the UDP port it asked for: a copy of its own, MJPEG at most
1280 wide, whatever the owner streams in; its selection and input change
nothing; the owner dropping a monitor stops it for the watcher too; a new
code (or 0) drops the watchers, and so does the owner leaving.
"""
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
from smoke_client import (HOST, PIN, TCP_PORT, UDP_PORT, hello, receive_frames,  # noqa: E402
                          recv_msg, send_multi_select, send_stream_config)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OWNER_IP, WATCHER_IP = "127.0.0.2", "127.0.0.3"
WATCH_UDP = UDP_PORT + 7


def fail(msg):
    print(f"[watch] FAIL: {msg}")
    sys.exit(1)


def watch_hello(code, udp_port=WATCH_UDP):
    """HELLO with HELLO_FLAG_WATCH: the code where the PIN goes, then the UDP port."""
    body = (bytes([1]) + b"WatchTest".ljust(32, b"\x00") + bytes([0x02])
            + struct.pack("<IH", code, udp_port))
    return struct.pack("<BI", 0x01, len(body)) + body


def watch_code(s, code):
    s.sendall(struct.pack("<BII", 0x26, 4, code))
    time.sleep(0.3)  # the owner's own handler thread takes it in


def connect(ip, msg):
    s = socket.create_connection((HOST, TCP_PORT), timeout=5, source_address=(ip, 0))
    s.sendall(msg)
    return s


def refused(code, reason, what):
    s = connect(WATCHER_IP, watch_hello(code))
    mtype, payload = recv_msg(s)
    if mtype != 0x09 or payload[:1] != bytes([reason]):
        fail(f"{what}: expected HELLO_REJECT({reason}), got {mtype:#x} {payload[:4].hex()}")
    s.close()
    print(f"[watch] {what}: refused (reason {reason}) OK")


def messages(s, seconds):
    """Every control message for `seconds`: [(type, payload)]."""
    out, end = [], time.time() + seconds
    s.settimeout(0.2)
    while time.time() < end:
        try:
            out.append(recv_msg(s))
        except (TimeoutError, socket.timeout):
            continue
        except ConnectionError:
            out.append((None, b""))
            break
    return out


def closed(s, seconds=3):
    return any(t is None for t, _ in messages(s, seconds))


def join(code, want_streams):
    """A watcher that got in: HELLO_ACK (view-only), then STREAM_START for each live stream."""
    s = connect(WATCHER_IP, watch_hello(code))
    got = messages(s, 2)
    types = [t for t, _ in got]
    if not types or types[0] != 0x02:
        fail(f"watcher: expected HELLO_ACK first, got {[hex(t or 0) for t in types]}")
    ack = got[0][1]
    if len(ack) < 73 or not ack[68] & 0x01:
        fail(f"watcher HELLO_ACK lacks HOST_FLAG_VIEW_ONLY or lan_ipv4: {ack.hex()}")
    starts = [struct.unpack_from("<BHHB", p) for t, p in got if t == 0x05]
    if sorted(s[0] for s in starts) != want_streams:
        fail(f"watcher got STREAM_START for {starts}, expected monitors {want_streams}")
    if any(codec != 2 or w > 1280 for _, w, _, codec in starts):
        fail(f"a watcher's stream must be MJPEG at most 1280 wide: {starts}")
    if any(t in (0x03, 0x07) for t in types):
        fail("a watcher must not get the monitor list or the PC's sound")
    return s


def main():
    exe = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "host", "build", "immersive2_host")
    log = tempfile.TemporaryFile("w+")
    host = subprocess.Popen([exe, "--stub", "--no-usb", "--no-ui", "--pin", str(PIN),
                             "--tcp-port", str(TCP_PORT), "--udp-port", str(UDP_PORT),
                             "--audio-port", str(UDP_PORT + 1)],
                            stdout=log, stderr=subprocess.STDOUT)
    try:
        time.sleep(1.0)
        run()
        time.sleep(0.5)
    finally:
        host.terminate()  # also flushes its (block-buffered) log
        host.wait(timeout=5)
    log.seek(0)
    text = log.read()
    if "[StubInput]" in text:
        fail("a watcher's input reached the injector:\n" + text[-2000:])
    print("[watch] OK: code checked, frames fanned out, watchers only watch and are dropped with the share")


def run():
    owner_udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    owner_udp.bind((OWNER_IP, UDP_PORT))
    watch_udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    watch_udp.bind((WATCHER_IP, WATCH_UDP))
    watch_udp.settimeout(0.5)

    owner = connect(OWNER_IP, hello("Owner", pin=PIN))
    mtype, ack = recv_msg(owner)
    if mtype != 0x02 or len(ack) < 73:
        fail(f"owner: HELLO_ACK without lan_ipv4 ({mtype:#x}, {len(ack)} bytes)")
    send_stream_config(owner, 0, 4000, 0, 0, 0)  # the owner on H.264 (where the PC can)
    send_multi_select(owner, [0, 2])
    starts = [struct.unpack_from("<BHHB", p) for t, p in messages(owner, 3) if t == 0x05]
    if sorted(s[0] for s in starts) != [0, 2]:
        fail(f"owner: STREAM_START for {starts}")
    print(f"[watch] the owner streams codec {starts[0][3]} (0 = H.264, 2 = MJPEG)")

    refused(0x5EC12E7, 1, "watching before anyone shares")
    watch_code(owner, 0x5EC12E7)
    refused(0x5EC12E8, 2, "wrong watch code")

    w = join(0x5EC12E7, [0, 2])
    got = receive_frames(watch_udp, [0, 2], 8, 3)
    if any(got.get(m, 0) < 3 for m in (0, 2)):
        fail(f"watcher frames: {got}")
    print("[watch] watcher gets both screens in MJPEG at its own UDP port OK")

    # Its requests change nothing: the owner keeps both streams.
    send_multi_select(w, [1])
    w.sendall(struct.pack("<BIBHHBhh", 0x10, 10, 0, 100, 50, 1, 0, 0))  # left button down
    w.sendall(struct.pack("<BIBHBB", 0x11, 5, 0, 0x41, 1, 0))           # 'A' down
    w.sendall(struct.pack("<BII", 0x26, 4, 1))                          # its own WATCH_CODE
    if any(t in (0x05, 0x06) for t, _ in messages(owner, 1.5)):
        fail("a watcher's MULTI_MONITOR_SELECT restarted the owner's streams")
    w.sendall(struct.pack("<BIB", 0x31, 1, 0))  # REQUEST_KEYFRAME: allowed
    if closed(w, 1):
        fail("the watcher was dropped by its own requests")

    send_multi_select(owner, [0])
    stops = [p[0] for t, p in messages(w, 3) if t == 0x06]
    if stops != [2]:
        fail(f"watcher: STREAM_STOP for {stops} after the owner dropped monitor 2")
    print("[watch] watcher follows the owner's selection and cannot change it OK")

    watch_code(owner, 0)
    if not closed(w):
        fail("the watcher stayed after the owner stopped sharing")
    refused(0x5EC12E7, 1, "the old code after the share stopped")

    watch_code(owner, 0xABCDEF)
    w = join(0xABCDEF, [0])
    owner.close()
    if not closed(w, 5):
        fail("the watcher stayed after its owner left")
    print("[watch] watchers dropped when the share stops and when the owner leaves OK")


if __name__ == "__main__":
    main()
