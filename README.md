# Immersive-2

Open-source alternative to Immersed — use your PC monitors in VR.

Immersive-2 captures PC displays via DXGI, encodes video (MJPEG software encoder
or GPU hardware via NVENC/AMF/QSV when available), and streams over Wi-Fi to a
VR headset (Meta Quest, Pico 4) running a Godot 4 / OpenXR client that renders the
screens as floating panels. VR controller input is sent back to the PC.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        Windows Host                              │
│                                                                  │
│  ┌─────────────┐   ┌──────────────┐   ┌───────────────────────┐ │
│  │ IDD Virtual  │──▶│ DXGI Desktop │──▶│ Video Encoder         │ │
│  │ Display      │   │ Capture      │   │ MJPEG (sw) / NVENC /  │ │
│  │ Driver       │   └──────────────┘   │ AMF / QSV (hw)        │ │
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
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │ UI Overlay (toggle with B/Y or O key)                        │ │
│  │  • Connection status   • Host IP field   • Monitor list      │ │
│  │  • Latency indicator   • Connect button                      │ │
│  └──────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

## Project Structure

```
Immersive-2/
├── host/                    # Windows host application (C++)
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
│   │   ├── screen_panel.gd  # Virtual screen panel (drag + MJPEG decode)
│   │   ├── ui_overlay.gd    # VR UI (status, IP, monitors, ping)
│   │   ├── video_decoder.gd # Video frame decoder
│   │   └── vr_input.gd      # VR controller input handler
│   ├── scenes/
│   │   └── main.tscn        # Main scene (3 screen slots + UI overlay)
│   └── shaders/
│       └── screen.gdshader  # Custom screen shader
├── protocol/
│   └── protocol.h           # Wire protocol (shared C++ header)
├── docs/
│   ├── ARCHITECTURE.md
│   ├── BUILDING.md
│   └── PROTOCOL.md
└── .github/workflows/
    └── build.yml            # CI: Windows host + Godot client builds
```

## Requirements

### Windows Host
- Windows 10/11 (x64)
- Visual Studio 2022 or MinGW-w64
- CMake 3.20+
- **No GPU encoder required** — the built-in MJPEG software encoder works on any CPU

### VR Client
- Godot Engine 4.3+
- Meta Quest 2/3/Pro or Pico 4 (developer mode enabled)
- Wi-Fi connection to the Windows host

## Quick Start

### 1. Build the Windows Host

```powershell
cd host
cmake -B build -G "Visual Studio 17 2022" -A x64 ^
  -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build build --config Release
.\build\Release\immersive2_host.exe
```

The host listens on TCP :19800 (control) and UDP :19801 (video).

### 2. Run the VR Client

**Desktop testing:**
1. Open `client/project/` in Godot 4.3+
2. Press **F5** to run
3. Press **O** to open the UI overlay
4. Enter the host IP and click Connect

**Quest / Pico:**
1. Export via **Project → Export → Android**
2. Deploy to headset via `adb install`
3. Press **B/Y** in VR to open the UI overlay

### 3. Connect

- Enter the host PC's local IP in the overlay
- Click **Connect**
- Select a monitor from the list
- The monitor streams as a floating panel in VR

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
| Right thumbstick | Scroll (when pointer is on screen) |

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

### In Progress
- [ ] Real DXGI frame capture (DDA API)
- [ ] NVENC / AMF / QSV hardware encoder integration
- [ ] Input injection (mouse + keyboard via SendInput)

### Planned
- [ ] Virtual keyboard in VR
- [ ] IDD virtual display driver (for custom resolutions)
- [ ] H.264 decode via MediaCodec on Android
- [ ] Screen resize/scale in VR
- [ ] Audio streaming
- [ ] Multi-client support

## Protocol

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the full wire protocol specification.

## Building

See [docs/BUILDING.md](docs/BUILDING.md) for detailed build instructions.

## License

MIT — see [LICENSE](LICENSE).
