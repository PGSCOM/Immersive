# Immersive-2 Wire Protocol

This document describes the network protocol used between the Windows host and the VR client.

All multi-byte integers are **little-endian** unless noted otherwise.

---

## Transport

| Channel | Protocol | Default Port | Direction    | Purpose           |
|---------|----------|-------------|--------------|-------------------|
| Control | TCP      | 19800       | Bidirectional| Handshake, control, input |
| Video   | UDP      | 19801       | Host → Client| Video frame chunks |

---

## Control Channel (TCP)

All control messages use a **TLV (Type-Length-Value)** framing:

```
 0       1       2       3       4       5      5+length
 +-------+-------+-------+-------+-------+... ...+
 | type  |     length (uint32 LE)        | payload|
 +-------+-------+-------+-------+-------+... ...+
```

- **type**: 1 byte — `MessageType` enum value
- **length**: 4 bytes LE — payload byte count (0 for empty messages)
- **payload**: `length` bytes — message-specific data

---

## Message Types

### `0x01` HELLO — Client → Host

Sent immediately after TCP connection is established.

```
 0         1                      33
 +---------+----------------------+
 | version | client_name[32]      |
 +---------+----------------------+
```

| Field | Type | Description |
|-------|------|-------------|
| version | uint8 | Protocol version (currently 1) |
| client_name | char[32] | UTF-8 null-terminated display name |

---

### `0x02` HELLO_ACK — Host → Client

Response to HELLO.

```
 0         1         3         4
 +---------+---------+---------+
 | version | udp_port| mon_cnt |
 +---------+---------+---------+
```

| Field | Type | Description |
|-------|------|-------------|
| version | uint8 | Protocol version |
| udp_port | uint16 LE | UDP port for video stream |
| monitor_count | uint8 | Number of monitors (informational; full list follows) |

---

### `0x03` MONITOR_LIST — Host → Client

Sent after HELLO_ACK to enumerate available displays.

```
Payload: uint8 count + count × MonitorInfo
```

**MonitorInfo** (70 bytes):
```
 0         1         3         5         6                   70
 +---------+---------+---------+---------+-------------------+
 | id      | width   | height  | refresh | name[64]          |
 +---------+---------+---------+---------+-------------------+
```

| Field | Type | Description |
|-------|------|-------------|
| monitor_id | uint8 | Unique monitor ID |
| width | uint16 LE | Resolution width |
| height | uint16 LE | Resolution height |
| refresh_rate | uint8 | Refresh rate (Hz) |
| name | char[64] | UTF-8 display name |

---

### `0x04` MONITOR_SELECT — Client → Host

Request to stream a single monitor.

```
 0
 +---------+
 | mon_id  |
 +---------+
```

---

### `0x05` STREAM_START — Host → Client

Confirms stream is starting for a monitor.

```
 0         1         3         5         6
 +---------+---------+---------+---------+
 | mon_id  | width   | height  | codec   |
 +---------+---------+---------+---------+
```

| Field | Type | Description |
|-------|------|-------------|
| monitor_id | uint8 | Monitor being streamed |
| width | uint16 LE | Frame width |
| height | uint16 LE | Frame height |
| codec | uint8 | 0=H.264, 1=H.265/HEVC, 2=MJPEG, 3=AV1 |

---

### `0x06` STREAM_STOP — Host → Client

Notifies the client that the stream of a specific monitor has stopped
(e.g. the monitor was deselected via MONITOR_SELECT / MULTI_MONITOR_SELECT).

| Field | Type | Description |
|-------|------|-------------|
| monitor_id | uint8 | Monitor whose stream ended |

Clients should treat an empty payload (legacy) as "all streams stopped".

---

### `0x10` INPUT_MOUSE — Client → Host

Mouse input event on a specific monitor.

```
 0         1         3         5         6         8
 +---------+---------+---------+---------+---------+
 | mon_id  | x       | y       | buttons | scroll  |
 +---------+---------+---------+---------+---------+
```

| Field | Type | Description |
|-------|------|-------------|
| monitor_id | uint8 | Target monitor |
| x | uint16 LE | Pixel X coordinate |
| y | uint16 LE | Pixel Y coordinate |
| buttons | uint8 | Bitmask: bit0=left, bit1=right, bit2=middle |
| scroll_delta | int16 LE | Vertical scroll amount |

---

### `0x11` INPUT_KEYBOARD — Client → Host

Keyboard input event.

```
 0         1         3         4         5
 +---------+---------+---------+---------+
 | mon_id  | scancode| pressed | mods    |
 +---------+---------+---------+---------+
```

| Field | Type | Description |
|-------|------|-------------|
| monitor_id | uint8 | Target monitor (for focus) |
| scancode | uint16 LE | USB HID scancode |
| pressed | uint8 | 1=key down, 0=key up |
| modifiers | uint8 | Bitmask: bit0=Shift, bit1=Ctrl, bit2=Alt |

---

### `0x20` MULTI_MONITOR_SELECT — Client → Host

Select up to 3 monitors simultaneously.

```
 0         1         2         3         4
 +---------+---------+---------+---------+
 | count   | id[0]   | id[1]   | id[2]   |  + 1 reserved byte
 +---------+---------+---------+---------+
```

| Field | Type | Description |
|-------|------|-------------|
| monitor_count | uint8 | Number of valid IDs (0–3) |
| monitor_ids[3] | uint8[3] | Monitor IDs; unused slots = 0xFF |
| _reserved | uint8 | Reserved, must be 0 |

The host reconciles its active streams with the full selection: monitors not
listed are stopped (each acknowledged with STREAM_STOP), new ones are started
(STREAM_START), already-streaming ones continue untouched. `monitor_count = 0`
stops all streams.

---

### `0x21` STREAM_CONFIG — Client → Host

Stream quality settings. Applies to all streams; the host restarts the active
streams in place (new STREAM_START per monitor, no STREAM_STOP) so the change
takes effect immediately.

| Field | Type | Description |
|-------|------|-------------|
| codec | uint8 | 0 = H.264, 1 = H.265/HEVC, 2 = MJPEG, 3 = AV1, 0xFF = host default. If the host cannot encode the requested codec it falls back (→ H.264 → MJPEG) and announces the actual codec in STREAM_START. |
| bitrate_kbps | uint32 LE | H.264 bitrate; 0 = host default |
| jpeg_quality | uint8 | MJPEG quality 10–95; 0 = host default |
| max_width | uint16 LE | Downscale streams to this width (aspect preserved, host clamps to native); 0 = native resolution |
| max_fps | uint8 | FPS cap; 0 = auto (display refresh for H.264, 24 for MJPEG) |

When a stream is downscaled the host announces the scaled dimensions in
STREAM_START and maps incoming INPUT_MOUSE coordinates (which are in stream
pixels) back to native monitor pixels.

---

### `0x30` FRAME_ACK — Client → Host

Acknowledges receipt of a video frame. Used for flow control.

```
 0         1         5
 +---------+---------+
 | mon_id  | frame # |
 +---------+---------+
```

| Field | Type | Description |
|-------|------|-------------|
| monitor_id | uint8 | Monitor for which frame is acked |
| frame_number | uint32 LE | Frame number being acknowledged |

---

### `0x40` LATENCY_PROBE — Client → Host

Round-trip latency measurement. The host echoes it back as `LATENCY_RESPONSE`.

```
 0                   8                   16
 +-------------------+-------------------+
 | probe_id (uint64) | client_ts (uint64) |
 +-------------------+-------------------+
```

| Field | Type | Description |
|-------|------|-------------|
| probe_id | uint64 LE | Unique probe ID (monotonic) |
| client_timestamp | uint64 LE | Client microsecond timestamp |

---

### `0x41` LATENCY_RESPONSE — Host → Client

Echo of `LATENCY_PROBE` with server timestamp added.

```
 0                   8                   16                  24
 +-------------------+-------------------+-------------------+
 | probe_id (uint64) | client_ts (uint64) | server_ts (uint64)|
 +-------------------+-------------------+-------------------+
```

| Field | Type | Description |
|-------|------|-------------|
| probe_id | uint64 LE | Echoed from probe |
| client_timestamp | uint64 LE | Echoed from probe |
| server_timestamp | uint64 LE | Server microsecond timestamp |

**RTT calculation** (client side):
```
rtt_ms = (Time.get_ticks_usec() - client_timestamp) / 1000.0
```

---

### `0xFF` PING

Empty payload heartbeat. Either side may send; the receiver echoes it back.

---

## Video Channel (UDP)

Video frames are split into UDP datagrams of at most **1400 bytes** each.

### Packet Format

```
 0         1         5         7         9         9+N
 +---------+---------+---------+---------+--- ...---+
 | mon_id  | frame # | chunk # | total # | payload  |
 +---------+---------+---------+---------+--- ...---+
```

| Field | Size | Description |
|-------|------|-------------|
| monitor_id | 1 byte | Which monitor this frame belongs to |
| frame_number | 4 bytes LE | Frame sequence number (wraps at 2^32) |
| chunk_index | 2 bytes LE | Zero-based chunk index |
| chunk_count | 2 bytes LE | Total chunks for this frame |
| payload | 1–1400 bytes | Encoded video data slice |

**Total header size**: 9 bytes.

### Frame Reassembly

A frame is complete when `chunks_received == chunk_count`.
Frames that are never completed (due to packet loss) should be discarded after
receiving a frame with a higher `frame_number`.

### Video Codecs

| Value | Name | Description |
|-------|------|-------------|
| 0 | H.264 | Hardware encoder (NVENC/AMF/QSV) — not yet implemented |
| 1 | H.265 | Hardware encoder — not yet implemented |
| 2 | MJPEG | Software encoder (stb_image_write); default in CI builds |

MJPEG frames are valid JPEG files. The client decodes them with
`Image.load_jpg_from_buffer()` (Godot) or `stb_image.h` (C++).

---

## Connection Sequence

```
Client                                   Host
  |                                        |
  |--- TCP connect ----------------------->|
  |--- HELLO (0x01) ---------------------->|
  |<-- HELLO_ACK (0x02) -------------------|
  |<-- MONITOR_LIST (0x03) ----------------|
  |                                        |
  |--- MONITOR_SELECT (0x04, id=1) ------->|
  |<-- STREAM_START (0x05, id=1) ----------|
  |                                        |
  |<== UDP video frames ==================|
  |--- FRAME_ACK (0x30) ----------------->|
  |                                        |
  |--- LATENCY_PROBE (0x40) ------------->|
  |<-- LATENCY_RESPONSE (0x41) ------------|
  |                                        |
  |--- INPUT_MOUSE (0x10) --------------->|
  |--- INPUT_KEYBOARD (0x11) ------------>|
  |                                        |
  |--- STREAM_STOP (0x06) (optional) ----->|
  |--- TCP disconnect -------------------->|
```

---

## Version History

| Version | Changes |
|---------|---------|
| 1 (current) | Initial protocol: HELLO handshake, monitor list, single-monitor stream, mouse/keyboard input, MJPEG video, latency probing, multi-monitor select, frame ACK |
