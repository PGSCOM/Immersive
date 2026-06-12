"""Smoke-test client for the Immersive-2 host (no headset needed).

Run the host on this machine, then:  python host/tools/smoke_client.py

It connects from 127.0.0.2 so the UDP video stream can be received locally
even though the host holds the wildcard bind on the video port.

Exercises: HELLO handshake, MONITOR_LIST, MULTI_MONITOR_SELECT, video frame
reassembly (all selected monitors) and STREAM_STOP on deselection.
"""
import socket
import struct
import sys
import time

HOST = "127.0.0.1"
CLIENT_IP = "127.0.0.2"
TCP_PORT = 19800
UDP_PORT = 19801

MSG_NAMES = {
    0x02: "HELLO_ACK", 0x03: "MONITOR_LIST", 0x05: "STREAM_START",
    0x06: "STREAM_STOP", 0x07: "AUDIO_START", 0x08: "AUDIO_STOP",
    0x41: "LATENCY_RESPONSE", 0xFF: "PING",
}

def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("disconnected")
        buf += chunk
    return buf

def recv_msg(s):
    hdr = recv_exact(s, 5)
    mtype, mlen = struct.unpack("<BI", hdr)
    payload = recv_exact(s, mlen) if mlen else b""
    return mtype, payload

def send_multi_select(s, ids):
    body = bytes([len(ids)]) + bytes((ids + [0xFF, 0xFF, 0xFF])[:3]) + b"\x00"
    s.sendall(struct.pack("<BI", 0x20, len(body)) + body)
    print(f"[client] -> MULTI_MONITOR_SELECT {ids}")

def send_stream_config(s, codec, bitrate_kbps, jpeg_quality, max_width, max_fps):
    body = struct.pack("<BIBHB", codec, bitrate_kbps, jpeg_quality, max_width, max_fps)
    s.sendall(struct.pack("<BI", 0x21, len(body)) + body)
    print(f"[client] -> STREAM_CONFIG codec={codec} br={bitrate_kbps} "
          f"jq={jpeg_quality} maxw={max_width} fps={max_fps}")

def receive_frames(udp, monitors_expected, seconds, min_frames):
    """Reassemble chunked video frames; returns {monitor_id: count}."""
    frames = {}
    complete = {}
    first = {}
    end = time.time() + seconds
    while time.time() < end:
        if all(complete.get(m, 0) >= min_frames for m in monitors_expected):
            break
        try:
            pkt, _ = udp.recvfrom(2048)
        except (TimeoutError, socket.timeout):
            continue
        if len(pkt) < 9:
            continue
        fmon, fnum, cidx, ccnt = struct.unpack_from("<BIHH", pkt, 0)
        chunks = frames.setdefault((fmon, fnum), {})
        chunks[cidx] = pkt[9:]
        if len(chunks) == ccnt:
            data = b"".join(chunks[i] for i in range(ccnt))
            if fmon not in first:
                first[fmon] = data[:4]
            complete[fmon] = complete.get(fmon, 0) + 1
            del frames[(fmon, fnum)]
    for mon, cnt in sorted(complete.items()):
        print(f"[client] monitor {mon}: {cnt} complete frames, "
              f"first bytes {first[mon].hex()}")
    return complete

def main():
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind((CLIENT_IP, UDP_PORT))
    udp.settimeout(0.5)

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind((CLIENT_IP, 0))
    s.settimeout(5)
    s.connect((HOST, TCP_PORT))
    print("[client] TCP connected")

    name = b"SmokeTest".ljust(32, b"\x00")
    s.sendall(struct.pack("<BI", 0x01, 33) + bytes([1]) + name)

    # --- Wait for the monitor list ---
    monitor_ids = []
    deadline = time.time() + 5
    while time.time() < deadline and not monitor_ids:
        mtype, payload = recv_msg(s)
        print(f"[client] <- {MSG_NAMES.get(mtype, hex(mtype))} ({len(payload)} bytes)")
        if mtype == 0x03 and payload:  # MONITOR_LIST
            count = payload[0]
            off = 1
            for _ in range(count):
                mon_id, w, h, rr = struct.unpack_from("<BHHB", payload, off)
                nm = payload[off+6:off+70].split(b"\x00")[0].decode("utf-8", "replace")
                print(f"[client]    monitor {mon_id}: {w}x{h}@{rr} {nm}")
                monitor_ids.append(mon_id)
                off += 70

    if not monitor_ids:
        print("[client] FAIL: never received MONITOR_LIST")
        sys.exit(1)

    # --- Select up to 3 monitors at once ---
    selection = monitor_ids[:3]
    send_multi_select(s, selection)

    # Collect STREAM_START messages for each selected monitor
    started = set()
    deadline = time.time() + 5
    s.settimeout(0.5)
    while time.time() < deadline and len(started) < len(selection):
        try:
            mtype, payload = recv_msg(s)
        except (TimeoutError, socket.timeout):
            continue
        if mtype == 0x05:
            mon_id, w, h, codec = struct.unpack("<BHHB", payload)
            print(f"[client] <- STREAM_START monitor={mon_id} {w}x{h} codec={codec}")
            started.add(mon_id)

    if started != set(selection):
        print(f"[client] FAIL: expected streams {selection}, got {sorted(started)}")
        sys.exit(1)

    # --- Receive frames from every selected monitor ---
    counts = receive_frames(udp, selection, seconds=5, min_frames=3)
    missing = [m for m in selection if counts.get(m, 0) == 0]
    if missing:
        print(f"[client] FAIL: no frames from monitors {missing}")
        sys.exit(1)

    # --- Reconfigure: downscale to 960 px wide, 30 fps, JPEG quality 50 ---
    send_stream_config(s, codec=0xFF, bitrate_kbps=0, jpeg_quality=50,
                       max_width=960, max_fps=30)

    # Host restarts streams: expect new STREAM_START with the scaled size
    restarted = {}
    deadline = time.time() + 5
    while time.time() < deadline and len(restarted) < len(selection):
        try:
            mtype, payload = recv_msg(s)
        except (TimeoutError, socket.timeout):
            continue
        if mtype == 0x05:
            mon_id, w, h, codec = struct.unpack("<BHHB", payload)
            print(f"[client] <- STREAM_START (reconfig) monitor={mon_id} {w}x{h} codec={codec}")
            restarted[mon_id] = (w, h)

    if set(restarted) != set(selection):
        print(f"[client] FAIL: reconfig expected restarts for {selection}, got {sorted(restarted)}")
        sys.exit(1)
    for mon, (w, h) in restarted.items():
        if w > 960:
            print(f"[client] FAIL: monitor {mon} not downscaled (width {w})")
            sys.exit(1)

    counts = receive_frames(udp, selection, seconds=5, min_frames=3)
    if any(counts.get(m, 0) == 0 for m in selection):
        print("[client] FAIL: no frames after reconfiguration")
        sys.exit(1)

    # --- Codec sweep: request each codec, report what the host delivers ---
    CODEC_NAMES = {0: "H.264", 1: "HEVC", 2: "MJPEG", 3: "AV1"}
    for req in (0, 1, 3, 2):
        send_stream_config(s, codec=req, bitrate_kbps=10000, jpeg_quality=50,
                           max_width=960, max_fps=30)
        got = {}
        deadline = time.time() + 6
        while time.time() < deadline and len(got) < len(selection):
            try:
                mtype, payload = recv_msg(s)
            except (TimeoutError, socket.timeout):
                continue
            if mtype == 0x05:
                mon_id, w, h, codec = struct.unpack("<BHHB", payload)
                got[mon_id] = codec
        if set(got) != set(selection):
            print(f"[client] FAIL: codec {CODEC_NAMES[req]}: no restart for all monitors")
            sys.exit(1)
        actual = got[selection[0]]
        counts = receive_frames(udp, selection, seconds=4, min_frames=2)
        if any(counts.get(m, 0) == 0 for m in selection):
            print(f"[client] FAIL: requested {CODEC_NAMES[req]}, "
                  f"got {CODEC_NAMES.get(actual)}, but no frames arrived")
            sys.exit(1)
        note = "" if actual == req else f"  (fallback from {CODEC_NAMES[req]})"
        print(f"[client] codec request {CODEC_NAMES[req]:6} -> "
              f"streams {CODEC_NAMES.get(actual, actual)}{note}")

    # --- Deselect everything and expect STREAM_STOP per monitor ---
    send_multi_select(s, [])
    stopped = set()
    deadline = time.time() + 5
    while time.time() < deadline and len(stopped) < len(selection):
        try:
            mtype, payload = recv_msg(s)
        except (TimeoutError, socket.timeout):
            continue
        if mtype == 0x06:
            mon = payload[0] if payload else -1
            print(f"[client] <- STREAM_STOP monitor={mon}")
            stopped.add(mon)

    if stopped != set(selection):
        print(f"[client] FAIL: expected STREAM_STOP for {selection}, got {sorted(stopped)}")
        sys.exit(1)

    s.close()
    print("[client] OK: handshake, multi-monitor streaming and stop all verified")

if __name__ == "__main__":
    main()
