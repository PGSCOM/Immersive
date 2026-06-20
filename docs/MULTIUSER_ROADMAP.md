# Multi-User Shared VR Workspace — Implementation Roadmap

## Overview
Extend Immersive-2 from a single-user VR desktop streamer to a multi-user shared VR workspace where several people share a VR space, see each other as avatars, and view all shared screens arranged in each user's monitor layout.

## Architecture Decisions (Locked)
- **Topology:** 1–2 users → P2P mesh; 3+ users → SFU. Automatic seamless migration.
- **Privacy:** E2EE media (insertable streams / SFrame), opt-in revocable screen sharing, no PII logging.
- **Protocol:** Extend `protocol/protocol.h` first, then mirror in GDScript.
- **Testing:** Every milestone ends with a passing test. Godot runs use `--headless --xr-mode off`.

---

## Milestone 1: Protocol Extension for Multi-User Signaling

**Goal:** Extend the wire protocol to support room operations, user presence, and pose data.

### New Message Types (protocol.h)
- `0x50 ROOM_JOIN` — Client → Server: request to join a room (room_id[16], display_name[32])
- `0x51 ROOM_JOINED` — Server → Client: joined successfully (room_id, user_id, participant list)
- `0x52 ROOM_LEFT` — Server → Client: a user left (user_id)
- `0x53 USER_PRESENCE` — Server → Client: user list update (user_id, display_name, is_local)
- `0x54 USER_POSE` — Bidirectional: head + hand transforms (user_id, head[7], left_hand[7], right_hand[7])
- `0x55 SCREEN_SHARE_STATE` — Client → Server: which monitors are shared (monitor_ids[3], enabled)
- `0x56 REMOTE_SCREEN_LAYOUT` — Server → Client: another user's monitor layout (user_id, monitor_count, MonitorInfo[])
- `0x57 MONITOR_LAYOUT_UPDATE` — Client → Server: update relative positions/sizes of monitors

### Files to Modify
- `protocol/protocol.h` — add structs and message types
- `docs/PROTOCOL.md` — document new messages

### Acceptance
- `protocol.h` compiles with host build
- GDScript mirror matches byte layout

---

## Milestone 2: Signaling Server + Room Join/Leave + Presence

**Goal:** Implement a WebSocket-based signaling server that manages rooms, user presence, and pose relay.

### Why WebSocket?
The existing TCP protocol is host-centric (one host, one client). For multi-user rooms we need a lightweight signaling layer that can run independently and bridge to the existing host streaming. WebSocket gives us:
- Full-duplex messaging over HTTP-friendly ports
- Easy to implement P2P offer/answer and SFU signaling
- Simple to test with Python/JavaScript clients

### Components
1. **`signaling/server.py`** — Asyncio/WebSocket signaling server
   - Room management (create, join, leave, destroy when empty)
   - User presence tracking (user_id, display_name, connection state)
   - Pose relay (broadcast USER_POSE to all room participants)
   - Screen share state relay
   - Monitor layout relay

2. **`signaling/test_server.py`** — Integration tests
   - Connect 2 peers, verify room join
   - Verify presence broadcast
   - Verify pose relay
   - Disconnect, verify room cleanup

### Files to Create
- `signaling/server.py`
- `signaling/test_server.py`
- `signaling/requirements.txt`

### Acceptance
- `python signaling/test_server.py` passes
- 2 simulated peers can join a room and see each other's presence

---

## Milestone 3: P2P Mesh Media for 2 Users (Encrypted)

**Goal:** When 2 users are in a room, establish direct WebRTC P2P connections for media (screen streams + audio).

### Components
1. **WebRTC P2P connection manager** (Godot/GDScript)
   - Use Godot 4's built-in WebRTC support (`WebRTCPeerConnection`)
   - Signaling via the WebSocket signaling server
   - Data channel for pose updates (lower latency than TCP relay)
   - Media tracks for screen sharing (via `WebRTCMediaStream` or custom data channels)

2. **E2EE with Insertable Streams**
   - Use WebRTC Insertable Streams API for end-to-end encryption
   - Each participant generates a shared key via ECDH
   - SFU cannot decrypt (only routes encrypted packets)

### Files to Create
- `client/project/scripts/webrtc_manager.gd`
- `client/project/scripts/e2ee_crypto.gd`
- `client/project/test/test_p2p_mesh.gd`

### Acceptance
- 2 simulated peers join a room and exchange media tracks
- Integration test verifies track arrival
- Wireshark/tcpdump confirms DTLS-SRTP encryption

---

## Milestone 4: SFU for 3+ Users + Automatic Mesh↔SFU Migration

**Goal:** When a 3rd user joins, seamlessly migrate from P2P mesh to SFU. When dropping back to 2, migrate back to P2P.

### Components
1. **SFU Server** (`signaling/sfu_server.py`)
   - Selective forwarding of video/audio tracks
   - Uses `aiortc` for WebRTC SFU functionality
   - Routes encrypted packets (no decryption)

2. **Topology Manager** (Godot/GDScript)
   - Config constant: `P2P_MAX_USERS = 2`
   - Detects user count changes
   - Orchestrates migration without dropping streams

### Files to Create
- `signaling/sfu_server.py`
- `signaling/test_sfu.py`
- `client/project/scripts/topology_manager.gd`

### Acceptance
- Integration test: 3 peers join, verify SFU mode
- 1 peer leaves, verify migration back to P2P
- No black screens during migration

---

## Milestone 5: Remote Screen Panels from Monitor-Layout Metadata

**Goal:** In the Godot scene, reconstruct remote users' shared screens using their monitor layout metadata.

### Components
1. **RemoteUser scene** (`client/project/scenes/remote_user.tscn`)
   - Avatar (head + hands from pose data)
   - Screen panels for each shared monitor
   - Layout applied from REMOTE_SCREEN_LAYOUT messages

2. **RemoteScreenPanel** (`client/project/scripts/remote_screen_panel.gd`)
   - Receives video stream from WebRTC track
   - Applies user's monitor layout (position, size, resolution)

### Files to Create
- `client/project/scenes/remote_user.tscn`
- `client/project/scripts/remote_user.gd`
- `client/project/scripts/remote_screen_panel.gd`
- `client/project/test/test_remote_screens.gd`

### Acceptance
- Godot test (`--headless --xr-mode off`) creates remote user with 2 screens
- Layout matches metadata

---

## Milestone 6: Hardware Decode H.264/H.265/AV1 on PC and iOS

**Goal:** Implement and verify hardware decode paths for all target platforms.

### PC (Windows/Linux)
- Use FFmpeg with hwaccel (D3D11VA, DXVA2, or Vulkan)
- Or use Media Foundation via custom GDExtension

### iOS
- Use VideoToolbox via custom GDExtension or FFmpeg

### Android
- Verify existing MediaCodec plugin works for H.264/H.265/AV1
- Add assertions that HW path is selected

### Files to Create/Modify
- `client/project/scripts/video_decoder.gd` — add platform detection
- `client/project/test/test_hw_decode.gd`

### Acceptance
- Test asserts HW decoder is active per (platform, codec)
- Falls back to software MJPEG if HW unavailable

---

## Milestone 7: Privacy — E2EE Media, Consent/Revocation, No-PII Logging

**Goal:** Ensure privacy requirements are met and tested.

### Components
1. **E2EE Media**
   - SFrame or Insertable Streams for all media
   - Key rotation
   - SFU routes only encrypted data

2. **Consent/Revocation**
   - UI toggle per screen to share/unshare
   - Clear indicator of what is being shared
   - Immediate effect on revocation

3. **No-PII Logging**
   - Audit all log statements
   - Remove or hash any identifying info
   - Test assertions that no PII appears in logs

### Files to Create
- `client/project/scripts/privacy_manager.gd`
- `client/project/test/test_privacy.gd`
- `docs/PRIVACY.md`

### Acceptance
- Privacy test passes
- Screen sharing toggle works in Godot test
- Log audit shows no PII

---

## Milestone 8: Flat-Screen Client (Desktop)

**Goal:** Non-VR desktop users can join the same rooms.

### Components
1. **Flat-screen scene** (`client/project/scenes/flat_main.tscn`)
   - 3D view without XR initialization
   - Mouse/keyboard input for navigation
   - Same networking as VR client

### Files to Create
- `client/project/scenes/flat_main.tscn`
- `client/project/scripts/flat_main.gd`
- `client/project/test/test_flat_client.gd`

### Acceptance
- Godot test runs flat client headless
- Can join room and see remote users

---

## Milestone 9: Mobile Client (Touch UX)

**Goal:** Phone users can join rooms with touch-friendly UI.

### Components
1. **Mobile scene** (`client/project/scenes/mobile_main.tscn`)
   - Touch controls for camera rotation
   - Simplified UI for room join/leave
   - Same networking as VR client

### Files to Create
- `client/project/scenes/mobile_main.tscn`
- `client/project/scripts/mobile_main.gd`

### Acceptance
- Godot test runs mobile client headless
- Touch input simulation works

---

## Milestone 10: Docs + Final Green Run

**Goal:** Update all documentation and run the full test suite.

### Files to Update
- `README.md` — multi-user features, architecture
- `docs/ARCHITECTURE.md` — add multi-user section
- `docs/PROTOCOL.md` — document all new messages
- `docs/PRIVACY.md` — privacy model

### Acceptance
- Full Godot suite passes (`--headless --xr-mode off`)
- Host builds and smoke test passes
- Networking integration tests pass (mesh@2, SFU@3, migration)
- HW decode assertions pass
- Privacy assertions pass
