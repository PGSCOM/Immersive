"""Try multiplayer alone: your headset plus "Ben", a bot on this PC.

    python3 host/tools/room_sandbox.py                 # Ben opens a room (PIN 111 111)
    python3 host/tools/room_sandbox.py join IP PIN     # Ben joins the room your headset opened
    options:  --tone          Ben plays a tone instead of repeating what you say
              --switch-host   replace an older host on TCP 19800 with this build

Starts Ben's PC (a --stub host on TCP 19900: three grey screens, the third
one animated) and Ben (the real client on this PC, client/tests/room_bot.gd)
sharing two of them, and prints what Ben sees and hears. Ctrl+C stops both.
Your headset stays on your own PC's host (TCP 19800); sharing YOUR screens
needs that host to be this build (protocol.h WatchCode).
"""
import os
import re
import signal
import subprocess
import sys
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HOST_BIN = os.path.join(ROOT, "host", "build", "immersive2_host")
CLIENT_DIR = os.path.join(ROOT, "client", "project")
BOT = os.path.join(ROOT, "client", "tests", "room_bot.gd")
BEN_TCP, ROOM_PIN = 19900, "111111"


def pid_on_tcp(port):
    out = subprocess.run(["ss", "-ltnpH", f"( sport = :{port} )"], capture_output=True, text=True).stdout
    m = re.search(r"pid=(\d+)", out)
    return int(m.group(1)) if m else None


def check_host(switch):
    pid = pid_on_tcp(19800)
    exe = os.path.realpath(f"/proc/{pid}/exe") if pid else None
    if exe == os.path.realpath(HOST_BIN):
        print(f"[sandbox] your PC's host is this build (pid {pid}): sharing your screens works")
        return
    if not switch:
        print(f"[sandbox] your PC's host on TCP 19800 is {exe or 'not running'}.")
        print("          Rooms, avatars, voice and Ben's screens work with any host, but sharing YOUR")
        print("          screens needs this build: quit that host and run " + HOST_BIN)
        print("          (or start this again with --switch-host).")
        return
    if pid:
        print(f"[sandbox] stopping the host at pid {pid}…")
        os.kill(pid, signal.SIGINT)
        for _ in range(50):
            if pid_on_tcp(19800) is None:
                break
            time.sleep(0.1)
    log = os.path.join("/tmp", "immersive2-host.log")
    subprocess.Popen(["setsid", "-f", HOST_BIN], cwd=ROOT, stdout=open(log, "w"), stderr=subprocess.STDOUT)
    time.sleep(1.5)
    print(f"[sandbox] started this build's host (log: {log})")


def echo(proc, prefix, wanted):
    """Print the lines of `proc` that contain one of `wanted` (and drain the rest)."""
    for line in proc.stdout:
        if any(w in line for w in wanted):
            print(f"{prefix} {line.rstrip()}".strip())


def main():
    sys.stdout.reconfigure(line_buffering=True)  # live, even into a pipe or a file
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt))
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = [a for a in sys.argv[1:] if a.startswith("--")]
    if not os.path.exists(HOST_BIN):
        sys.exit("build the host first: cmake --build host/build")
    room = ["--im2-room=open", f"--im2-room-pin={ROOM_PIN}"]
    if args[:1] == ["join"] and len(args) == 3:
        room = [f"--im2-room={args[1]}", f"--im2-room-pin={args[2]}"]
    elif args:
        sys.exit(__doc__)
    check_host("--switch-host" in opts)

    # Class names (Room, Participant…) need an up-to-date import cache.
    subprocess.run(["godot", "--headless", "--path", CLIENT_DIR, "--import"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ben_pc = subprocess.Popen(["stdbuf", "-oL", HOST_BIN, "--stub", "--no-ui", "--no-usb", "--pin", "246810",
                               "--tcp-port", str(BEN_TCP), "--udp-port", str(BEN_TCP + 1),
                               "--audio-port", str(BEN_TCP + 2)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(1.0)
    bot = subprocess.Popen(["godot", "--xr-mode", "off", "--path", CLIENT_DIR, "-s", BOT, "--",
                            "--im2-host=127.0.0.1", f"--im2-port={BEN_TCP}", f"--im2-udp-port={BEN_TCP + 1}",
                            "--im2-monitors=0,2", "--im2-name=Ben", "--im2-share",
                            "--im2-tone" if "--tone" in opts else "--im2-no-mic", *room],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if room[0] == "--im2-room=open":
        print(f"[sandbox] Ben opens a room on this PC: in the headset, Room tab -> Ben's room -> Join, PIN {ROOM_PIN[:3]} {ROOM_PIN[3:]}")
    else:
        print(f"[sandbox] Ben joins the room at {room[0].split('=')[1]}")
    print("[sandbox] Ctrl+C stops Ben and his PC\n")
    threading.Thread(target=echo, args=(ben_pc, "[Ben's PC]", ("watches", "refused", "sharing")),
                     daemon=True).start()
    try:
        echo(bot, "", ("[Bot]", "[Room]", "SCRIPT ERROR"))
    except KeyboardInterrupt:
        pass
    finally:
        for p in (bot, ben_pc):
            if p.poll() is None:
                p.send_signal(signal.SIGINT)
        for p in (bot, ben_pc):
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
        print("\n[sandbox] stopped")


if __name__ == "__main__":
    main()
