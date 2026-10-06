"""Try the whole multiplayer side alone: your headset plus two people on this PC.

    python3 host/tools/room_sandbox.py                 # Ben opens a room (PIN 111 111), Cleo joins it
    python3 host/tools/room_sandbox.py join IP PIN     # both join the room your headset opened
    options:  --tone          Cleo plays a tone (a second voice, from her head)
              --switch-host   replace the host on TCP 19800 with this build (needed to share YOUR screens)
              --install       export this build's app and install it on the headset plugged in (adb)
              --no-cleo       only Ben

Ben and Cleo are the real client on this PC (client/tests/room_bot.gd), each
with a PC of their own (--stub hosts on TCP 19900 and 19930, each with its own
TLS identity): Ben shares two screens (the second one animated), repeats what
you say 1.5 s later, and has a whiteboard you may draw on, where he draws six
lines; Cleo shares one screen, shows a whiteboard you may not draw on, and
draws on every board that lets her (Ben's, and yours once you allow her).
Their windows show what they see. While it runs, type a letter and Enter:

    c  Cleo leaves / comes back       e  Eve tries a wrong room PIN
    s  who watches whose screens, and whether it is encrypted and pinned
    h  what to try in the headset     q  quit (also Ctrl+C)

Full logs: /tmp/immersive2-sandbox-*.log
"""
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
from smoke_client import private_config  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HOST_BIN = os.path.join(ROOT, "host", "build", "immersive2_host")
CLIENT_DIR = os.path.join(ROOT, "client", "project")
BOT = os.path.join(ROOT, "client", "tests", "room_bot.gd")
ROOM_PIN = "111111"
LOG = "/tmp/immersive2-sandbox-{}.log"

CHECKLIST = """
What to try in the headset (Ben and Cleo say what they see in this window):
 1. Room tab: "Ben's room" in the list -> Join, PIN {pin}. Or type this PC's address.
    Ben and Cleo stand beside you in a row, each in their colour, names over their heads.
    Join with a wrong PIN first: refused; five wrong ones lock your headset out for a minute.
 2. Talk: Ben repeats you 1.5 s later, from his head.{tone}
 3. Ben's two screens and Cleo's one hang where they have them (the third is animated).
    Grab one by its bar and move it: it stays where you put it, for you only.
 4. Whiteboards: Ben draws six lines on his, you can draw on it too (trigger, pinch or a
    fingertip), and Cleo draws on it every few seconds. Cleo's own board: movable, not drawable.
 5. Your board (Screens tab, Whiteboard) and the Room tab's Permissions page: allow Cleo to
    draw, and within seconds a line of hers lands on it. Take it back: she stops.
 6. Permissions: turn off Cleo's voice, screens or board: they go away for you only.
 7. "Show my screens to the room" (needs this build's host on this PC): Ben and Cleo say
    "screens: live" for you; type s here: they watch your PC over TLS pinned to its
    certificate. Turn off "Sees my screens" for Cleo: she stops, Ben carries on.
 8. Walk (left stick), turn (right stick), pinch in the air and pull; "Back to my seat".
 9. Type c here: Cleo leaves (her avatar, screens and board go); c again: she comes back
    and gets your board as it is now. Type e: Eve's wrong PIN is refused.
10. Leave the room from the menu: you are back at your seat, the others carry on.
"""


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
        print("          Rooms, avatars, voice and the others' screens work with any host, but sharing")
        print("          YOUR screens needs this build: quit that host and run " + HOST_BIN)
        print("          (or start this again with --switch-host).")
        return
    if pid:
        print(f"[sandbox] stopping the host at pid {pid}…")
        os.kill(pid, signal.SIGINT)
        for _ in range(50):
            if pid_on_tcp(19800) is None:
                break
            time.sleep(0.1)
    log = LOG.format("your-pc")
    subprocess.Popen(["setsid", "-f", HOST_BIN], cwd=ROOT, stdout=open(log, "w"), stderr=subprocess.STDOUT)
    time.sleep(1.5)
    print(f"[sandbox] started this build's host (log: {log})")


def install_app():
    """Export this build's Android app (from a copy of the project, as CI does)
    and install it on the headset plugged into this PC."""
    print("[sandbox] exporting the app (about a minute)…")
    work = tempfile.mkdtemp(prefix="im2-apk-")
    proj, apk = os.path.join(work, "project"), os.path.join(work, "immersive2-debug.apk")
    os.mkdir(proj)
    for name in ("project.godot", "export_presets.cfg", "openxr_action_map.tres"):
        shutil.copy(os.path.join(CLIENT_DIR, name), proj)
    for name in ("scenes", "scripts", "shaders", "fonts", "addons"):
        shutil.copytree(os.path.join(CLIENT_DIR, name), os.path.join(proj, name))
    r = subprocess.run(["godot", "--headless", "--audio-driver", "Dummy", "--xr-mode", "off", "--path", proj,
                        "--install-android-build-template", "--export-debug", "Android", apk],
                       capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(apk):
        sys.exit("[sandbox] the export failed:\n" + (r.stdout + r.stderr)[-3000:])
    devices = [l.split()[0] for l in subprocess.run(["adb", "devices"], capture_output=True, text=True)
               .stdout.splitlines()[1:] if l.strip().endswith("device")]
    if not devices:
        print(f"[sandbox] no headset on adb: install it yourself with  adb install -r {apk}")
        return
    for serial in devices:
        r = subprocess.run(["adb", "-s", serial, "install", "-r", apk], capture_output=True, text=True)
        print(f"[sandbox] installed on {serial}" if r.returncode == 0
              else f"[sandbox] could not install on {serial}: {r.stdout.strip()} {r.stderr.strip()}")


class Status:
    """What the logs say about who watches whose screens (the s command)."""

    def __init__(self):
        self.lock = threading.Lock()
        self.pcs = {}      # PC name -> {client id: (name, encrypted)}
        self.watching = {}  # bot -> {whose: how}
        self.connects = {}  # bot -> {"ip:port": how} from its "Connecting to" lines

    def pc_line(self, pc, line):
        with self.lock:
            clients = self.pcs.setdefault(pc, {})
            m = re.search(r"Client (\d+) says hello: (.*) watching( \(encrypted\))?$", line)
            if m:
                clients[m.group(1)] = (m.group(2).strip() or "someone", bool(m.group(3)))
            m = re.search(r"Client (\d+) disconnected", line)
            if m:
                clients.pop(m.group(1), None)

    def bot_line(self, bot, line):
        with self.lock:
            # The watch connection says how it connects, then whose it is.
            m = re.search(r"Connecting to ([\d.]+:\d+)(.*)\.\.\.", line)
            if m:
                self.connects.setdefault(bot, {})[m.group(1)] = m.group(2).strip(" ()") or "not encrypted"
            m = re.search(r"\[Room\] watching (.+)'s screens at ([\d.]+:\d+)", line)
            if m:
                self.watching.setdefault(bot, {})[m.group(1)] = self.connects.get(bot, {}).get(m.group(2), "?")
            m = re.search(r"\[Room\] (.+) left", line)
            if m:
                self.watching.get(bot, {}).pop(m.group(1), None)

    def forget(self, bot):
        with self.lock:
            self.watching.pop(bot, None)

    def show(self):
        with self.lock:
            print("\n[sandbox] who watches whose screens")
            for bot, whose in self.watching.items():
                for who, how in whose.items():
                    print(f"  {bot} watches {who}'s PC: {how}")
            for pc, clients in self.pcs.items():
                for name, enc in clients.values():
                    print(f"  {pc} is watched by {name}: {'encrypted' if enc else 'NOT encrypted'}")
            if not any(self.watching.values()) and not any(self.pcs.values()):
                print("  nobody yet")
            print()


class Person:
    """A bot and its PC (a --stub host of its own)."""

    def __init__(self, name, tcp, monitors, extra, status):
        self.name, self.tcp, self.monitors, self.extra, self.status = name, tcp, monitors, extra, status
        self.pc = self.bot = None
        self.quit_file = ""

    def start_pc(self):
        self.pc = subprocess.Popen(["stdbuf", "-oL", HOST_BIN, "--stub", "--no-ui", "--no-usb", "--pin", "246810",
                                    "--tcp-port", str(self.tcp), "--udp-port", str(self.tcp + 1),
                                    "--audio-port", str(self.tcp + 2)],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                   env=private_config())  # an identity of its own, not this PC's
        pc = f"{self.name}'s PC"
        threading.Thread(target=self._echo, args=(self.pc, f"[{pc}]", ("watches", "refused", "watching"),
                                                  LOG.format(self.name.lower() + "-pc"),
                                                  lambda l: self.status.pc_line(pc, l)), daemon=True).start()

    def start_bot(self, room):
        self.status.forget(self.name)
        self.quit_file = os.path.join(tempfile.gettempdir(), f"immersive2-sandbox-{self.name.lower()}-{os.getpid()}.quit")
        if os.path.exists(self.quit_file):
            os.remove(self.quit_file)
        self.bot = subprocess.Popen(["godot", "--xr-mode", "off", "--path", CLIENT_DIR, "-s", BOT, "--",
                                     f"--bot-quit-file={self.quit_file}",
                                     "--im2-host=127.0.0.1", f"--im2-port={self.tcp}",
                                     f"--im2-udp-port={self.tcp + 1}", f"--im2-monitors={self.monitors}",
                                     f"--im2-name={self.name}", "--im2-share", *self.extra, *room],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        threading.Thread(target=self._echo, args=(self.bot, "", ("[Bot]", "[Room]", "SCRIPT ERROR", "(TLS"),
                                                  LOG.format(self.name.lower()),
                                                  lambda l: self.status.bot_line(self.name, l)), daemon=True).start()

    def stop_bot(self):
        """Leave the room cleanly (the others see it at once), then quit."""
        self.status.forget(self.name)
        if self.bot and self.bot.poll() is None:
            open(self.quit_file, "w").close()
            try:
                self.bot.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        stop(self.bot)
        if os.path.exists(self.quit_file):
            os.remove(self.quit_file)
        self.bot = None

    @staticmethod
    def _echo(proc, prefix, wanted, log, track):
        """Print the lines of `proc` that contain one of `wanted`; all go to `log`."""
        with open(log, "w") as f:
            for line in proc.stdout:
                f.write(line)
                f.flush()
                track(line.rstrip())
                if any(w in line for w in wanted):
                    print(f"{prefix} {line.rstrip()}".strip())


def stop(p):
    if p and p.poll() is None:
        p.send_signal(signal.SIGINT)  # a bot leaves the room cleanly
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()


def wrong_pin(room_ip):
    """Eve tries to join with a wrong PIN; prints what the room answered."""
    eve = subprocess.Popen(["godot", "--headless", "--xr-mode", "off", "--path", CLIENT_DIR, "--",
                            "--im2-name=Eve", f"--im2-room={room_ip}", "--im2-room-pin=999999"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    timer = threading.Timer(15, eve.kill)  # no answer: give up
    timer.start()
    answer = "no answer within 15 s"
    for line in eve.stdout:
        if "Wrong PIN" in line or "joined the room" in line:
            answer = line.strip()
            break
    timer.cancel()
    stop(eve)
    print(f"[sandbox] Eve: {answer}  (five wrong PINs lock this PC's address out for a minute: Cleo too)")


def main():
    sys.stdout.reconfigure(line_buffering=True)  # live, even into a pipe or a file
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt))
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = [a for a in sys.argv[1:] if a.startswith("--")]
    if not os.path.exists(HOST_BIN):
        sys.exit("build the host first: cmake --build host/build")
    room_ip, pin, ben_opens = "127.0.0.1", ROOM_PIN, True
    if args[:1] == ["join"] and len(args) == 3:
        room_ip, pin, ben_opens = args[1], args[2], False
    elif args or any(o not in ("--tone", "--switch-host", "--install", "--no-cleo") for o in opts):
        sys.exit(__doc__)
    if "--install" in opts:
        install_app()
    check_host("--switch-host" in opts)

    # Class names (Room, Participant…) need an up-to-date import cache.
    subprocess.run(["godot", "--headless", "--path", CLIENT_DIR, "--import"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    status = Status()
    ben = Person("Ben", 19900, "0,2", ["--im2-no-mic", "--bot-echo", "--bot-board", "--im2-board-open"], status)
    cleo = None if "--no-cleo" in opts else Person(
        "Cleo", 19930, "1", ["--im2-tone" if "--tone" in opts else "--im2-no-mic", "--im2-board", "--bot-guest"],
        status)
    people = [p for p in (ben, cleo) if p]
    for p in people:
        p.start_pc()
    time.sleep(1.0)
    join = [f"--im2-room={room_ip}", f"--im2-room-pin={pin}"]
    ben.start_bot(["--im2-room=open", f"--im2-room-pin={pin}"] if ben_opens else join)
    if cleo:
        time.sleep(4.0 if ben_opens else 0.0)  # the room is open before she knocks
        cleo.start_bot(join)
    where = "Ben opens a room on this PC" if ben_opens else f"they join the room at {room_ip}"
    print(f"[sandbox] {where}; PIN {pin[:3]} {pin[3:]}")
    print(CHECKLIST.format(pin=f"{pin[:3]} {pin[3:]}",
                           tone=" Cleo hums a tone from hers." if cleo and "--tone" in opts else ""))
    print("[sandbox] type c (Cleo leaves / comes back), e (wrong PIN), s (who watches what), h, q\n")
    try:
        for line in sys.stdin:
            cmd = line.strip().lower()
            if cmd == "q":
                break
            elif cmd == "h":
                print(CHECKLIST.format(pin=f"{pin[:3]} {pin[3:]}", tone=""))
            elif cmd == "s":
                status.show()
            elif cmd == "e":
                threading.Thread(target=wrong_pin, args=(room_ip,), daemon=True).start()
            elif cmd == "c" and cleo:
                if cleo.bot:
                    print("[sandbox] Cleo leaves the room")
                    cleo.stop_bot()
                else:
                    print("[sandbox] Cleo comes back")
                    cleo.start_bot(join)
            elif cmd:
                print("[sandbox] c, e, s, h or q")
        else:
            signal.pause()  # stdin closed (run in the background): until Ctrl+C
    except KeyboardInterrupt:
        pass
    finally:
        for p in people:
            p.stop_bot()
        for p in people:
            stop(p.pc)
        print("\n[sandbox] stopped")


if __name__ == "__main__":
    main()
