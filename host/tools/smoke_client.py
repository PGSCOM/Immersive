"""Smoke-test client for the Immersive-2 host (no headset needed).

Run the host on this machine with fake displays (`immersive2_host --stub`),
then:  python host/tools/smoke_client.py

It connects from 127.0.0.2 so the UDP video stream can be received locally
even though the host holds the wildcard bind on the video port.

Start the host with the PIN this script sends:  immersive2_host --stub --pin 246810
(IM2_PIN, IM2_TCP_PORT and IM2_UDP_PORT override the defaults.)

Exercises: LAN discovery, PIN pairing (no PIN / wrong PIN refused, nothing
served before HELLO), HELLO handshake (host flags), MONITOR_LIST (with its
per-monitor flags), MULTI_MONITOR_SELECT, video frame reassembly (all
selected monitors), a quality-only STREAM_CONFIG retuning the running streams
(no STREAM_STOP/START), the adaptive rate (stop sending FRAME_ACKs: the rate
falls; resume: it climbs back) and STREAM_STOP on deselection, then virtual displays
(create -> RESULT + new list, stream it, remove -> STREAM_STOP + list, the
limit of 4). Then a second connection from 127.0.0.1 (trusted, like a USB
headset) asks for HELLO_FLAG_TCP_MEDIA (the USB / adb-reverse mode) and checks
every monitor's frames arrive in-band as VIDEO_FRAME messages.
"""
import os
import select
import socket
import struct
import sys
import time

HOST = "127.0.0.1"
CLIENT_IP = "127.0.0.2"
TCP_PORT = int(os.environ.get("IM2_TCP_PORT", "19800"))
UDP_PORT = int(os.environ.get("IM2_UDP_PORT", "19801"))
PIN = int(os.environ.get("IM2_PIN", "246810"))

MSG_NAMES = {
    0x02: "HELLO_ACK", 0x09: "HELLO_REJECT", 0x03: "MONITOR_LIST", 0x05: "STREAM_START",
    0x24: "VIRTUAL_DISPLAY_RESULT",
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

def hello(name, flags=0, pin=0):
    """HELLO message: version, name[32], flags, pin (u32)."""
    body = bytes([1]) + name.encode().ljust(32, b"\x00") + bytes([flags]) + struct.pack("<I", pin)
    return struct.pack("<BI", 0x01, len(body)) + body

def fail(msg):
    print(f"[client] FAIL: {msg}")
    sys.exit(1)

def check_discovery():
    """A DiscoveryRequest to UDP <tcp port> gets a DiscoveryReply back."""
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind((CLIENT_IP, 0))
    u.settimeout(2)
    u.sendto(struct.pack("<IB", 0x3F324D49, 1), (HOST, TCP_PORT))
    try:
        data, _ = u.recvfrom(256)
    except (TimeoutError, socket.timeout):
        fail("no reply to a LAN discovery request")
    magic, ver, port, mons, flags = struct.unpack_from("<IBHBB", data)
    name = data[9:73].split(b"\x00")[0].decode("utf-8", "replace")
    print(f"[client] discovery: {name!r} port={port} monitors={mons} flags={flags}")
    if magic != 0x21324D49 or port != TCP_PORT or mons != 3 or not flags & 1 or not name:
        fail(f"bad discovery reply {data[:16].hex()}")

def expect_reject(hello_msg, want_reason, what):
    s = socket.create_connection((HOST, TCP_PORT), timeout=5, source_address=(CLIENT_IP, 0))
    s.sendall(hello_msg)
    mtype, payload = recv_msg(s)
    if mtype != 0x09 or payload[:1] != bytes([want_reason]):
        fail(f"{what}: expected HELLO_REJECT({want_reason}), got {hex(mtype)} {payload[:4].hex()}")
    try:
        closed = s.recv(1) == b""
    except (ConnectionError, OSError):
        closed = True
    if not closed:
        fail(f"{what}: host kept the connection open after rejecting it")
    s.close()
    print(f"[client] {what}: refused (reason {want_reason}) OK")

def check_pairing():
    expect_reject(hello("NoPin"), 1, "no PIN")
    expect_reject(hello("WrongPin", pin=111111 if PIN != 111111 else 222222), 2, "wrong PIN")
    # Anything before HELLO (here: a monitor select) drops the connection.
    s = socket.create_connection((HOST, TCP_PORT), timeout=5, source_address=(CLIENT_IP, 0))
    s.sendall(struct.pack("<BIB", 0x04, 1, 0))
    try:
        data = s.recv(64)
    except (ConnectionError, OSError):
        data = b""
    if data:
        fail(f"host answered a request sent before HELLO: {data[:8].hex()}")
    s.close()
    print("[client] request before HELLO: dropped OK")

def parse_monitor_list(payload):
    """[(id, w, h, name, flags)]; flags is None from a host without the array."""
    count = payload[0]
    out = []
    flags = payload[1 + count * 70:1 + count * 71]
    for i in range(count):
        off = 1 + i * 70
        mon_id, w, h, _ = struct.unpack_from("<BHHB", payload, off)
        name = payload[off + 6:off + 70].split(b"\x00")[0].decode("utf-8", "replace")
        out.append((mon_id, w, h, name, flags[i] if len(flags) == count else None))
    return out

def wait_for(s, want, seconds=8):
    """Reads messages until every type in `want` arrived; {type: last payload}."""
    got = {}
    end = time.time() + seconds
    while time.time() < end and not set(want) <= set(got):
        try:
            mtype, payload = recv_msg(s)
        except (TimeoutError, socket.timeout):
            continue
        got[mtype] = payload
    missing = [MSG_NAMES.get(t, hex(t)) for t in want if t not in got]
    if missing:
        fail(f"never received {missing}")
    return got

def vdisplay(s, create=None, remove=None, also=()):
    """CREATE (w, h) or REMOVE id, waiting for RESULT and the `also` message
    types too; returns (status, removed, id, monitor list or None)."""
    if create:
        s.sendall(struct.pack("<BIHHB", 0x22, 5, create[0], create[1], 60))
    else:
        s.sendall(struct.pack("<BIB", 0x23, 1, remove))
    got = wait_for(s, [0x24, *also])
    status, removed, mon = struct.unpack("<BBB", got[0x24][:3])
    monitors = None
    if status == 0:
        monitors = parse_monitor_list(wait_for(s, [0x03])[0x03] if 0x03 not in got else got[0x03])
    return status, removed, mon, monitors

def check_virtual_displays(s, udp):
    """--stub virtual displays: create, list, stream, remove, the limit."""
    status, removed, vid, monitors = vdisplay(s, create=(1280, 720))
    print(f"[client] virtual display: status={status} id={vid} list={monitors}")
    if status != 0 or removed != 0 or vid != 100:
        fail(f"CREATE: expected OK with id 100, got status {status} id {vid}")
    entry = [m for m in monitors if m[0] == vid]
    if len(monitors) != 4 or not entry or not entry[0][4] & 0x01 or entry[0][1:3] != (1280, 720):
        fail(f"new monitor list lacks virtual display 100 (flag 0x01, 1280x720): {monitors}")

    send_multi_select(s, [vid])
    starts = wait_for(s, [0x05])
    mon, w, h, codec = struct.unpack_from("<BHHB", starts[0x05])
    if mon != vid:
        fail(f"STREAM_START for {mon}, expected {vid}")
    counts = receive_frames(udp, [vid], seconds=5, min_frames=2)
    if counts.get(vid, 0) == 0:
        fail("no frames from the virtual display")

    # Removing a display that streams stops the stream first (STREAM_STOP).
    status, removed, mon, monitors = vdisplay(s, remove=vid, also=[0x06])
    if status != 0 or removed != 1 or mon != vid or any(m[0] == vid for m in monitors):
        fail(f"REMOVE: status {status} removed {removed} id {mon}, list {monitors}")
    print("[client] virtual display removed, stream stopped")

    made = []
    for _ in range(4):
        status, _, mon, _ = vdisplay(s, create=(1920, 1080))
        if status != 0:
            fail(f"creating virtual display {len(made) + 1} of 4 failed: status {status}")
        made.append(mon)
    status, _, _, _ = vdisplay(s, create=(1920, 1080))
    if status != 3:
        fail(f"a 5th virtual display should be refused with LIMIT (3), got {status}")
    for mon in made:
        if vdisplay(s, remove=mon)[0] != 0:
            fail(f"removing virtual display {mon} failed")
    if vdisplay(s, remove=100)[0] != 2:
        fail("removing a virtual display that is gone should fail (2)")
    print(f"[client] OK: virtual displays {made} made and removed, 5th refused")

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

def measure(udp, s, mon, seconds, ack):
    """Reassemble frames for `seconds`; FRAME_ACK every complete one when
    `ack`. Returns (frames/s, kbit/s) of monitor `mon`. Fails on a
    STREAM_START / STREAM_STOP meanwhile: the stream must go on."""
    frames, n, size = {}, 0, 0
    end = time.time() + seconds
    while time.time() < end:
        readable, _, _ = select.select([udp, s], [], [], 0.1)
        if s in readable:
            mtype, _ = recv_msg(s)
            if mtype in (0x05, 0x06):
                fail(f"a quality-only STREAM_CONFIG restarted the stream ({MSG_NAMES[mtype]})")
        if udp not in readable:
            continue
        pkt, _ = udp.recvfrom(2048)
        if len(pkt) < 9:
            continue
        fmon, fnum, cidx, ccnt = struct.unpack_from("<BIHH", pkt, 0)
        chunks = frames.setdefault((fmon, fnum), {})
        chunks[cidx] = len(pkt) - 9
        if len(chunks) < ccnt:
            continue
        del frames[(fmon, fnum)]
        if ack:
            s.sendall(struct.pack("<BIBI", 0x30, 5, fmon, fnum))
        if fmon == mon:
            n += 1
            size += sum(chunks.values())
    return n / seconds, size * 8 / 1000 / seconds

def check_live_config_and_rate(s, udp, selection):
    """A bitrate / quality / fps-only STREAM_CONFIG retunes the running
    streams (no STREAM_STOP/START), and a client that stops acknowledging
    frames (a stalled link) gets a lower rate, which then climbs back."""
    mon = 2 if 2 in selection else selection[-1]  # the stub's animated monitor
    send_stream_config(s, codec=2, bitrate_kbps=20000, jpeg_quality=90, max_width=960, max_fps=30)
    measure(udp, s, mon, 1, ack=True)
    fps, kbps = measure(udp, s, mon, 2, ack=True)
    print(f"[client] live retune, no restart; acknowledging: {fps:.0f} fps, {kbps:.0f} kbit/s")
    if fps < 5:
        fail("frames stopped after a live retune")

    # Stop acknowledging: to the host the frames pile up unconfirmed. (The
    # stub's flat picture barely shrinks with JPEG quality: this is mostly
    # the frame rate MJPEG also gives up.)
    measure(udp, s, mon, 5, ack=False)
    slow_fps, slow_kbps = measure(udp, s, mon, 2, ack=False)
    print(f"[client] not acknowledging: {slow_fps:.0f} fps, {slow_kbps:.0f} kbit/s")
    if slow_kbps > 0.6 * kbps:
        fail(f"host kept the rate up for a stalled client ({slow_kbps:.0f} of {kbps:.0f} kbit/s)")

    # Acknowledge again: after 4 clean seconds the rate climbs 10 % a second.
    low_fps, low_kbps = measure(udp, s, mon, 1.5, ack=True)
    measure(udp, s, mon, 8, ack=True)
    back_fps, back_kbps = measure(udp, s, mon, 2, ack=True)
    print(f"[client] acknowledging again: {low_fps:.0f} fps, {low_kbps:.0f} kbit/s, "
          f"10 s later {back_fps:.0f} fps, {back_kbps:.0f} kbit/s")
    if back_kbps < 1.3 * low_kbps:
        fail("the rate did not recover once frames were acknowledged again")
    print("[client] OK: live retune without restart, adaptive rate down and back up")

def check_idle_dropped(idle):
    """Sockets that never sent HELLO are closed by the host after ~5 s."""
    for sock in idle:
        sock.settimeout(8)
        try:
            closed = sock.recv(1) == b""
        except (ConnectionError, OSError):
            closed = True
        if not closed:
            fail("host kept an idle never-HELLO connection open")
        sock.close()
    print(f"[client] {len(idle)} idle unpaired sockets: dropped by the host OK")

def main():
    check_discovery()
    check_pairing()
    # More idle, never-HELLO sockets than --max-clients (4): they must not
    # lock the real client out (the limit counts paired clients).
    idle = [socket.create_connection((HOST, TCP_PORT), timeout=5, source_address=(CLIENT_IP, 0))
            for _ in range(5)]
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind((CLIENT_IP, UDP_PORT))
    udp.settimeout(0.5)

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind((CLIENT_IP, 0))
    s.settimeout(5)
    s.connect((HOST, TCP_PORT))
    print("[client] TCP connected")

    s.sendall(hello("SmokeTest", pin=PIN))

    # --- Wait for the monitor list ---
    monitor_ids = []
    deadline = time.time() + 5
    while time.time() < deadline and not monitor_ids:
        mtype, payload = recv_msg(s)
        print(f"[client] <- {MSG_NAMES.get(mtype, hex(mtype))} ({len(payload)} bytes)")
        if mtype == 0x02 and len(payload) >= 68:  # HELLO_ACK with host name
            host_name = payload[4:68].split(b"\x00")[0].decode("utf-8", "replace")
            host_flags = payload[68] if len(payload) >= 69 else None
            print(f"[client]    host name {host_name!r} flags {host_flags}")
            if host_flags is None or host_flags & 0x01 or not host_flags & 0x02:
                fail(f"--stub host should say virtual displays yes, view-only no: {host_flags}")
        if mtype == 0x03 and payload:  # MONITOR_LIST
            for mon_id, w, h, nm, flags in parse_monitor_list(payload):
                print(f"[client]    monitor {mon_id}: {w}x{h} {nm} flags={flags}")
                monitor_ids.append(mon_id)
                if flags is None or flags & 0x01 or (mon_id == 0) != bool(flags & 0x02):
                    fail("monitor flags: expected monitor 0 primary, none virtual")

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
            mon_id, w, h, codec = struct.unpack_from("<BHHB", payload)
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
            mon_id, w, h, codec = struct.unpack_from("<BHHB", payload)
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
                mon_id, w, h, codec = struct.unpack_from("<BHHB", payload)
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

    check_live_config_and_rate(s, udp, selection)

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

    check_virtual_displays(s, udp)
    s.close()
    print("[client] OK: handshake, multi-monitor streaming and stop all verified")
    check_idle_dropped(idle)
    check_tcp_media(selection)

def check_tcp_media(selection):
    """USB mode: video comes on the TCP socket as VIDEO_FRAME (0x50) messages."""
    time.sleep(0.5)  # let the host reap the previous client's streams
    # From 127.0.0.1, like `adb reverse`: trusted, no PIN.
    s = socket.create_connection((HOST, TCP_PORT), timeout=5)
    s.sendall(hello("SmokeTestUSB", flags=0x01))
    send_multi_select(s, selection)
    counts = {}
    deadline = time.time() + 10
    while time.time() < deadline and any(counts.get(m, 0) < 3 for m in selection):
        mtype, payload = recv_msg(s)
        if mtype == 0x50:
            mon, fnum = struct.unpack_from("<BI", payload)
            if payload[5:7] != b"\xff\xd8":  # default codec is MJPEG
                print(f"[client] FAIL: VIDEO_FRAME mon={mon} is not a JPEG")
                sys.exit(1)
            counts[mon] = counts.get(mon, 0) + 1
    s.close()
    if any(counts.get(m, 0) < 3 for m in selection):
        print(f"[client] FAIL: TCP media frames per monitor: {counts}")
        sys.exit(1)
    print(f"[client] OK: video over TCP (USB mode) for all monitors: {counts}")

if __name__ == "__main__":
    main()
