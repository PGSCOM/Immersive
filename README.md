# Immersive-2

Open-source alternative to Immersed — use your PC monitors in VR.

Immersive-2 creates virtual monitors on Windows (IDD driver), captures them via DXGI,
encodes with hardware GPU acceleration (NVENC / AMF / QSV), and streams over Wi-Fi to
a VR headset (Meta Quest, Pico 4) running a Godot 4 / OpenXR client that renders the
screens as floating panels. VR controller input (pointer, virtual keyboard) is sent
back to the PC.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        Windows Host                              │
│                                                                  │
│  ┌─────────────┐   ┌──────────────┐   ┌───────────────────────┐ │
│  │ IDD Virtual  │──▶│ DXGI Desktop │──▶│ GPU Encoder           │ │
│  │ Display      │   │ Capture      │   │ (NVENC / AMF / QSV)   │ │
│  │ Driver       │   └──────────────┘   └──────────┬────────────┘ │
│  └─────────────┘                                  │              │
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
│  │ (TCP ctrl + UDP vid) │   │ (MediaCodec H.264/H.265)         │ │
│  └──────────────────────┘   └──────────┬───────────────────────┘ │
│                                        ▼                         │
│  ┌──────────────────────┐   ┌──────────────────────────────────┐ │
│  │ Input Manager        │──▶│ OpenXR Screen Renderer           │ │
│  │ (pointer + keyboard) │   │ (floating panels in 3D space)    │ │
│  └──────────────────────┘   └──────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

## Project Structure

```
Immersive-2/
├── host/                    # Windows host application (C++)
│   ├── CMakeLists.txt
│   ├── include/             # Public headers
│   │   ├── capture/         # DXGI screen capture
│   │   ├── encoder/         # GPU video encoding
│   │   ├── network/         # Streaming server
│   │   ├── input/           # Input injection
│   │   └── driver/          # IDD driver interface
│   └── src/                 # Implementation
│       ├── capture/
│       ├── encoder/
│       ├── network/
│       ├── input/
│       └── driver/
├── client/                  # VR client (Godot 4 + OpenXR)
│   ├── project/             # Godot project files
│   ├── scripts/             # GDScript source
│   ├── scenes/              # Scene files (.tscn)
│   └── shaders/             # Custom shaders
├── protocol/                # Shared protocol definitions
├── docs/                    # Documentation
└── scripts/                 # Build and utility scripts
```

## Requirements

### Windows Host
- Windows 10/11
- Visual Studio 2022 or MinGW-w64
- CMake 3.20+
- GPU with hardware encoding support (NVIDIA, AMD, or Intel)

### VR Client
- Godot Engine 4.3+
- Meta Quest 2/3/Pro or Pico 4 headset
- OpenXR runtime

## Building

### Windows Host

```bash
cd host
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

### VR Client

1. Open the `client/project/` folder in Godot 4.3+
2. Install the OpenXR plugin if not already present
3. Configure export preset for Android (Quest/Pico)
4. Build and deploy to headset

## MVP Roadmap

- [x] Project structure and architecture
- [ ] Single monitor DXGI capture
- [ ] H.264 encoding via NVENC
- [ ] UDP streaming with basic protocol
- [ ] Godot VR client with single floating screen
- [ ] Basic pointer input return
- [ ] Multi-monitor support
- [ ] Virtual keyboard
- [ ] IDD virtual display driver
- [ ] Screen positioning and resizing in VR

## Protocol

See [protocol/README.md](protocol/README.md) for the wire protocol specification.

## License

MIT — see [LICENSE](LICENSE).
