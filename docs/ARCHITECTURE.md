# Architecture

## System Overview

Immersive-2 is a virtual desktop system that streams your Windows PC screens
to VR headsets. It consists of two main components:

### Windows Host

The host application runs on your Windows PC and:

1. **Discovers monitors** — enumerates physical and virtual displays
2. **Captures screen content** — uses DXGI Desktop Duplication API
3. **Encodes video** — hardware-accelerated H.264/H.265 encoding
4. **Streams over network** — sends encoded video via UDP, adapting the
   bitrate (and MJPEG's frame rate) to the link from the client's frame
   ACKs, below the client's settings; a CPU encoder is paced to what it
   sustains. Bitrate / quality / fps changes apply to the running encoder
   without restarting the stream (see STREAM_CONFIG in PROTOCOL.md)
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

#### Tray icon and settings window (`host/src/ui/`)

The host's persistent UI, off with `--no-ui`. It never runs on a streaming
thread:

- **Settings** (`host_ui.h`): the switches the panel changes live, as atomics
  that `main.cpp` reads where it used to read its CLI variables (view-only,
  default codec and JPEG quality, sound, USB, PIN). Loaded from `host.conf`,
  overridden by CLI flags; the panel writes back only the key it changed.
- **Panel** (`panel.cpp` + `panel.html`): one thread serving a small HTTP
  API on 127.0.0.1 only. Access needs the per-run token (in the URL the host
  opens, then an HttpOnly SameSite=Strict cookie); the Host header must name
  the panel (DNS rebinding) and requests carrying another Origin are refused;
  POSTs also need an `X-Im2-Panel` header. It reads state through `Hooks`
  lent by `main.cpp` (monitors, streams with frame/byte counters, virtual
  screen removal) and changes the server live through `INetworkServer`
  (`set_pin`, `set_host_flags`, which re-sends HELLO_ACK, `clients`,
  `disconnect_client`).
- **Tray** (`tray_win.cpp` Shell_NotifyIcon on its own thread,
  `tray_mac.mm` NSStatusItem pumped from the main loop through
  `HostUi::pump()`, `tray_linux.cpp` a StatusNotifierItem + dbusmenu on a
  private session-bus connection): status line, PIN, Open, Quit. Without a
  tray the panel opens at startup; `panel-url` in the settings folder lets a
  second launch open the running host's window.
- On a Wayland session the panel shows when the desktop refused remote
  control (`portal::input_denied()`) and "Ask again" forgets the restore
  token and restarts the portal session (`portal::ask_again()`).

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
6. **Shares a room**: several people, each with their own PC, see each
   other's avatars, talk, and watch the screens each one shares
   (`room.gd`, `participant.gd`, see below).

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

## Multiplayer rooms

No server and no account: a room is a handful of headsets talking directly.

```
   Ana's PC ──────── video (watch) ────────────┐
      │ her own stream                         ▼
   Ana's headset ◄══ room (ENet, UDP 19820) ══► Ben's headset
   (opened the room,  poses · voice · profiles      │ his own stream
    relays the rest)                             Ben's PC ── video (watch) ──► Ana's headset
```

- **The room** (`room.gd`) is Godot's high-level multiplayer over ENet. One
  headset opens it (UDP 19820, `--im2-room-port` in tests) and relays between
  the others; it also answers LAN discovery on 19821, so the Room tab lists
  it. Joining takes its address and its six-digit PIN (SceneMultiplayer
  authentication; five wrong PINs lock an address out for a minute). Over the
  internet that means a VPN (Tailscale, ZeroTier...) or a forwarded port: the
  room and each sharer's PC must be reachable. If the headset that opened the
  room leaves, the room closes.
- **What goes through it**: each person's *profile* (name, microphone on or
  off, how to watch their PC, where their shared screens hang) when it
  changes; their *pose* (head and both hands, relative to their XROrigin3D,
  30 times a second, unreliable); their *voice* (microphone on a muted bus
  with an AudioEffectCapture, mixed to mono, box-filtered to 16 kHz, 20 ms
  PCM-16 packets, only while it passes a noise gate). About 3 KB/s of poses
  and 32 KB/s of voice per person talking.
- **Screens never go through the room.** A headset that shares sends its PC a
  random WATCH_CODE and, once the host has it, tells the room the PC's
  address, port and code. Everyone else connects to that PC directly as a
  *watcher* (`protocol.h` `HELLO_FLAG_WATCH`) and gets the same encoded frames
  the sharer gets, fanned out by the host: no second encode, no relay through
  a headset, the sharer's own rate control. A watcher can do nothing but
  watch. Sharing is off by default and never saved.
- **Seats** (`Room.seat()`): everyone in one row, ordered by peer id, 3.2 m
  apart, facing the same way. Each `Participant` node sits at its seat; under
  it, the avatar and the shared screens are in that person's own tracking
  space, as they sent them. A shared screen can be grabbed by its bar and
  brought closer; from then on it stays where it was put, here only.
- **Avatars** (`participant.gd`): a head wearing a headset, shoulders and a
  chest that turns after the head, two mitts where the controllers (or bare
  hands) are, and the name, brighter while they speak; one colour per seat
  (`UiTheme.PEOPLE`), the same colour their name has in the menu. Their voice
  plays from their head (AudioStreamPlayer3D).

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
