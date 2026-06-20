# Immersive-2

Open-source alternative to Immersed — use your PC monitors in VR.

Immersive-2 captures PC displays via DXGI, encodes video (MJPEG software encoder
or GPU hardware via NVENC/AMF/QSV when available), and streams over Wi-Fi to a
VR headset (Meta Quest, Pico 4) running a Godot 4 / OpenXR client that renders the
screens as floating panels. VR controller input is sent back to the PC.

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

## Multi-User Shared VR Workspaces

Immersive-2 now supports multi-user shared VR workspaces where several people can share a VR space, see each other as avatars, and view all shared screens arranged in each user's monitor layout.

### Network Topology

- **1–2 users:** Direct P2P mesh (no media server)
- **3+ users:** SFU server routes streams
- **Automatic migration:** Seamless transition between P2P and SFU when the 3rd user joins or leaves

### Privacy

- **End-to-end encryption:** Media is encrypted with E2EE (XOR stream cipher for MVP, SRTP/DTLS for transport)
- **Opt-in screen sharing:** Users choose which monitors to share, with immediate revocation
- **No PII logging:** Only ephemeral session IDs and monitor IDs are logged

### Supported Clients

- **VR Headsets:** Meta Quest, Pico 4 (OpenXR)
- **Desktop:** Flat-screen client for non-VR users
- **Mobile:** Touch-friendly mobile client

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
├── host/                    # Host application (Windows + Linux/macOS portable)
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
│       ├── network/         # server.cpp, tcp_control.cpp, udp_stream.cpp
│       ├── input/           # input_injector.cpp
│       ├── driver/          # idd_manager.cpp
│       └── main.cpp
├── client/                  # VR client (Godot 4 + OpenXR)
│   ├── project/
│   │   ├── project.godot
│   │   ├── export_presets.cfg   # Windows Desktop + Android presets
│   │   └── openxr_action_map.tres
│   ├── scripts/
│   │   ├── main.gd          # Scene controller, multi-monitor, auto-reconnect
│   │   ├── network_client.gd# TCP/UDP client + latency probing
│   │   ├── screen_panel.gd  # Virtual screen panel (drag + resize + MJPEG decode)
│   │   ├── ui_overlay.gd    # VR UI (status, IP, monitors, ping)
│   │   ├── video_decoder.gd # MJPEG / H.264 MediaCodec decoder
│   │   ├── vr_input.gd      # VR controller input handler
│   │   ├── virtual_keyboard.gd # VR QWERTY keyboard
│   │   └── audio_receiver.gd   # UDP audio receiver + AudioStreamGenerator
│   ├── scenes/
│   │   ├── main.tscn        # Main scene (3 screen slots + UI overlay + keyboard)
│   │   └── virtual_keyboard.tscn # Virtual keyboard scene
│   └── shaders/
│       └── screen.gdshader  # Custom screen shader
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
- Linux/macOS for portable host mode (network/protocol development and testing)
- CMake 3.20+
- Visual Studio 2022 / MinGW-w64 (Windows) or Clang/GCC (Linux/macOS)
- **No GPU encoder required** — the built-in MJPEG software encoder works on any CPU

### VR Client
- Godot Engine 4.6.3+
- Meta Quest 2/3/Pro or Pico 4 (developer mode enabled)
- Wi-Fi connection to the host machine

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

Linux/macOS (portable host mode):

```bash
cd host
cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build build
./build/immersive2_host
```

The host listens on TCP :19800 (control) and UDP :19801 (video).

Useful host options:

| Option | Description |
| --- | --- |
| `--codec mjpeg\|h264\|h265\|av1` | Video codec. `mjpeg` (default) works with every client. The others use the GPU encoder (NVENC/AMF/QSV via Media Foundation); on the client they need the MediaCodec plugin (`client/android-plugin`) — without it the client auto-falls back to MJPEG. If the GPU lacks the codec the host falls back (→ H.264 → MJPEG). |
| `--jpeg-quality N` | MJPEG quality 10–95 (default 35; raise it on fast networks). |
| `--no-audio` | Disable audio streaming. |
| `--max-clients N` | Maximum simultaneous VR clients (default 4). |

These are only defaults: the VR client can override codec, bitrate, JPEG
quality, stream resolution and FPS at runtime from the overlay's
**Stream quality** section (STREAM_CONFIG message). The "✨ Auto" resolution
mode computes the ideal stream width/FPS from the panel size, its distance to
the headset and the headset's pixels-per-degree, so no bandwidth is wasted on
detail the headset cannot resolve.

> Note: if you run the Godot client on the **same machine** as the host, the
> client cannot bind UDP :19801 while the host is using it. Test from a second
> device, or change the video port on both sides.

### 2. Run the VR Client

**Desktop testing:**
1. Open `client/project/` in Godot 4.6.3+
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

- Enter the host PC's local IP in the overlay
- Click **Connect**
- Select a monitor from the list
- The monitor streams as a floating panel in VR

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
| `O` | Toggle UI overlay |
| `Esc` | Quit |

## VR Controls

| Action | Function |
|--------|----------|
| B / Y button | Toggle UI overlay |
| Right trigger | Click / interact with UI |
| Right grip (hold) | Grab and reposition screen panel |
| Right grip + thumbstick Y | Scale screen panel up/down |
| Right thumbstick | Scroll (when pointer is on screen) |
| A / X button (left controller) | Toggle virtual QWERTY keyboard |
| Right hand pinch (no controller) | Pointer click/drag via hand tracking |
| Left hand pinch-hold (no controller) | Toggle UI overlay |

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
- [x] CI/CD (GitHub Actions: Windows host + Godot export)
- [x] Real DXGI frame capture (Desktop Duplication API)
- [x] Input injection (mouse + keyboard via SendInput)
- [x] Media Foundation hardware encoder (NVENC/AMF/QSV via MFT, Windows 8+)
- [x] Virtual keyboard in VR (QWERTY + modifiers, A/X button toggle)
- [x] Screen resize/scale in VR (grip + thumbstick Y)
- [x] Curved screen mode (toggle + strength control in VR overlay)
- [x] Eye-tracking based foveated rendering (OpenXR eye gaze + head-gaze fallback)
- [x] Hand tracking support (pinch pointer/click, no controllers required)
- [x] Workspace save/restore (panel transform + monitor assignments)
- [x] macOS/Linux host support (portable mode + CI builds)
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
