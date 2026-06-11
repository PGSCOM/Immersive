"""Smoke-test client for Immersive-2 host: handshake + monitor select."""
import socket
import struct
import sys
import time

HOST = "127.0.0.1"
TCP_PORT = 19800

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

def main():
    # Bind UDP on 127.0.0.2:19801 (the host holds the wildcard bind on :19801,
    # but a specific-address bind takes precedence for packets sent to it).
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.2", 19801))
    udp.settimeout(0.5)

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.2", 0))  # source IP 127.0.0.2 so host streams there
    s.settimeout(5)
    s.connect((HOST, TCP_PORT))
    print("[client] TCP connected")

    # HELLO: type 0x01, len 33, version + 32-byte name
    name = b"SmokeTest".ljust(32, b"\x00")
    s.sendall(struct.pack("<BI", 0x01, 33) + bytes([1]) + name)

    monitor_ids = []
    deadline = time.time() + 5
    selected = False
    while time.time() < deadline:
        s.settimeout(max(0.1, deadline - time.time()))
        try:
            hdr = recv_exact(s, 5)
        except (TimeoutError, socket.timeout):
            break
        mtype, mlen = struct.unpack("<BI", hdr)
        payload = recv_exact(s, mlen) if mlen else b""
        print(f"[client] <- {MSG_NAMES.get(mtype, hex(mtype))} ({mlen} bytes)")

        if mtype == 0x03 and payload:  # MONITOR_LIST
            count = payload[0]
            off = 1
            for _ in range(count):
                mon_id, w, h, rr = struct.unpack_from("<BHHB", payload, off)
                nm = payload[off+6:off+70].split(b"\x00")[0].decode("utf-8", "replace")
                print(f"[client]    monitor {mon_id}: {w}x{h}@{rr} {nm}")
                monitor_ids.append(mon_id)
                off += 70
            # MONITOR_SELECT first monitor
            s.sendall(struct.pack("<BI", 0x04, 1) + bytes([monitor_ids[0]]))
            print(f"[client] -> MONITOR_SELECT {monitor_ids[0]}")
            selected = True
        elif mtype == 0x05:  # STREAM_START
            mon_id, w, h, codec = struct.unpack("<BHHB", payload)
            print(f"[client]    stream: monitor={mon_id} {w}x{h} codec={codec}")
            # Receive and reassemble video frames for a few seconds
            frames = {}
            complete = 0
            first_bytes = None
            end = time.time() + 4
            while time.time() < end and complete < 5:
                try:
                    pkt, _ = udp.recvfrom(2048)
                except (TimeoutError, socket.timeout):
                    continue
                if len(pkt) < 9:
                    continue
                fmon, fnum, cidx, ccnt = struct.unpack_from("<BIHH", pkt, 0)
                chunks = frames.setdefault(fnum, {})
                chunks[cidx] = pkt[9:]
                if len(chunks) == ccnt:
                    data = b"".join(chunks[i] for i in range(ccnt))
                    if first_bytes is None:
                        first_bytes = data[:8]
                    complete += 1
                    del frames[fnum]
            print(f"[client] complete frames: {complete}")
            if first_bytes:
                print(f"[client] first frame starts with: {first_bytes.hex()}")
            if complete == 0:
                print("[client] FAIL: no complete video frames received")
                sys.exit(1)
            break

    if not selected:
        print("[client] FAIL: never received MONITOR_LIST")
        sys.exit(1)

    s.close()
    print("[client] done")

if __name__ == "__main__":
    main()
