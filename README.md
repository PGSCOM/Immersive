# Immersive-2

Open-source alternative to Immersed — use your PC monitors in VR.

Immersive-2 captures your PC's displays (Windows, Linux or macOS), encodes them
(hardware H.264/HEVC/AV1, or software MJPEG), and streams them over Wi-Fi or a
USB cable to a VR headset (Meta Quest, Pico 4) running a Godot 4 / OpenXR
client. There they become curved or flat screens arranged around you, in a
quiet night or dusk landscape or your own room (passthrough). Controllers,
hands, the VR keyboard or a Bluetooth keyboard drive the PC.

The headset finds the PC on the network by itself; the first connection asks
for the six-digit PIN the PC shows, so nobody else on the network can take
over your mouse and keyboard.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│              Host (Windows / Linux / macOS)                      │
│                                                                  │
│  ┌─────────────┐   ┌──────────────┐    ┌───────────────────────┐ │
│  │ IDD Virtual │──▶│ DXGI Desktop │──▶│ Video Encoder         │ │
│  │ Display     │   │ Capture      │    │ MJPEG (sw) / NVENC /  │ │
│  │ Driver      │   └──────────────┘    │ AMF / QSV (hw)        │ │
│  └─────────────┘                       └──────────┬────────────┘ │
│                                                   │              │
│                                                   ▼              │
│                                        ┌──────────────────────┐  │
│  ┌─────────────┐                       │ Network Server       │  │
│  │ Input       │◀──────────────────────│ (TCP control +       │  │
│  │ Injector    │                       │  UDP video stream)   │  │
│  └─────────────┘                       └──────────┬───────────┘  │
└───────────────────────────────────────────────────┼──────────────┘
                                                    │ Wi-Fi
┌───────────────────────────────────────────────────┼──────────────┐
│                       VR Client (Quest / Pico 4)  │              │
│                                                   ▼              │
│  ┌──────────────────────┐   ┌──────────────────────────────────┐ │
│  │ Network Client       │──▶│ Video Decoder                    │ │
│  │ (TCP ctrl + UDP vid) │   │ (MJPEG via Image.load_jpg_from_  │ │
│  └──────────────────────┘   │  buffer or MediaCodec H.264)     │ │
│                             └──────────┬───────────────────────┘ │
│                                        ▼                         │
│  ┌──────────────────────┐   ┌──────────────────────────────────┐ │
│  │ Input Manager        │──▶│ OpenXR Screen Renderer           │ │
│  │ (pointer + keyboard) │   │ (up to 3 floating panels)        │ │
│  └──────────────────────┘   └──────────────────────────────────┘ │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────────┐│
│  │ UI Overlay (toggle with B/Y or O key)                        ││
│  │  • Connection status   • Host IP field   • Monitor list      ││
│  │  • Latency indicator   • Connect button                      ││
│  └──────────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────┘
```

## Project Structure

```
Immersive-2/
├── host/                    # Host application (Windows, Linux, macOS)
│   ├── CMakeLists.txt
│   ├── include/
│   │   ├── capture/         # DXGI screen capture
│   │   ├── encoder/         # Video encoding (encoder.h + stb_image_write.h)
│   │   ├── network/         # Streaming server
│   │   ├── input/           # Input injection
│   │   └── driver/          # IDD driver interface
│   └── src/
│       ├── capture/         # dxgi_capture.cpp
│       ├── encoder/         # encoder.cpp (MJPEG + hw stubs)
│       ├── network/         # server.cpp (TCP control + UDP video/audio)
│       ├── input/           # input_injector.cpp
│       ├── driver/          # idd_manager.cpp
│       └── main.cpp
├── client/                  # VR client (Godot 4 + OpenXR)
│   ├── project/
│   │   ├── project.godot
│   │   ├── export_presets.cfg   # Windows Desktop + Android presets
│   │   └── openxr_action_map.tres
│   ├── scripts/             # (under project/)
│   │   ├── main.gd          # Scene controller: connect, pair, screens, arrangement, settings
│   │   ├── network_client.gd# TCP/UDP client, frame reassembly, latency, stats
│   │   ├── host_discovery.gd# Finds PCs on the LAN (UDP broadcast)
│   │   ├── screen_panel.gd  # A screen: flat or curved mesh, ray hits, grab
│   │   ├── laser_drag.gd    # Moving screens / menu / keyboard with a pointer
│   │   ├── ui_overlay.gd    # VR menu: Connect, Screens, Space, Quality
│   │   ├── ui_theme.gd      # Colours and type shared by menu and keyboard
│   │   ├── world.gd         # Sky, floor and light (night / dusk / void)
│   │   ├── video_decoder.gd # H.264/HEVC/AV1 via the MediaCodec plugin
│   │   ├── software_video_decoder.gd # MJPEG on a worker thread (PC / iOS / web)
│   │   ├── vr_input.gd      # Controller pointer, buttons, grab, scroll
│   │   ├── hand_input.gd    # Bare-hand pointer and pinch
│   │   ├── virtual_keyboard.gd # VR keyboard (full US layout)
│   │   ├── key_map.gd       # Bluetooth keyboard keys -> Windows VK codes
│   │   └── audio_receiver.gd   # Audio receiver + jitter buffer
│   ├── scenes/
│   │   ├── main.tscn        # XR origin, both controllers, keyboard
│   │   └── virtual_keyboard.tscn # Virtual keyboard scene
│   ├── shaders/
│   │   ├── screen.gdshader  # Screen (rounded corners, NV12)
│   │   ├── screen_external.gdshader # Same for the zero-copy MediaCodec texture
│   │   ├── sky.gdshader, floor.gdshader # The surroundings
│   └── tests/               # Headless / offscreen client tests (run by e2e_test.py)
├── protocol/
│   └── protocol.h           # Wire protocol (shared C++ header)
├── docs/
│   ├── ARCHITECTURE.md
│   ├── BUILDING.md
│   └── PROTOCOL.md
├── web/
│   ├── bridge/
│   │   └── bridge.js       # Node bridge: host TCP/UDP -> HTTP/MJPEG
│   ├── client/
│   │   ├── index.html      # Browser control UI + stream preview
│   │   ├── vr.html         # WebXR scene
│   │   ├── app.js
│   │   └── styles.css
│   └── README.md
└── .github/workflows/
  └── build.yml            # CI: Windows/Linux/macOS host + Godot client builds
```

## Requirements

### Host
- Windows 10/11 (x64) for full DXGI capture + SendInput + IDD features
- Linux (X11 or Wayland) or macOS 13+ — see [docs/BUILDING.md](docs/BUILDING.md) for the
  libraries and permissions
- CMake 3.20+
- Visual Studio 2022 / MinGW-w64 (Windows) or Clang/GCC (Linux/macOS)
- **No GPU encoder required** — the built-in MJPEG software encoder works on any CPU

### VR Client
- Godot Engine 4.7+
- Meta Quest 2/3/Pro or Pico 4 (developer mode enabled)
- Wi-Fi connection to the host machine, **or** a USB cable (needs `adb` from Android platform-tools on the host: PATH, `ANDROID_HOME`/`ANDROID_SDK_ROOT`, or the Android Studio SDK folder)

### Web Client (Optional)
- Node.js 20+
- Chromium-based browser with WebXR support (for `vr.html`)

## Quick Start

### 1. Build the Host

```powershell
cd host
cmake -B build -G "Visual Studio 17 2022" -A x64 ^
  -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build build --config Release
.\build\Release\immersive2_host.exe
```

Linux/macOS (see [docs/BUILDING.md](docs/BUILDING.md) for dependencies and permissions):

```bash
cd host
cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build build
./build/immersive2_host
```

The host listens on TCP :19800 (control) and UDP :19801 (video).

**No terminal needed.** While it runs, the host keeps an icon in the tray
(Windows notification area, macOS menu bar, the KDE tray or GNOME with the
*AppIndicator* extension). Click it, or pick **Open Immersive-2** in its menu,
for the settings window: the pairing PIN, the connected headsets (what each
one streams, at what fps and bitrate, with **Disconnect**), and switches for
remote control, the PIN, sound, USB, start at login, the default codec and
the virtual screens. On a desktop without a tray the window opens when the
host starts; launching the host again while it runs opens it too.

The window is a page the host serves on `127.0.0.1` only, opened as an app
window (Edge or Chrome `--app`, else the default browser), and only with the
random key the host puts in the address each run. Changes apply at once and
are kept in `host.conf` in the settings folder (`%APPDATA%\Immersive2`,
`~/.config/immersive2`); command-line options override them for one run.
`--no-ui` runs the host headless, exactly as a console program.

Useful host options:

| Option | Description |
| --- | --- |
| `--codec mjpeg\|h264\|h265\|av1` | Video codec. `mjpeg` (default) works with every client. The others use the hardware encoder (Media Foundation on Windows, VideoToolbox on macOS, FFmpeg NVENC/VAAPI — or libx264 — on Linux); on the client they need the MediaCodec plugin (`client/android-plugin`) — without it the client auto-falls back to MJPEG. If the GPU lacks the codec the host falls back (→ H.264 → MJPEG). |
| `--jpeg-quality N` | MJPEG quality 10–95 (default 35; raise it on fast networks). |
| `--no-audio` | Disable audio streaming. |
| `--max-clients N` | Maximum simultaneous VR clients (default 4). |
| `--pin NNNNNN` | Pairing PIN headsets must enter. By default one is generated once and kept in the settings folder (`%APPDATA%\Immersive2`, `~/.config/immersive2`). |
| `--no-pin` | No pairing: any device on the network may connect. |
| `--view-only` | Share the screens but ignore mouse and keyboard input from every headset (remote control off). |
| `--no-ui` | No tray icon and no settings window (servers, scripts, tests). |
| `--panel-port N` | Port of the settings window on 127.0.0.1 (default 19803; any free one if busy). |
| `--stub` | Fake displays, input only logged — protocol testing without a desktop. Ignores `host.conf`. |

These are only defaults: the VR client can override codec, bitrate, JPEG
quality, stream resolution and FPS at runtime from the menu's **Quality** tab
(STREAM_CONFIG message). The "Auto" resolution computes the ideal stream
width/FPS from the screen's size, its distance to the headset and the
headset's pixels-per-degree, so no bandwidth is wasted on detail the headset
cannot resolve.

> Note: if you run the Godot client on the **same machine** as the host, the
> client cannot bind UDP :19801 while the host is using it. Test from a second
> device, or change the video port on both sides.

### 2. Run the VR Client

**Desktop testing:**
1. Open `client/project/` in Godot 4.7+
2. Press **F5** to run
3. Press **O** to open the UI overlay
4. Enter the host IP and click Connect

**Export an APK (Quest / Pico):**

The Android preset uses gradle builds and bundles the MediaCodec decoder
plugin (`addons/im2_decoder/bin/*.aar`, built from `client/android-plugin`).
With the Android SDK + JDK 17 configured in the Godot editor settings:

```powershell
godot --headless --path client/project --export-debug "Android" client/dist/immersive2-debug.apk
adb install -r client/dist/immersive2-debug.apk
```

**Quest / Pico:**
1. Export via **Project → Export → Android**
2. Deploy to headset via `adb install`
3. Press **B/Y** in VR to open the UI overlay

CI builds publish an `immersive2_client_android` artifact containing a debug-signed `Immersive2.apk`; install it with `adb install -r Immersive2.apk`.

### 3. Connect

- The menu opens on **Connect** and lists the PCs running the host on your
  network. Press **Connect** next to yours (or type its address on the keypad).
- The first time, type the **PIN** the PC shows in its settings window (and in
  a notification when the headset asks). The headset
  remembers it, and on the next launch goes straight back to that PC.
- Your monitors appear as screens on an arc in front of you. Choose which ones
  on the **Screens** tab; **Arrange around me** and **Bring in front** tidy
  them up, and the system recenter (long press of the Meta/Pico button) brings
  them back in front.
- The PC needs TCP 19800 and UDP 19800 (discovery) open inbound in its
  firewall; see [docs/BUILDING.md](docs/BUILDING.md#firewall).

**Over USB instead of Wi-Fi:** enable USB debugging on the headset, plug it into
the PC and accept the prompt (tick "Always allow"). That's all: the host keeps an
`adb reverse` tunnel armed on every authorised headset, and the app finds the
PC through the cable by itself, at launch or while it streams over Wi-Fi, and
moves there (the menu's status line says "over USB" / "over Wi-Fi"). Pull the
cable and it goes straight back to Wi-Fi; plug it in again and it returns.
Video and audio travel in-band on TCP over the cable. The host finds `adb` on
its PATH or in the usual Android SDK folders, and its console says when a
headset is waiting for the USB debugging prompt. `--no-usb` turns this off.

### 4. Run the Web Client (WebXR)

```bash
node web/bridge/bridge.js --connect --host 127.0.0.1 --tcp-port 19800 --udp-port 19801 --port 19810
```

Then open:

- `http://localhost:19810/` (desktop controls + stream preview)
- `http://localhost:19810/vr.html` (WebXR scene)

## Key Bindings (Desktop Mode)

| Key | Action |
|-----|--------|
| `C` | Connect to host |
| `D` | Disconnect |
| `O` | Toggle the menu |
| `K` | Toggle the VR keyboard |
| `Esc` | Quit |

On the headset these keys are not shortcuts: a Bluetooth keyboard paired with
the headset types straight into the PC.

## VR Controls

Both controllers work the same way; the one whose trigger you pressed last
holds the pointer. Put them down (3 s still) and your bare hands take over;
pick one up and it has the pointer again.

| Action | Function |
|--------|----------|
| Trigger | Click (screens, menu, keyboard); hold to drag |
| Grip, short squeeze | Right click on a screen |
| Grip, hold | Grab the screen, menu or keyboard under the pointer and move it |
| Grip held + stick up/down | Push it away / pull it closer |
| Grip held + stick left/right | Resize the screen |
| Thumbstick | Scroll the screen or menu under the pointer |
| Thumbstick click | Middle click |
| A / X | Show / hide the VR keyboard |
| B / Y | Show / hide the menu |
| Right hand pinch (controllers down) | Pointer click/drag via hand tracking |
| Pinch on a bar, then turn the hand | Move the screen, menu or keyboard, and turn it |
| Thumb + middle finger pinch (index open) | Right click; hold and move the hand to scroll |
| Fingertip on the keyboard, menu or whiteboard | Type, press, draw |
| Left palm to your face, then pinch | Toggle the menu (its Keyboard button opens the keyboard) |

### Hand tracking on a standalone headset

Put the controllers down (still for 3 s) or switch them off: the bare hand takes
over. It needs three things, and the runtime is the strict one about all of them:

- `xr/openxr/extensions/hand_tracking = true` in `project.godot`. It is **off by
  default since Godot 4.4**, and it is what makes Godot request
  `XR_EXT_hand_tracking` at all.
- The Android manifest entries, which `addons/im2_decoder/im2_decoder.gd` writes
  at export time: `handtracking=1` and `pvr.app.type=vr`, plus
  `com.picovr.permission.HAND_TRACKING` on PICO (`oculus.software.handtracking`
  and `com.oculus.permission.HAND_TRACKING` on Quest). They used to be export
  options, but Godot removed them in 4.2, so setting them there does nothing.
- No controller in use. PICO has no `XR_META_simultaneous_hands_and_controllers`:
  it stops feeding joints while a controller is held.

If the hands never appear, read one line from logcat (`adb logcat -s godot`):

```
[HandInput] OpenXR hand tracking true|false
[HandInput] left hand joints tracked|none|- (source N)
```

`false` means the runtime is withholding it (check the manifest above); `none`
means Godot never registered `/user/hand_tracker/*`, which only happens when the
extension was not requested at all. `source 0` is `UNKNOWN` and is expected:
only some runtimes implement `XR_EXT_hand_tracking_data_source` (Quest and
SteamVR do, PICO 4 does not).

The VR keyboard is a full US layout (Esc, Tab, symbols, arrows, Ctrl, Alt,
Win); Shift, Ctrl, Alt and Win latch for the next key, and held keys repeat.

Clicks and grabs give a short vibration (Space tab → **Vibrate the
controllers**). **Control this PC** on the Connect tab turns remote control
off from the headset: you can still look and move screens, but nothing is
clicked or typed; a host started with `--view-only` enforces it for everyone.

### Virtual screens

A PC can add screens that exist only in the headset (Screens tab → **Add a
virtual screen**, 1080p to 4K; up to four, removable from the list). The host
creates them on X11 (an extra RandR monitor), on GNOME Wayland (Mutter's
virtual monitors) and on macOS (a virtual display, not yet tried on a real
Mac); other desktops answer that they can't. They are removed again when the host quits.

### Main screen off

Connect tab → **Turn off this PC's main screen** darkens the PC's main monitor
while you keep working on it in the headset (it still streams). It is never
saved: every connection starts with the screen on, and it comes back on by
itself when you switch it off, disconnect, take the headset off (the headset
stops renewing it and the PC waits 10 s) or quit the host. Works on X11 (gamma),
GNOME Wayland (gamma, and a laptop panel's backlight down to its minimum),
macOS (gamma, not yet tried on a real Mac) and Windows 10 2004+ (a black window
left out of the capture; the pointer and the Start menu still show over it).
Other Wayland desktops and view-only hosts don't offer it.

### Sharper text

Space tab → **Sharper text** draws each screen as an OpenXR compositor layer:
the headset's compositor samples the picture once, straight through the
lens correction, instead of after Godot has already resampled it into the
eye buffer. Godot punches a hole where the layer is, so the menu, keyboard and
pointer still draw in front. Off by default; turn it off again if a runtime
shows the screens wrong.

## MVP Roadmap

### Implemented ✓
- [x] Project structure and architecture
- [x] DXGI screen capture (interface + stub)
- [x] MJPEG software encoder (stb_image_write, no GPU required)
- [x] TCP control channel (HELLO, monitor list, stream start/stop)
- [x] UDP video streaming with chunk reassembly
- [x] Godot 4 VR client with OpenXR
- [x] Single floating screen panel
- [x] Pointer/mouse input return
- [x] Multi-monitor support (up to 3 simultaneous screens)
- [x] VR UI overlay (status, IP, monitor list, latency)
- [x] Screen repositioning with grip controller
- [x] Latency measurement (LATENCY_PROBE / LATENCY_RESPONSE)
- [x] Flow control (FRAME_ACK)
- [x] Auto-reconnect on disconnect
- [x] Host IP config persistence
- [x] USB connection (`adb reverse`, video/audio over TCP)
- [x] CI/CD (GitHub Actions: Windows host + Godot export)
- [x] Real DXGI frame capture (Desktop Duplication API)
- [x] Input injection (mouse + keyboard via SendInput)
- [x] Media Foundation hardware encoder (NVENC/AMF/QSV via MFT, Windows 8+)
- [x] Virtual keyboard in VR (QWERTY + modifiers, A/X button toggle)
- [x] Screen resize/scale in VR (grip + thumbstick Y)
- [x] Curved screens (real cylinder geometry, 0–100% in the menu)
- [x] LAN discovery of hosts, one-press connect, auto-reconnect to the last PC
- [x] PIN pairing (TOFU per headset; loopback/USB trusted; brute-force lockout)
- [x] Screens arranged on an arc; recenter (menu or system recenter); grab with push/pull and resize
- [x] Workspace kept automatically (monitors and positions, also across quality changes)
- [x] Surroundings: night / dusk / void landscapes, passthrough
- [x] Full VR keyboard with latching modifiers and key repeat; Bluetooth keyboard on the headset
- [x] Live status: delay, received fps and Mbps, connection details
- [x] Virtual screens (X11, GNOME Wayland, macOS) created from the headset
- [x] OpenXR compositor layers for sharper text (opt-in)
- [x] Turn the PC's main screen off from the headset (lit again without it)
- [x] Controller vibration on clicks and grabs
- [x] Remote control switch in the headset, and `--view-only` on the host
- [x] Host tray icon + settings window (PIN, headsets, live switches, start at login)
- [x] Mouse and keyboard in the WebXR scene
- [x] Hand tracking support (pinch pointer/click, no controllers required)
- [x] Workspace persistence (panel transform + monitor assignments, saved automatically)
- [x] macOS host (ScreenCaptureKit capture + audio, CGEvent input)
- [x] Linux host (X11: XShm + XTEST; Wayland: portal + PipeWire; PulseAudio/PipeWire audio)
- [x] Web client (WebXR + browser bridge)
- [x] Passthrough background mode (mixed reality in supported headsets)
- [x] Audio streaming (WASAPI loopback → UDP → AudioStreamGenerator)
- [x] Multi-client support (up to 4 simultaneous VR headsets, `--max-clients N`)
- [x] H.264 hardware decode on Android (MediaCodec path via Godot GPU Shader YUV→RGBA conversion)
- [x] IDD virtual display driver (Auto-creates self-signed certificates, no test-signing or WHQL required)

## Protocol

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the full wire protocol specification.

## Building

See [docs/BUILDING.md](docs/BUILDING.md) for detailed build instructions.

## License

MIT — see [LICENSE](LICENSE).
