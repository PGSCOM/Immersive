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

The client runs on VR headsets and:

1. **Initializes XR** — sets up OpenXR stereo rendering
2. **Connects to host** — TCP handshake + UDP video reception
3. **Decodes video** — MediaCodec H.264/H.265 decoding
4. **Renders screens** — floating 3D panels in VR space
5. **Sends input** — controller pointer and virtual keyboard events

#### Component Architecture

```
┌──────────────────────────────────────────────────┐
│                   main.gd                        │
│           (scene controller)                     │
├──────────┬──────────┬────────────┬──────────────┤
│ Network  │ Video    │ Screen     │ VR Input     │
│ Client   │ Decoder  │ Panel      │              │
│          │          │            │              │
│ TCP/UDP  │ MediaCdc │ PlaneMesh  │ XRController │
│ protocol │ H264/265 │ Shader     │ Raycast      │
└──────────┴──────────┴────────────┴──────────────┘
```

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
