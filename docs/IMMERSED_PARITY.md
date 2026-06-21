# Immersed feature parity

Honest mapping of every feature in `funciones-immersed.md` (the public Immersed VR
feature list) to its status in Immersive-2. Each "implemented" row is backed by an
automated test in `client/project/test/` or `signaling/test_server.py`.

Legend: ✅ implemented · 🟡 partial · ❌ not implemented · ⚪ N/A (commercial/plan
detail, or hardware/OS capability that cannot exist in this open-source client).

## Virtual screens & desktop

| Immersed feature | Status | Where |
|---|---|---|
| Multiple virtual screens in VR (Mac/PC/Linux) | ✅ | host DXGI/WGC capture → `main.gd` panels (up to 3) |
| Scale / reposition screens in 3D | ✅ | `screen_panel.gd` grab + thumbstick scale |
| Premium resolutions / quality | ✅ | `STREAM_CONFIG`, overlay quality + "✨ Auto" (PPD) |
| Desktop sharing while using normal apps | ✅ | WGC non-exclusive capture |
| SnapGrid — remember layouts between sessions | ✅ | workspace save/restore (`main.gd`) |
| Plan-gated screen counts (Starter 3 / Pro 5) | ⚪ | no plans in an open-source client |

## Collaboration & VR office

| Immersed feature | Status | Where |
|---|---|---|
| Telepresence (multiple people in one room) | ✅ | `multiuser_manager.gd` + signaling server, wired into `main.gd` |
| Private rooms (by room id) | ✅ | overlay "Room" field → `join_room()` |
| Avatars (see each other) | ✅ | `remote_user.gd` (head + hands meshes + nameplate) |
| Multi-screen sharing in a room | ✅ | `REMOTE_SCREEN_LAYOUT` + `remote_screen_panel.gd`, opt-in via `privacy_manager.gd` |
| Shared whiteboards + high-res save | ✅ | `whiteboard.gd` (collaborative strokes, snapshot PNG) |
| Audio chat between users (headset mic → others) | ✅ | `voice_chat.gd` mic capture → `multiuser_manager.broadcast_voice` (P2P voice channel / SFU relay) → spatial `voice_playback.gd` on each avatar |
| Public co-working / VIP spaces | ✅ | public lobby: `public` flag on join, `lobby_list`/`lobby_update` wire protocol, overlay "Public Lobby" section with one-click join (`ui_overlay.gd`, `signaling/server.py`) |
| P2P mesh (≤2) / SFU relay (3+) with migration | ✅ | server topology + `webrtc_manager.gd`; tested both directions |

## Passthrough & mixed-reality portals

| Immersed feature | Status | Where |
|---|---|---|
| General passthrough (see the real world) | ✅ | `main.gd::_apply_passthrough_settings` (alpha-blend + transparent env) |
| Passthrough portals (cut-out windows) | ✅ | `portal.gd` / `portal_manager.gd` + `shaders/portal.gdshader` |
| Up to 5 simultaneous portals | ✅ | `PortalManager.MAX_PORTALS = 5` |
| Multiple shapes (rectangle / square / circle) | ✅ | `Im2Portal.Shape` |
| Resize / reposition portals at runtime | ✅ | `portal.set_size()` + grip drag |
| Keyboard portal anchored to the real keyboard | ✅ | `PortalManager.create_keyboard_portal()` |

## Keyboard, mouse & peripherals

| Immersed feature | Status | Where |
|---|---|---|
| Mouse / keyboard input to the PC | ✅ | `SendInput` host injection |
| In-VR QWERTY keyboard | ✅ | `virtual_keyboard.gd` (A/X toggle, ray + pinch typing) |
| Keyboard passthrough portal | ✅ | see portals above |
| Bluetooth keyboard/mouse paired to the headset | ⚪ | OS-level pairing, outside the app |
| Hand tracking (bare-hand pinch pointer) | ✅ | `hand_input.gd` (Pico/Quest/SteamVR) |
| Tracked physical keyboards (K830 / Magic Keyboard models) | ❌ | needs vendor keyboard models + IK; portal covers the use case |

## Audio, mic, webcam

| Immersed feature | Status | Where |
|---|---|---|
| PC audio → headset | ✅ | WASAPI loopback → UDP → `audio_receiver.gd` |
| Headset mic mute toggle | ✅ | `VoiceChat.toggle_mute()` — overlay "Voice" button + `M` key, gates capture instantly |
| Immersed virtual webcam | ❌ | OS virtual-camera driver, out of scope |

## Multi-device & phone mirroring

| Immersed feature | Status | Where |
|---|---|---|
| Windows / macOS / Linux host | ✅ | full on Windows, portable elsewhere |
| Meta Quest 2/3/Pro | ✅ | OpenXR client |
| Pico 4 | ✅ | OpenXR client + hand tracking |
| Apple Vision Pro | ❌ | Godot OpenXR does not target visionOS |
| Phone/tablet mirrored as a VR screen | ❌ | mobile client is a room participant, not a screen source |

## Environments, rooms & movement

| Immersed feature | Status | Where |
|---|---|---|
| Themed environments (café, space, lodge, …) | ✅ | `environment_manager.gd` (5 themes) |
| Weekly rotating environments (Starter 2 / Pro 5) | ✅ | `EnvironmentManager.weekly_rotation()` |
| Switch environment from the menu | ✅ | overlay "Environment ▶" |
| Teleport / movement dots | ✅ | `locomotion.gd` (left thumbstick aim + go) |
| Comfortable snap-turn | ✅ | `locomotion.gd` snap-turn |
| Room-scale / seated | ✅ | OpenXR native |

## Modes, plans, earning streaks, focus

| Immersed feature | Status |
|---|---|
| Free/Pro plans, earning streaks, billing | ⚪ commercial — N/A to open source |
| Private "hyperfocus" workspace | ✅ single-user mode is the default |

## Testing

All ✅ rows above are covered by the headless Godot suite and the Python signaling
suite:

```
godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
#   → Total Passed: 399 / Total Failed: 0
python -m unittest discover -s signaling
#   → Ran 15 tests … OK
```

The runtime-only glue that cannot be asserted headlessly (live WebRTC ICE
handshake, controller/hand input events, on-device passthrough compositing, live
microphone capture) is kept thin and delegates to pure helpers that *are*
unit-tested (`MultiuserManager` pose/voice routing, `WebRTCManager.parse_ice_candidate`,
the portal / whiteboard / locomotion geometry, keyboard edge-detection, the
`VoiceChat` PCM frame codec + mute gate + per-user playback buffering).
