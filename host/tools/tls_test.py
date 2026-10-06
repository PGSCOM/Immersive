"""TLS on the control channel and sealed UDP media (docs/SECURITY.md).

    python3 host/tools/tls_test.py [path/to/immersive2_host]

Starts the host with --stub --pin 246810 and its settings folder in a
temporary directory (IM2_TCP_PORT / IM2_UDP_PORT choose the ports). Checks:
- the host makes an identity, keeps the key readable by its user only and
  prints its fingerprint;
- a TLS client (from 127.0.0.2) gets TLS 1.2 with an ECDHE + AEAD suite,
  then IDENTITY (the certificate it just saw in the handshake) before the
  answer to its HELLO: PIN required, wrong PIN;
- pinned to that certificate and with the PIN it gets MEDIA_KEY, HELLO_ACK
  and the monitor list, and the frames it selects arrive sealed with that
  key: they open, and a datagram changed in transit does not;
- plain TCP stays fine from this PC (127/8); HELLO_FLAG_IDENTITY gets the
  certificate there too, MEDIA_KEY never;
- plain TCP from the network is refused (REJECT_ENCRYPTION_REQUIRED), unless
  the host runs with --allow-plaintext;
- 20 wrong PINs in a minute from as many addresses make the next wrong one
  slow (5 s) and warn, while the right PIN still pairs at once;
- after a restart the identity is the same.
Needs the `cryptography` package (python3-cryptography) for AES and HMAC.
"""
import hashlib
import hmac
import os
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

sys.path.insert(0, os.path.dirname(__file__))
from smoke_client import HOST, PIN, TCP_PORT, UDP_PORT, hello, receive_frames, recv_msg, send_multi_select  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLIENT_IP = "127.0.0.2"
MSG_IDENTITY, MSG_MEDIA_KEY = 0x27, 0x28
HELLO_FLAG_IDENTITY = 0x04


def fail(msg):
    print(f"[tls] FAIL: {msg}")
    sys.exit(1)


def lan_ip():
    """This machine's address on its network (no packet is sent), or None."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))
        ip = s.getsockname()[0]
        return None if ip.startswith("127.") else ip
    except OSError:
        return None
    finally:
        s.close()


def tls_connect(pem=None, ip=CLIENT_IP, host=HOST):
    """A TLS 1.2 connection; pinned to `pem` (the only trusted certificate) if given."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    if pem:
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.verify_flags &= ~getattr(ssl, "VERIFY_X509_STRICT", 0)
        ctx.load_verify_locations(cadata=pem)
    else:
        ctx.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection((host, TCP_PORT), timeout=5, source_address=(ip, 0))
    return ctx.wrap_socket(raw, server_hostname="immersive-host")


def messages(s, seconds, until=None):
    """Control messages for up to `seconds` (or until type `until` arrives)."""
    out, end = [], time.time() + seconds
    s.settimeout(0.3)
    while time.time() < end:
        try:
            out.append(recv_msg(s))
        except (TimeoutError, socket.timeout):
            continue
        except (ConnectionError, ssl.SSLError):
            break
        if until is not None and out[-1][0] == until:
            break
    return out


class MediaKey:
    """The client side of tls::MediaCipher."""

    def __init__(self, key):
        self.aes, self.mac = key[:16], key[16:48]

    def open(self, pkt):
        if len(pkt) < 48 or (len(pkt) - 32) % 16:
            return None
        iv, body, tag = pkt[:16], pkt[16:-16], pkt[-16:]
        if not hmac.compare_digest(hmac.new(self.mac, iv + body, hashlib.sha256).digest()[:16], tag):
            return None
        d = Cipher(algorithms.AES(self.aes), modes.CBC(iv)).decryptor()
        plain = d.update(body) + d.finalize()
        pad = plain[-1]
        return plain[:-pad] if 1 <= pad <= 16 else None


class SealedUdp:
    """A UDP socket that opens every datagram (for receive_frames)."""

    def __init__(self, sock, key):
        self.sock, self.key, self.count, self.bad = sock, key, 0, 0

    def recvfrom(self, n):
        while True:
            pkt, addr = self.sock.recvfrom(n)
            plain = self.key.open(pkt)
            if plain is None:
                self.bad += 1
                continue
            self.count += 1
            if self.count == 1:
                # The same datagram, one bit changed: must not open.
                broken = bytearray(pkt)
                broken[20] ^= 0x01
                if self.key.open(bytes(broken)) is not None:
                    fail("a changed datagram still opened")
            return plain, addr


def start_host(exe, conf, *extra):
    log = tempfile.TemporaryFile("w+")
    env = dict(os.environ, XDG_CONFIG_HOME=conf, APPDATA=conf)
    host = subprocess.Popen([exe, "--stub", "--no-usb", "--no-ui", "--pin", str(PIN),
                             "--tcp-port", str(TCP_PORT), "--udp-port", str(UDP_PORT),
                             "--audio-port", str(UDP_PORT + 1), *extra],
                            stdout=log, stderr=subprocess.STDOUT, env=env)
    time.sleep(1.0)
    return host, log


def stop_host(host, log):
    host.terminate()  # also flushes its (block-buffered) log
    host.wait(timeout=5)
    log.seek(0)
    return log.read()


def fingerprint(der):
    h = hashlib.sha256(der).hexdigest().upper()[:16]
    return " ".join(h[i:i + 4] for i in range(0, 16, 4))


def logged_fingerprint(text):
    for line in text.splitlines():
        if line.strip().startswith("Identity"):
            return " ".join(line.split()[1:5])
    fail("the host did not print its identity:\n" + text[-1500:])


def check_tls(conf):
    """Handshake, IDENTITY, the PIN inside TLS, sealed frames. Returns the PEM."""
    s = tls_connect()
    version, cipher = s.version(), s.cipher()[0]
    if version != "TLSv1.2" or "ECDHE-ECDSA" not in cipher or not ("GCM" in cipher or "CHACHA20" in cipher):
        fail(f"expected TLS 1.2 with ECDHE-ECDSA and AEAD, got {version} {cipher}")
    print(f"[tls] handshake: {version} {cipher} OK")
    der = s.getpeercert(binary_form=True)
    s.sendall(hello("TlsTest", pin=0))
    got = messages(s, 3, until=0x09)
    types = [t for t, _ in got]
    if types[:2] != [MSG_IDENTITY, 0x09] or got[1][1][:1] != b"\x01":
        fail(f"probe: expected IDENTITY then HELLO_REJECT(1), got {[hex(t) for t in types]}")
    pem = got[0][1].decode()
    if ssl.PEM_cert_to_DER_cert(pem) != der:
        fail("IDENTITY is not the certificate of the handshake")
    s.close()
    print("[tls] probe without PIN: IDENTITY (the handshake's certificate), then PIN required OK")

    s = tls_connect(pem)
    s.sendall(hello("TlsTest", pin=PIN + 1 if PIN < 999999 else PIN - 1))
    got = messages(s, 3, until=0x09)
    if [t for t, _ in got] != [MSG_IDENTITY, 0x09] or got[1][1][:1] != b"\x02":
        fail(f"wrong PIN over TLS: expected IDENTITY, HELLO_REJECT(2), got {[hex(t) for t, _ in got]}")
    s.close()
    print("[tls] pinned, wrong PIN: refused OK")

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind((CLIENT_IP, UDP_PORT))
    udp.settimeout(0.5)
    s = tls_connect(pem)
    s.sendall(hello("TlsTest", pin=PIN))
    got = messages(s, 3, until=0x03)
    types = [t for t, _ in got]
    if types[:4] != [MSG_IDENTITY, MSG_MEDIA_KEY, 0x02, 0x03] or len(got[1][1]) != 48:
        fail(f"pinned with the PIN: expected IDENTITY, MEDIA_KEY(48), HELLO_ACK, MONITOR_LIST, "
             f"got {[(hex(t), len(p)) for t, p in got]}")
    print("[tls] pinned with the PIN: IDENTITY, MEDIA_KEY, HELLO_ACK, MONITOR_LIST OK")
    sealed = SealedUdp(udp, MediaKey(got[1][1]))
    send_multi_select(s, [0])
    complete = receive_frames(sealed, [0], 8, 3)
    if complete.get(0, 0) < 3 or sealed.bad:
        fail(f"sealed frames: {complete} complete, {sealed.bad} datagrams did not open")
    print(f"[tls] {sealed.count} sealed datagrams opened, a changed one did not OK")
    s.close()
    udp.close()
    return pem, der


def check_plain(der):
    """Plain TCP from this PC: fine; HELLO_FLAG_IDENTITY gets the certificate, never MEDIA_KEY."""
    s = socket.create_connection((HOST, TCP_PORT), timeout=5, source_address=(CLIENT_IP, 0))
    s.sendall(hello("PlainTest", flags=HELLO_FLAG_IDENTITY, pin=PIN))
    got = messages(s, 3, until=0x03)
    types = [t for t, _ in got]
    if types[:3] != [MSG_IDENTITY, 0x02, 0x03] or MSG_MEDIA_KEY in types:
        fail(f"plain from 127.0.0.2: expected IDENTITY, HELLO_ACK, MONITOR_LIST, got {[hex(t) for t in types]}")
    if ssl.PEM_cert_to_DER_cert(got[0][1].decode()) != der:
        fail("plain IDENTITY differs from the TLS certificate")
    s.close()
    print("[tls] plain from this PC: accepted, IDENTITY on request, no MEDIA_KEY OK")


def wrong_pin(ip):
    s = socket.create_connection((HOST, TCP_PORT), timeout=10, source_address=(ip, 0))
    s.sendall(hello("Guess", pin=111111 if PIN != 111111 else 222222))
    got = messages(s, 8, until=0x09)
    s.close()
    return got[-1][1][:1] if got and got[-1][0] == 0x09 else None


def check_guessing():
    """One wrong PIN from each of 20 addresses: the 21st is slow, the right PIN is not."""
    ips = [f"127.0.0.{n}" for n in range(10, 30)]
    for batch in (ips[:6], ips[6:12], ips[12:18], ips[18:]):  # under the pending-socket cap
        threads = [threading.Thread(target=wrong_pin, args=(ip,)) for ip in batch]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
    t0 = time.time()
    reason = wrong_pin("127.0.0.40")
    slow = time.time() - t0
    if reason != b"\x02" or slow < 4.5:
        fail(f"the 21st wrong PIN in a minute should take 5 s: {slow:.1f} s, reason {reason}")
    s = tls_connect(ip="127.0.0.41")
    s.sendall(hello("TlsTest", pin=PIN))
    t0 = time.time()
    if 0x02 not in [t for t, _ in messages(s, 3, until=0x02)] or time.time() - t0 > 1.5:
        fail("the right PIN should still pair at once")
    s.close()
    print(f"[tls] 20 wrong PINs from 20 addresses: the next took {slow:.1f} s, the right one pairs at once OK")


def check_lan(lan, allowed):
    s = socket.create_connection((lan, TCP_PORT), timeout=5, source_address=(lan, 0))
    s.sendall(hello("PlainTest", pin=PIN))
    got = messages(s, 3, until=0x03 if allowed else 0x09)
    types = [t for t, _ in got]
    s.close()
    if allowed:
        if 0x02 not in types:
            fail(f"--allow-plaintext: plain from {lan} should pair, got {[hex(t) for t in types]}")
        print(f"[tls] --allow-plaintext: plain from {lan} accepted OK")
        return
    if types != [0x09] or got[0][1][:1] != b"\x05":
        fail(f"plain from {lan}: expected only HELLO_REJECT(5), got {[(hex(t), p[:1].hex()) for t, p in got]}")
    print(f"[tls] plain from the network ({lan}): refused, encryption required OK")
    s = tls_connect(ip=lan, host=lan)
    s.sendall(hello("TlsTest", pin=PIN))
    if 0x02 not in [t for t, _ in messages(s, 3, until=0x02)]:
        fail(f"TLS from {lan} with the PIN should pair")
    s.close()
    print(f"[tls] TLS from the network ({lan}): paired OK")


def main():
    exe = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "host", "build", "immersive2_host")
    lan = lan_ip()
    with tempfile.TemporaryDirectory() as conf:
        host, log = start_host(exe, conf)
        try:
            pem, der = check_tls(conf)
            check_plain(der)
            if lan:
                check_lan(lan, allowed=False)
            else:
                print("[tls] no network address here: skipping the checks from the network")
            check_guessing()
        finally:
            text = stop_host(host, log)
        if "someone may be guessing it" not in text:
            fail("no warning about the wrong PINs:\n" + text[-1500:])
        if logged_fingerprint(text) != fingerprint(der):
            fail(f"printed fingerprint {logged_fingerprint(text)} is not the certificate's {fingerprint(der)}")
        print(f"[tls] fingerprint {fingerprint(der)} printed OK")
        key = os.path.join(conf, "Immersive2" if os.name == "nt" else "immersive2", "identity-key.pem")
        if not os.path.exists(key):
            fail(f"no {key}")
        if os.name == "posix" and stat.S_IMODE(os.stat(key).st_mode) & 0o077:
            fail(f"{key} is readable by others: {oct(os.stat(key).st_mode)}")
        print("[tls] key saved, readable by its user only OK")

        host, log = start_host(exe, conf, "--allow-plaintext")
        try:
            s = tls_connect(pem)  # pinned: the same identity
            if s.getpeercert(binary_form=True) != der:
                fail("the identity changed across a restart")
            s.close()
            print("[tls] same identity after a restart OK")
            if lan:
                check_lan(lan, allowed=True)
        finally:
            stop_host(host, log)
    print("[tls] OK: TLS with a pinnable identity, the PIN inside it, sealed media, plain TCP only from this PC")


if __name__ == "__main__":
    main()
