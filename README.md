# Immersive-2

Open-source alternative to Immersed — use your PC monitors in VR.

Immersive-2 captures PC displays via DXGI, encodes video (MJPEG software encoder or GPU hardware via NVENC/AMF/QSV when available), and streams over Wi-Fi to a VR headset (Meta Quest, Pico 4) running a Godot 4 / OpenXR client that renders the screens as floating panels. VR controller input is sent back to the PC.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│        Host (Windows full / Linux+macOS portable mode)           │
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
│  │ (TCP ctrl + UDP vid) │   │ (MJPEG sw / MediaCodec H.264)    │ │
│  └──────────────────────┘   └──────────┬───────────────────────┘ │
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

## Multi-User Shared VR Workspaces

Multiple users can share a VR space, see each other as avatars, and view all shared screens. A lightweight WebSocket signaling server (`signaling/server.py`) coordinates presence and WebRTC peer connections.

### Network topology

| Users in room | Mode | Description |
|---|---|---|
| 1–2 | P2P | Direct mesh — no relay server needed |
| 3+ | SFU relay | Server routes pose data; auto-migrates back to P2P when room drops below 3 |

### Privacy

- Screen sharing is **opt-in per monitor** — nothing is shared by default
- Revocation is immediate (stream stops within one frame)
- Logs contain only ephemeral session IDs and opaque monitor IDs — no IPs, names, or screen contents

## Project Structure

```
Immersive-2/
├── host/                    # Host application (Windows + Linux/macOS portable)
│   ├── CMakeLists.txt
│   ├── include/             # capture/ encoder/ network/ input/ driver/
│   └── src/                 # dxgi_capture, encoder (MJPEG+hw), server, input_injector, main.cpp
├── client/
│   ├── project/             # Godot 4.7 project
│   │   ├── scripts/         # main.gd, network_client.gd, screen_panel.gd, video_decoder.gd …
│   │   ├── scenes/          # main.tscn, virtual_keyboard.tscn
│   │   ├── shaders/         # screen.gdshader (ExternalTexture / MJPEG paths)
│   │   ├── addons/          # im2_decoder export plugin (bundles MediaCodec AAR)
│   │   └── test/            # Godot headless test suite (run_tests.gd + 3 suites)
│   └── android-plugin/      # Java/Gradle source for the Im2VideoDecoder AAR
├── signaling/               # Multi-user signaling server
│   ├── server.py            # WebSocket server (P2P ↔ SFU topology)
│   ├── sfu_server.py        # SFU relay entry point (extends server.py)
│   ├── requirements.txt     # websockets>=10,<15
│   └── test_server.py       # Python unittest suite (6 tests)
├── protocol/
│   └── protocol.h           # Wire protocol (shared C++ header — source of truth)
├── web/
│   ├── bridge/bridge.js     # Node bridge: host TCP/UDP → HTTP/MJPEG/H.264
│   └── client/              # index.html (2D preview) + vr.html (WebXR scene)
├── docs/
│   ├── ARCHITECTURE.md
│   ├── BUILDING.md
│   └── PROTOCOL.md
└── .github/workflows/
    ├── build.yml            # CI: host (Win/Linux/macOS) + tests + Godot export
    └── deploy_webxr_pages.yml  # Deploy web/client to GitHub Pages
```

## Requirements

### Host
- Windows 10/11 (x64) for full DXGI capture + SendInput + IDD features
- Linux/macOS for portable host mode (network/protocol development)
- CMake 3.20+, Visual Studio 2022 / GCC / Clang
- No GPU encoder required — the built-in MJPEG software encoder works on any CPU

### VR Client
- Godot Engine 4.7+
- Meta Quest 2/3/Pro or Pico 4 (developer mode enabled)
- Wi-Fi connection to the host machine

### Signaling server (multi-user only)
- Python 3.10+
- `pip install -r signaling/requirements.txt` (`websockets>=10,<15`)

### Web client (optional)
- Node.js 20+
- Chromium-based browser with WebXR support

## Quick Start

### 1. Build and run the host

**Windows:**
```powershell
cmake -S host -B host/build -G "Visual Studio 17 2022" -A x64 `
  -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build host/build --config Release
.\host\build\Release\immersive2_host.exe
```

**Linux / macOS (portable mode):**
```bash
cmake -S host -B host/build -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build host/build
./host/build/immersive2_host
```

The host listens on TCP 19800 (control) and UDP 19801 (video) by default.

**Useful host flags:**

| Flag | Description |
|---|---|
| `--codec mjpeg\|h264\|h265\|av1` | Video codec. `mjpeg` works on every client. H.264/H.265/AV1 use a GPU encoder (NVENC/AMF/QSV); the client auto-falls back to MJPEG if the plugin is absent. |
| `--jpeg-quality N` | MJPEG quality 10–95 (default 35; raise on fast Wi-Fi). |
| `--no-audio` | Disable audio streaming. |
| `--max-clients N` | Max simultaneous headsets (default 4). |

The VR client can override codec, JPEG quality, stream resolution and FPS at runtime from the overlay's **Stream quality** panel (STREAM_CONFIG). The "✨ Auto" mode computes the ideal resolution from panel size, distance, and headset PPD.

### 2. Run the VR client

**Desktop (no headset, for testing):**
1. Open `client/project/` in Godot 4.7+
2. Press **F5** to run
3. Press **O** to open the UI overlay
4. Enter the host IP and click **Connect**

**Android APK (Quest / Pico):**

With Android SDK + JDK 17 configured in the Godot editor:
```bash
godot --headless --path client/project \
  --export-debug "Android" client/dist/immersive2-debug.apk
adb install -r client/dist/immersive2-debug.apk
```

CI builds publish a ready-to-install `immersive2_client_android` artifact on every push.

On the headset: press **B/Y** to open the overlay, enter the host IP, select a monitor.

> If you run the Godot client on the same machine as the host, the client cannot bind UDP 19801 while the host holds it. Test from a second device or change the video port on both sides.

### 3. Connect and stream

1. Open the overlay (B/Y on headset, O on desktop)
2. Enter the host PC's local IP
3. Click **Connect**
4. Select a monitor from the list
5. The monitor appears as a floating panel — grab and reposition it with the grip button

### 4. Multi-user session (optional)

Start the signaling server on any machine reachable by all headsets:

```bash
pip install -r signaling/requirements.txt
python signaling/server.py          # default port 19810
# or for SFU relay mode (3+ users):
python signaling/sfu_server.py      # port 19811
```

Each VR client joins the same room by entering the signaling server address in the overlay's **Room** field. With two users the system uses a direct P2P connection; a third user triggers automatic migration to SFU relay mode.

### 5. Web client (optional)

```bash
node web/bridge/bridge.js \
  --connect --host 127.0.0.1 \
  --tcp-port 19800 --udp-port 19801 --port 19810
```

Then open:
- `http://localhost:19810/` — desktop controls + MJPEG stream preview
- `http://localhost:19810/vr.html` — WebXR scene (H.264 via WebCodecs, falls back to MJPEG)

## Key Bindings

### Desktop mode

| Key | Action |
|---|---|
| `O` | Toggle UI overlay |
| `C` | Connect |
| `D` | Disconnect |
| `Esc` | Quit |

### VR controls

| Action | Function |
|---|---|
| B / Y | Toggle UI overlay |
| Right trigger | Click / interact |
| Right grip (hold) | Grab and reposition panel |
| Right grip + thumbstick Y | Scale panel up/down |
| Right thumbstick | Scroll |
| A / X (left controller) | Toggle virtual keyboard |
| Right hand pinch | Pointer click/drag (hand tracking, no controller) |
| Left hand pinch-hold | Toggle overlay (hand tracking) |

## Running Tests

**Godot test suite (headless):**
```bash
godot --headless --xr-mode off \
  --path client/project -s res://test/run_tests.gd
# Expected: Total Passed: 159 / Total Failed: 0
```

**Python signaling tests:**
```bash
python -m unittest discover -v signaling/
# Expected: Ran 6 tests … OK
```

CI runs both suites on every push before building the export artifacts.

## Implemented Features

- DXGI screen capture (Windows) + portable stubs (Linux/macOS)
- MJPEG software encoder (stb_image_write, no GPU required)
- Media Foundation hardware encoder (NVENC/AMF/QSV via MFT, Windows 8+)
- TCP control channel + UDP video streaming with chunk reassembly
- Godot 4 VR client (OpenXR, Quest + Pico 4)
- Up to 3 simultaneous floating screen panels
- Pointer/mouse + keyboard input injection (SendInput)
- VR UI overlay (status, IP, monitor list, latency, stream quality)
- Grab/resize/curve panels in VR
- Virtual QWERTY keyboard in VR
- Eye-tracking foveated rendering (OpenXR eye gaze + head-gaze fallback)
- Hand tracking support (pinch pointer, no controllers required)
- Workspace save/restore (panel transforms + monitor assignments)
- Auto-reconnect on disconnect
- Latency measurement (LATENCY_PROBE / LATENCY_RESPONSE)
- Flow control (FRAME_ACK)
- H.264/HEVC/AV1 hardware decode on Android (MediaCodec zero-copy via ExternalTexture)
- Software MJPEG decode on PC/iOS/web (WorkerThreadPool, no native plugin)
- Audio streaming (WASAPI loopback → UDP → AudioStreamGenerator)
- Multi-client support (up to 4 simultaneous headsets, `--max-clients N`)
- IDD virtual display driver integration
- Passthrough/mixed-reality background mode
- Web client (WebXR + Node bridge, H.264 via WebCodecs)
- Multi-user shared VR workspaces (WebSocket signaling, P2P mesh / SFU relay)
- Per-monitor opt-in screen sharing with immediate revocation

## Protocol

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the full wire protocol specification. The authoritative source is [`protocol/protocol.h`](protocol/protocol.h).

## Building

See [docs/BUILDING.md](docs/BUILDING.md) for detailed build instructions including the Android MediaCodec plugin and IDD virtual display driver.

## License

MIT — see [LICENSE](LICENSE).
