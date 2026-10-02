"""The host's settings panel and tray, end to end (no headset, no desktop).

    python3 host/tools/panel_test.py [path/to/immersive2_host]

Starts `--stub --no-usb --pin 246810` with a private XDG_CONFIG_HOME/HOME, no
display and no session bus (so no window or tray can reach the real desktop;
the panel URL is read from the log), then:
  - the panel refuses requests without the per-run token, with a wrong one,
    with a foreign Origin or Host, and POSTs without its header; the token
    link sets the cookie and every page/API call works with it;
  - "control this PC" off/on live: a connected client gets a fresh
    HELLO_ACK with HOST_FLAG_VIEW_ONLY, its input is ignored, then honoured
    again; discovery follows;
  - a new PIN: HELLO with the old one is refused, the new one works, and it
    is in the private pairing-pin file; PIN off lets a HELLO without one in;
  - "disconnect" drops the headset and makes its next HELLO ask for the PIN;
  - a virtual screen made by the headset is listed and removed from the panel;
  - codec / quality / start-at-login persist (host.conf, autostart .desktop);
  - Quit stops the host.
Then, when dbus-run-session and python3-dbus are available, the Linux tray
on a private session bus: a fake StatusNotifierWatcher must get the item,
its menu must show the status and PIN, and its Open / Quit entries must work.

IM2_TCP_PORT / IM2_UDP_PORT choose the ports (the panel takes a free one).
"""
import http.client
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(__file__))
from smoke_client import CLIENT_IP, HOST, TCP_PORT, UDP_PORT, hello, recv_msg, send_multi_select  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PIN = 246810


def fail(msg, log=None):
    print(f"[panel] FAIL: {msg}")
    if log:
        print(open(log).read()[-3000:])
    sys.exit(1)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def start_host(exe, home, log_path, env_extra=None, extra_args=()):
    env = dict(os.environ)
    for k in ("DISPLAY", "WAYLAND_DISPLAY"):
        env.pop(k, None)
    env.update(HOME=home, XDG_CONFIG_HOME=os.path.join(home, ".config"),
               DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent/im2-panel-test")
    env.update(env_extra or {})
    args = [exe, "--stub", "--no-usb", "--pin", str(PIN), "--tcp-port", str(TCP_PORT),
            "--udp-port", str(UDP_PORT), "--audio-port", str(UDP_PORT + 1),
            "--panel-port", str(free_port()), *extra_args]
    if shutil.which("stdbuf"):  # the log is read while the host runs
        args = ["stdbuf", "-oL", "-eL", *args]
    proc = subprocess.Popen(args, stdout=open(log_path, "w"), stderr=subprocess.STDOUT, env=env)
    end = time.time() + 10
    while time.time() < end:
        m = re.search(r"\[UI\] Settings panel: (http://127\.0\.0\.1:(\d+)/\?token=([0-9a-f]+))",
                      open(log_path).read())
        if m:
            return proc, m.group(1), int(m.group(2)), m.group(3)
        if proc.poll() is not None:
            break
        time.sleep(0.1)
    proc.kill()
    fail("the host never printed its panel address", log_path)


class Panel:
    def __init__(self, port, token):
        self.port, self.token = port, token
        self.origin = f"http://127.0.0.1:{port}"
        self.cookie = None

    def request(self, method, path, body=None, headers=None, cookie=True):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        h = {"Host": f"127.0.0.1:{self.port}"}
        if cookie and self.cookie:
            h["Cookie"] = self.cookie
        if body is not None:
            h.update({"Origin": self.origin, "X-Im2-Panel": "1",
                      "Content-Type": "application/x-www-form-urlencoded"})
        h.update(headers or {})
        c.request(method, path, body=urllib.parse.urlencode(body) if body is not None else None, headers=h)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, dict((k.lower(), v) for k, v in r.getheaders()), data

    def state(self):
        import json
        status, _, data = self.request("GET", "/api/state")
        if status != 200:
            fail(f"/api/state answered {status}")
        return json.loads(data)

    def post(self, path, **body):
        import json
        status, _, data = self.request("POST", path, body={k: str(v) for k, v in body.items()})
        return status, (json.loads(data) if data.startswith(b"{") else data)

    def set(self, key, value):
        status, data = self.post("/api/set", key=key, value=value)
        if status != 200:
            fail(f"setting {key}={value} answered {status}: {data}")
        return data


def check_security(p):
    if p.request("GET", "/", cookie=False)[0] != 403:
        fail("the panel answered without the token")
    if p.request("GET", "/?token=" + "0" * 32, cookie=False)[0] != 403:
        fail("the panel took a wrong token")
    status, headers, _ = p.request("GET", "/?token=" + p.token, cookie=False)
    cookie = headers.get("set-cookie", "")
    if status != 303 or headers.get("location") != "/" or "HttpOnly" not in cookie or "SameSite=Strict" not in cookie:
        fail(f"token link: {status} {headers}")
    p.cookie = cookie.split(";")[0]
    status, headers, page = p.request("GET", "/")
    if status != 200 or b"Immersive-2" not in page or "frame-ancestors 'none'" not in headers.get("content-security-policy", ""):
        fail(f"page with the cookie: {status}")
    status, headers, font = p.request("GET", "/grotesk.woff2")
    if status != 200 or not font.startswith(b"wOF2"):
        fail("the Grotesk font is not served")
    for what, extra in (("foreign Origin", {"Origin": "http://evil.example"}),
                        ("another local port as Origin", {"Origin": "http://127.0.0.1:1"}),
                        ("a rebound Host", {"Host": f"evil.example:{p.port}"})):
        if p.request("GET", "/api/state", headers=extra)[0] != 403:
            fail(f"GET with {what} was served")
        if p.request("POST", "/api/set", body={"key": "view_only", "value": "1"}, headers=extra)[0] != 403:
            fail(f"POST with {what} was accepted")
    if p.request("POST", "/api/set", body={"key": "view_only", "value": "1"}, headers={"X-Im2-Panel": ""})[0] != 403:
        fail("POST without the X-Im2-Panel header was accepted")
    if p.state()["settings"]["view_only"]:
        fail("a refused request changed a setting")
    print("[panel] token, cookie, Origin/Host/header checks OK")


def connect(name, pin=PIN):
    s = socket.create_connection((HOST, TCP_PORT), timeout=5, source_address=(CLIENT_IP, 0))
    s.sendall(hello(name, pin=pin))
    return s, recv_msg(s)


def next_ack(s, seconds=3):
    """The next HELLO_ACK on `s` (skipping other messages): its flags byte."""
    end = time.time() + seconds
    while time.time() < end:
        mtype, payload = recv_msg(s)
        if mtype == 0x02:
            return payload[68]
    fail("no HELLO_ACK re-sent after the setting changed")


def discovery_flags():
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind((CLIENT_IP, 0))
    u.settimeout(2)
    u.sendto(struct.pack("<IB", 0x3F324D49, 1), (HOST, TCP_PORT))
    data, _ = u.recvfrom(256)
    u.close()
    return data[8]


def send_input(s):
    s.sendall(struct.pack("<BIBHHBhh", 0x10, 10, 0, 100, 50, 1, 0, 0))  # left button down
    s.sendall(struct.pack("<BIBHHBhh", 0x10, 10, 0, 100, 50, 0, 0, 0))  # and up


def check_view_only(p, log):
    s, (mtype, payload) = connect("PanelTest")
    if mtype != 0x02 or payload[68] & 0x01:
        fail(f"HELLO_ACK before the change: {mtype:#x} flags {payload[68] if len(payload) > 68 else None}")
    send_multi_select(s, [0])
    end = time.time() + 5
    while time.time() < end:
        st = p.state()
        if st["headsets"] and st["headsets"][0]["streams"]:
            break
        time.sleep(0.2)
    h = st["headsets"]
    if len(h) != 1 or h[0]["name"] != "PanelTest" or h[0]["address"] != CLIENT_IP or not h[0]["streams"] \
            or h[0]["streams"][0]["codec"] != "mjpeg" or h[0]["streams"][0]["width"] != 1920:
        fail(f"the panel does not show the streaming headset: {h}", log)

    p.set("view_only", 1)
    flags = next_ack(s)
    if not flags & 0x01 or not flags & 0x04:
        fail(f"the re-sent HELLO_ACK should keep HOST_FLAG_SCREEN_OFF and add VIEW_ONLY: {flags}")
    if not discovery_flags() & 0x02:
        fail("discovery does not say view-only")
    send_input(s)
    time.sleep(0.5)
    text = open(log).read()
    if "View-only: ignoring" not in text or "[StubInput]" in text:
        fail("input reached the injector while view-only", log)
    if "view_only = on" not in open(p.conf).read():
        fail("view_only not saved in host.conf")

    p.set("view_only", 0)
    if next_ack(s) & 0x01:
        fail("the re-sent HELLO_ACK still says view-only")
    send_input(s)
    time.sleep(0.5)
    if "[StubInput]" not in open(log).read():
        fail("input is still ignored after control was turned back on", log)
    print("[panel] control on/off applied live (HELLO_ACK re-sent, discovery, input) OK")
    return s


def check_pin(p):
    old = p.state()["pin"]["value"]
    status, st = p.post("/api/new-pin")
    new = st["pin"]["value"] if status == 200 else None
    if not new or new == old or not re.fullmatch(r"\d{6}", new):
        fail(f"new PIN: {status} {old} -> {new}")
    if open(os.path.join(p.cfgdir, "pairing-pin")).read().strip() != new:
        fail("the new PIN is not in the pairing-pin file")
    s, (mtype, payload) = connect("OldPin", pin=int(old))
    if mtype != 0x09 or payload[:1] != b"\x02":
        fail(f"HELLO with the old PIN was not refused: {mtype:#x}")
    s.close()
    s, (mtype, _) = connect("NewPin", pin=int(new))
    if mtype != 0x02:
        fail(f"HELLO with the new PIN was refused: {mtype:#x}")
    s.close()

    p.set("pin", 0)
    if discovery_flags() & 0x01:
        fail("discovery still asks for a PIN")
    s, (mtype, _) = connect("NoPin", pin=0)
    if mtype != 0x02:
        fail("PIN off, but a HELLO without one was refused")
    s.close()
    p.set("pin", 1)
    if p.state()["pin"]["value"] != new or "pin = on" not in open(p.conf).read():
        fail("PIN back on did not keep the PIN or was not saved")
    print(f"[panel] new PIN ({old} -> {new}), old refused, PIN off/on OK")
    return int(new)


def check_disconnect(p, pin):
    s, (mtype, _) = connect("KickMe", pin=pin)
    time.sleep(0.3)
    kick = [h for h in p.state()["headsets"] if h["name"] == "KickMe"]
    if mtype != 0x02 or not kick:
        fail("the headset to disconnect is not listed")
    p.post("/api/disconnect", id=kick[0]["id"])
    s.settimeout(3)
    try:
        while s.recv(4096):
            pass
    except OSError:
        pass
    s.close()
    s, (mtype, payload) = connect("KickMe", pin=pin)
    if mtype != 0x09 or payload[:1] != b"\x01":
        fail(f"after a disconnect the next HELLO must ask for the PIN, got {mtype:#x} {payload[:1].hex()}")
    s.close()
    s, (mtype, _) = connect("KickMe", pin=pin)
    if mtype != 0x02:
        fail("the headset could not come back with the PIN")
    s.close()
    print("[panel] disconnect: dropped, asked for the PIN once, back OK")


def check_virtual(p, s):
    s.sendall(struct.pack("<BIHHB", 0x22, 5, 1280, 720, 60))
    end = time.time() + 5
    while time.time() < end and not p.state()["virtual"]:
        time.sleep(0.2)
    v = p.state()["virtual"]
    if [x["id"] for x in v] != [100] or v[0]["width"] != 1280:
        fail(f"the virtual screen is not listed: {v}")
    status, st = p.post("/api/remove-virtual", id=100)
    if status != 200 or st["virtual"]:
        fail(f"removing it from the panel: {status} {st}")
    if p.post("/api/remove-virtual", id=100)[0] != 400:
        fail("removing a screen that is gone did not fail")
    print("[panel] virtual screen listed and removed OK")


def check_settings(p):
    p.set("codec", "h264")
    p.set("jpeg_quality", 60)
    st = p.state()["settings"]
    if st["codec"] != "h264" or st["jpeg_quality"] != 60:
        fail(f"codec/quality not applied: {st}")
    conf = open(p.conf).read()
    if "codec = h264" not in conf or "jpeg_quality = 60" not in conf:
        fail(f"codec/quality not saved:\n{conf}")
    if p.post("/api/set", key="jpeg_quality", value="5")[0] != 400:
        fail("an out-of-range quality was accepted")
    if p.post("/api/set", key="audio", value="1")[0] != 400:
        fail("sound was switched on in --stub, where there is none")
    # Started with --no-usb, so no adb server: USB on waits for the next start
    # (and never runs adb here).
    st = p.set("usb", 1)["settings"]
    if not st["usb"] or "next time" not in st["usb_note"] or "usb = on" not in open(p.conf).read():
        fail(f"USB on: {st}")
    if p.set("usb", 0)["settings"]["usb_note"]:
        fail("USB off still shows a note")
    desktop = os.path.join(p.home, ".config", "autostart", "immersive2-host.desktop")
    p.set("autostart", 1)
    if not p.state()["settings"]["autostart"] or "Exec=" not in open(desktop).read():
        fail("start at login did not write the autostart entry")
    p.set("autostart", 0)
    if os.path.exists(desktop) or p.state()["settings"]["autostart"]:
        fail("start at login could not be turned off")
    print("[panel] codec, quality, USB, start at login applied and saved OK")


def check_quit(p, proc):
    if p.post("/api/quit")[0] != 200:
        fail("quit was refused")
    try:
        code = proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        fail("the host did not stop after Quit")
    if code != 0 or os.path.exists(os.path.join(p.cfgdir, "panel-url")):
        fail(f"after Quit: exit code {code}, panel-url left behind")
    print("[panel] Quit stops the host OK")


# ---- tray (Linux, private session bus) -------------------------------------

WATCHER = r'''
import dbus, dbus.service, sys
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib
DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
class Watcher(dbus.service.Object):
    @dbus.service.method("org.kde.StatusNotifierWatcher", in_signature="s", out_signature="",
                         sender_keyword="sender")
    def RegisterStatusNotifierItem(self, service, sender=None):
        print("REGISTERED", service, sender, flush=True)
name = dbus.service.BusName("org.kde.StatusNotifierWatcher", bus)
Watcher(bus, "/StatusNotifierWatcher")
print("WATCHING", flush=True)
GLib.MainLoop().run()
'''


def tray_inner(exe):
    """Runs inside dbus-run-session."""
    import dbus
    home = tempfile.mkdtemp(prefix="im2-tray-")
    fakebin = os.path.join(home, "bin")
    os.makedirs(fakebin)
    opened = os.path.join(home, "opened.log")
    for b in ("google-chrome", "chromium", "xdg-open", "notify-send"):
        path = os.path.join(fakebin, b)
        with open(path, "w") as f:
            f.write(f"#!/bin/sh\necho \"$*\" >> {opened}\n")
        os.chmod(path, 0o755)
    watcher = subprocess.Popen([sys.executable, "-c", WATCHER], stdout=subprocess.PIPE, text=True)
    if watcher.stdout.readline().strip() != "WATCHING":
        fail("the fake StatusNotifierWatcher did not start")
    lines = []
    threading.Thread(target=lambda: lines.extend(watcher.stdout), daemon=True).start()
    log = os.path.join(home, "host.log")
    env = {"DBUS_SESSION_BUS_ADDRESS": os.environ["DBUS_SESSION_BUS_ADDRESS"],
           "DISPLAY": ":999", "PATH": fakebin + os.pathsep + os.environ.get("PATH", "")}
    proc, url, _, _ = start_host(exe, home, log, env)
    try:
        end = time.time() + 5
        while time.time() < end and not lines:
            time.sleep(0.1)
        if not lines or not lines[0].startswith("REGISTERED org.kde.StatusNotifierItem-"):
            fail(f"the tray never registered with the watcher: {lines}", log)
        if os.path.exists(opened):
            fail("the panel window opened at startup although a tray is there")
        service = lines[0].split()[1]
        bus = dbus.SessionBus()
        item = bus.get_object(service, "/StatusNotifierItem")
        props = item.GetAll("org.kde.StatusNotifierItem", dbus_interface="org.freedesktop.DBus.Properties")
        pix = props["IconPixmap"]
        if props["Id"] != "immersive2" or props["Menu"] != "/MenuBar" or not pix \
                or len(pix[0][2]) != pix[0][0] * pix[0][1] * 4 or not any(pix[0][2][3::4]):
            fail(f"bad StatusNotifierItem properties: { {k: v for k, v in props.items() if k != 'IconPixmap'} }")
        menu = bus.get_object(service, "/MenuBar")
        _, layout = menu.GetLayout(0, -1, [], dbus_interface="com.canonical.dbusmenu")
        labels = {int(c[0]): str(c[1].get("label", "")) for c in layout[2]}
        if labels.get(1) != "Open Immersive-2" or labels.get(3) != "Waiting for a headset" \
                or labels.get(4) != "PIN 246 810" or labels.get(6) != "Quit":
            fail(f"tray menu: {labels}")
        menu.Event(1, "clicked", dbus.Int32(0, variant_level=1), dbus.UInt32(0),
                   dbus_interface="com.canonical.dbusmenu")
        end = time.time() + 5
        while time.time() < end and not (os.path.exists(opened) and url in open(opened).read()):
            time.sleep(0.1)
        if not os.path.exists(opened) or f"--app={url}" not in open(opened).read():
            fail("the tray's Open entry did not open the panel as an app window", log)
        menu.Event(6, "clicked", dbus.Int32(0, variant_level=1), dbus.UInt32(0),
                   dbus_interface="com.canonical.dbusmenu")
        if proc.wait(timeout=10) != 0:
            fail("the tray's Quit entry did not stop the host cleanly", log)
        print("[panel] tray: registered, icon + menu (status, PIN), Open and Quit OK")
    finally:
        if proc.poll() is None:
            proc.kill()
        watcher.kill()
        shutil.rmtree(home, ignore_errors=True)


def main():
    sys.stdout.reconfigure(line_buffering=True)
    exe = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else \
        os.path.join(ROOT, "host", "build", "immersive2_host")
    if "--tray-inner" in sys.argv:
        tray_inner(exe)
        return
    home = tempfile.mkdtemp(prefix="im2-panel-")
    log = os.path.join(home, "host.log")
    proc, _, port, token = start_host(exe, home, log)
    p = Panel(port, token)
    p.home, p.cfgdir = home, os.path.join(home, ".config", "immersive2")
    p.conf = os.path.join(p.cfgdir, "host.conf")
    try:
        check_security(p)
        s = check_view_only(p, log)
        check_virtual(p, s)
        pin = check_pin(p)
        check_disconnect(p, pin)
        check_settings(p)
        s.close()
        check_quit(p, proc)
    finally:
        if proc.poll() is None:
            proc.kill()
        shutil.rmtree(home, ignore_errors=True)

    try:
        import dbus  # noqa: F401
        import gi  # noqa: F401
        have_dbus = shutil.which("dbus-run-session") is not None
    except ImportError:
        have_dbus = False
    if sys.platform.startswith("linux") and have_dbus:
        r = subprocess.run(["dbus-run-session", "--", sys.executable, __file__, exe, "--tray-inner"])
        if r.returncode != 0:
            sys.exit(r.returncode)
    else:
        print("[panel] tray check skipped (needs Linux, dbus-run-session, python3-dbus, python3-gi)")
    print("[panel] OK")


if __name__ == "__main__":
    main()
