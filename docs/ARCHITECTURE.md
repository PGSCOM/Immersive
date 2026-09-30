# Architecture

## System Overview

Immersive-2 is a virtual desktop system that streams your Windows PC screens
to VR headsets. It consists of two main components:

### Windows Host

The host application runs on your Windows PC and:

1. **Discovers monitors** — enumerates physical and virtual displays
2. **Captures screen content** — uses DXGI Desktop Duplication API
3. **Encodes video** — hardware-accelerated H.264/H.265 encoding
4. **Streams over network** — sends encoded video via UDP
5. **Receives input** — processes mouse/keyboard events from VR

#### Component Architecture

```
┌─────────────────────────────────────────────────┐
│                    main.cpp                      │
│           (orchestrates all components)          │
├──────────┬──────────┬───────────┬───────────────┤
│ DxgiCap  │ Encoder  │ NetServer │ InputInjector │
│          │          │           │               │
│ ID3D11   │ NVENC    │ TCP ctrl  │ SendInput     │
│ DXGI1.2  │ AMF      │ UDP video │ SetCursorPos  │
│ DDA      │ QSV      │ Winsock2  │               │
└──────────┴──────────┴───────────┴───────────────┘
```

### VR Client (Godot / OpenXR)

The client runs on VR headsets (and on a PC for testing) and:

1. **Finds the PC** — `host_discovery.gd` broadcasts on UDP 19800 and lists
   the hosts that answer; `main.gd` reconnects to the last PC on launch and
   follows it if its address changes.
2. **Pairs and connects** — TCP handshake with the host's PIN (asked once,
   remembered per PC), UDP video/audio (or everything over TCP on USB).
3. **Decodes video** — MediaCodec H.264/HEVC/AV1 straight into an
   ExternalTexture on Android; MJPEG on a worker thread elsewhere.
4. **Places the screens** — `screen_panel.gd` builds each screen as a flat
   quad or a real cylinder section (curvature), arranged on an arc around the
   head; positions persist per monitor and survive stream restarts.
5. **Takes input** — both controllers (`vr_input.gd`), bare hands
   (`hand_input.gd`), the VR keyboard (`virtual_keyboard.gd`) and, on the
   headset, a Bluetooth keyboard (`key_map.gd`).

#### Component Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                           main.gd                                │
│  connection · pairing · selection · arrangement · persistence    │
├───────────┬──────────┬─────────────┬─────────────┬──────────────┤
│ Network   │ Video    │ Screen      │ Input       │ UI + space   │
│ Client    │ Decoders │ Panel       │             │              │
│ + LAN     │ MediaCdc │ flat/curved │ vr_input    │ ui_overlay   │
│ discovery │ MJPEG    │ LaserDrag   │ hand_input  │ keyboard     │
│           │          │ shader      │ key_map     │ world (sky)  │
└───────────┴──────────┴─────────────┴─────────────┴──────────────┘
```

`ui_theme.gd` holds the colours and type shared by the menu and keyboard (the
same tokens as the web page). `laser_drag.gd` is how screens, menu and
keyboard are moved: the grabbed point stays on the pointer ray and the object
keeps facing the head.

## Data Flow

### Capture → Stream Pipeline

```
Monitor → DXGI DDA → BGRA Pixels → GPU Encoder → H.264 NALUs
                                                      │
                                                      ▼
                                              UDP Packetizer
                                                      │
                                              ┌───────┴───────┐
                                              │ Wi-Fi (5 GHz) │
                                              └───────┬───────┘
                                                      │
                                              UDP Reassembly
                                                      │
                                                      ▼
                                    H.264 NALUs → MediaCodec → RGBA Texture
                                                                    │
                                                                    ▼
                                                          3D Panel Shader
```

### Input Return Path

```
VR Controller → Ray → Panel UV → Pixel Coords → TCP Message
                                                      │
                                              ┌───────┴───────┐
                                              │ Wi-Fi (5 GHz) │
                                              └───────┬───────┘
                                                      │
                                              Host TCP Handler
                                                      │
                                                      ▼
                                              InputInjector
                                                      │
                                              SendInput / SetCursorPos
```

## Latency Budget

Target: < 30ms motion-to-photon for desktop interaction.

| Stage              | Target  | Notes                              |
|--------------------|---------|------------------------------------|
| DXGI capture       | < 2ms   | Desktop Duplication API            |
| GPU encode         | < 3ms   | NVENC hardware encoder             |
| Network (Wi-Fi 5G) | < 5ms   | Same room, 5 GHz Wi-Fi             |
| Decode             | < 3ms   | MediaCodec hardware decoder        |
| Render + display   | < 5ms   | Single frame at 72-90 Hz           |
| **Total**          | **< 18ms** | Well within 30ms budget         |

## IDD Virtual Display Driver

The IDD (Indirect Display Driver) creates virtual monitors that Windows
treats as real displays. This allows creating additional screens without
physical monitors.

The driver operates at the kernel level using the Windows IDD framework
and communicates with the user-mode host application via DeviceIoControl.

This is planned for a future milestone after the core streaming MVP.
