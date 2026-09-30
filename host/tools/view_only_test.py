"""--view-only: the host shares its screens but takes no input.

    python3 host/tools/view_only_test.py [path/to/immersive2_host]

Starts the host with --stub --view-only (IM2_TCP_PORT / IM2_UDP_PORT choose
the ports) and checks that LAN discovery and HELLO_ACK say so, that a stream
still starts, and that mouse and keyboard events never reach the injector.
"""
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
from smoke_client import CLIENT_IP, HOST, TCP_PORT, UDP_PORT, hello, recv_msg, send_multi_select  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def main():
    exe = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "host", "build", "immersive2_host")
    log = tempfile.TemporaryFile("w+")
    host = subprocess.Popen([exe, "--stub", "--no-usb", "--no-pin", "--view-only",
                             "--tcp-port", str(TCP_PORT), "--udp-port", str(UDP_PORT)],
                            stdout=log, stderr=subprocess.STDOUT)
    try:
        run()
        time.sleep(0.5)
    finally:
        host.terminate()  # also flushes its (block-buffered) log
        host.wait(timeout=5)
    log.seek(0)
    text = log.read()
    if "View-only: ignoring" not in text or "[StubInput]" in text:
        fail("input reached the injector:\n" + text[-2000:])
    print("[view-only] OK: advertised in discovery and HELLO_ACK, input ignored")


def fail(msg):
    print(f"[view-only] FAIL: {msg}")
    sys.exit(1)


def run():
    time.sleep(1.0)
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind((CLIENT_IP, 0))
    u.settimeout(2)
    u.sendto(struct.pack("<IB", 0x3F324D49, 1), (HOST, TCP_PORT))
    reply, _ = u.recvfrom(256)
    if not reply[8] & 0x02:
        fail(f"discovery flags {reply[8]} lack DISCOVERY_FLAG_VIEW_ONLY")

    s = socket.create_connection((HOST, TCP_PORT), timeout=5, source_address=(CLIENT_IP, 0))
    s.sendall(hello("ViewOnlyTest"))
    mtype, payload = recv_msg(s)
    if mtype != 0x02 or len(payload) < 69 or not payload[68] & 0x01:
        fail(f"HELLO_ACK lacks HOST_FLAG_VIEW_ONLY: type {mtype:#x}, {payload[:70].hex()}")
    send_multi_select(s, [0])
    end = time.time() + 5
    while time.time() < end:
        if recv_msg(s)[0] == 0x05:
            break
    else:
        fail("no STREAM_START: view-only must still share the screens")
    s.sendall(struct.pack("<BIBHHBhh", 0x10, 10, 0, 100, 50, 1, 0, 0))  # left button down
    s.sendall(struct.pack("<BIBHBB", 0x11, 5, 0, 0x41, 1, 0))           # 'A' down
    s.close()


if __name__ == "__main__":
    main()
