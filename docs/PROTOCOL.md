# Immersive-2 Wire Protocol

This document describes the network protocol used between the host (Windows, Linux or macOS) and the VR client.

All multi-byte integers are **little-endian** unless noted otherwise.

---

## Transport

| Channel | Protocol | Default Port | Direction    | Purpose           |
|---------|----------|-------------|--------------|-------------------|
| Control | TCP      | 19800       | Bidirectional| Handshake, control, input |
| Video   | UDP      | 19801       | Host → Client| Video frame chunks |
| Audio   | UDP      | 19802       | Host → Client| PCM-16 stereo 48 kHz system audio |
| Discovery | UDP    | 19800       | Client ↔ Host| LAN discovery (a separate namespace from the TCP control port) |

The host's UDP socket is send-only and binds an ephemeral port; the client owns
19801/19802 for receiving. (Binding them on the host too would stop a client on
the same machine from receiving video at all.)

**Encryption.** A client on another machine wraps the control connection in
**TLS 1.2** (ECDHE-ECDSA with AES-GCM or ChaCha20-Poly1305, nothing else):
the host tells the two apart by the first byte, `0x16` (a TLS handshake
record) or `0x01` (HELLO). Everything below then runs inside TLS unchanged.
The host refuses plain TCP from anywhere but `127.0.0.0/8` with
`REJECT_ENCRYPTION_REQUIRED`, unless it runs with `--allow-plaintext` (older
apps). The host's certificate is its identity: self-signed, ECDSA P-256,
`CN=immersive-host`, made once and kept in the settings folder
(`identity-key.pem`, `identity-cert.pem`). Its **fingerprint** is the first 8
bytes of the SHA-256 of the certificate (DER) in hex, in groups of four
(`C175 98B2 31A4 9F12`); the host prints it, shows it next to the PIN, and the
headset shows it on its PIN prompt. Over TLS, UDP video and audio are sealed
with a key the host sends in `MEDIA_KEY`, see [Sealed datagrams](#sealed-datagrams).
How the headset pins the certificate is in `docs/SECURITY.md`.

**TCP media mode (USB).** A client that sets `HELLO_FLAG_TCP_MEDIA` in HELLO gets
no UDP at all: video and audio arrive on the control socket as `VIDEO_FRAME`
(0x50) and `AUDIO_DATA` (0x51) messages. This is how a headset on a USB cable
works — the host runs `adb -s <serial> reverse tcp:19800 tcp:19800` on each
authorised device, the headset connects to its own `127.0.0.1:19800`, and
`adb reverse` can only tunnel TCP. The headset looks for the tunnel by itself
with a plain HELLO to `127.0.0.1` (a HELLO_ACK means a host answers; the
connection is then closed) and moves its session there.

Over TCP a frame is never lost, only queued, so the host limits each
monitor to 4 frames sent and not yet acknowledged by `FRAME_ACK` (the client
ACKs each frame as it reads it) and drops whole frames beyond that; the client
sees the gap in frame numbers and asks for a keyframe. A client that never
sends `FRAME_ACK` is not limited.

---

## LAN Discovery (UDP)

The host listens on **UDP `<tcp_port>`** (19800 by default). A client finds
hosts without an IP by broadcasting a request there (to `255.255.255.255` and
to its subnet's `x.y.z.255`); every host answers the sender with a unicast
reply. Sending broadcasts and reading unicast replies needs no multicast lock
on Android.

**DiscoveryRequest** (5 bytes): `magic` uint32 LE = `0x3F324D49` ("IM2?"),
`protocol_version` uint8.

**DiscoveryReply** (73 bytes):

| Field | Type | Description |
|-------|------|-------------|
| magic | uint32 LE | `0x21324D49` ("IM2!") |
| protocol_version | uint8 | |
| tcp_port | uint16 LE | Control port to connect to |
| monitor_count | uint8 | Number of displays |
| flags | uint8 | Bit 0 `DISCOVERY_FLAG_PIN`: connecting needs the pairing PIN. Bit 1 `DISCOVERY_FLAG_VIEW_ONLY`: the PC shares its screens but takes no input (`--view-only`) |
| host_name | char[64] | The PC's name, UTF-8, NUL-padded |

---

## Pairing

Everything the host does — sending the desktop, injecting mouse and keyboard
— waits for a HELLO that passed the pairing check:

- Connections from **127.0.0.1** are trusted: a process on the PC itself, or a
  headset on the USB cable (`adb reverse`, which the headset authorised).
- Everyone else must put the host's **PIN** in HELLO. The host prints it at
  start-up; by default it is six random digits created once and kept in the
  settings folder (`%APPDATA%\Immersive2\pairing-pin`,
  `~/.config/immersive2/pairing-pin`). `--pin NNNNNN` sets it, `--no-pin`
  turns pairing off.
- Over TLS the host sends `IDENTITY` (its certificate) before it answers the
  HELLO, so a headset can learn it with a HELLO without PIN, then reconnect
  pinned to it and only then send the PIN (`docs/SECURITY.md`).
- A wrong PIN costs half a second; five from one address lock it out for a
  minute (`REJECT_LOCKED_OUT`). Past 20 wrong PINs in a minute from all
  addresses together, each further one costs 5 s.
- Any other message before an accepted HELLO drops the connection. A socket
  that sends no accepted HELLO within 5 s is closed, and `--max-clients`
  counts paired clients only, so idle connections cannot lock a headset out.
- Mouse and keyboard input is only taken from the client that owns the
  streams (the last one to select monitors); when that client goes away the
  host releases any button or key it was holding.

The client remembers the PIN per PC and sends it on every connection.

**Watchers.** In a multiplayer room (see `docs/ARCHITECTURE.md`) a headset can
let the others watch what this PC streams to it, without the PIN: it sends
WATCH_CODE with a random code, and a HELLO with `HELLO_FLAG_WATCH` and that
code in the PIN field gets in (wrong codes cost and lock out like wrong PINs).
A watcher receives STREAM_START / STREAM_STOP for each screen the sharing
headset streams, and a copy of its own of each: MJPEG (every client decodes
it), at most 1280 wide and 8 fps, encoded on a thread of its own from the
frames the PC streams to the sharer, sent to the watcher's own UDP port. The
sharer's stream (codec, bitrate, keyframes) never depends on who watches, and
a watcher never needs a keyframe. It never gets the monitor list or the PC's
sound, and nothing it sends is acted on but LATENCY_PROBE and PING. A new
code, code 0, or the sharing headset leaving drops every watcher. Watchers do
not count toward `--max-clients`.

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
 0         1                      33       34                38                40
 +---------+----------------------+--------+-----------------+-----------------+
 | version | client_name[32]      | flags  | pin (uint32 LE) | udp_port (u16)  |
 +---------+----------------------+--------+-----------------+-----------------+
```

| Field | Type | Description |
|-------|------|-------------|
| version | uint8 | Protocol version (currently 1) |
| client_name | char[32] | UTF-8 null-terminated display name |
| flags | uint8 | Optional (older clients send 33 bytes = 0). Bit 0 `HELLO_FLAG_TCP_MEDIA`: send video/audio on this TCP socket instead of UDP. Bit 1 `HELLO_FLAG_WATCH`: only watch, see [Pairing](#pairing). Bit 2 `HELLO_FLAG_IDENTITY`: send `IDENTITY` on a plain connection too (over TLS it always comes) |
| pin | uint32 LE | Optional (absent = 0 = none). The pairing PIN, see [Pairing](#pairing); with `HELLO_FLAG_WATCH`, the watch code |
| udp_port | uint16 LE | Optional (absent = 0 = the host's UDP port). Only read with `HELLO_FLAG_WATCH`: the UDP port a watcher picked for its video. Other clients always get video at the host's UDP port, whatever they put here |

The host answers with HELLO_ACK, then MONITOR_LIST (and AUDIO_START when it
captures audio) — or with HELLO_REJECT and closes.

---

### `0x02` HELLO_ACK — Host → Client

Response to HELLO.

```
 0         1         3         4                  68        69                 73
 +---------+---------+---------+------------------+---------+------------------+
 | version | udp_port| mon_cnt | host_name[64]    | flags   | lan_ipv4 (u32)   |
 +---------+---------+---------+------------------+---------+------------------+
```

| Field | Type | Description |
|-------|------|-------------|
| version | uint8 | Protocol version |
| udp_port | uint16 LE | UDP port for video stream |
| monitor_count | uint8 | Number of monitors (informational; full list follows) |
| host_name | char[64] | Optional (older hosts send 4 bytes). The PC's name, UTF-8 |
| flags | uint8 | Optional (absent = 0). Bit 0 `HOST_FLAG_VIEW_ONLY`: mouse/keyboard input is ignored (`--view-only`, or "Let headsets control this PC" off in the host's settings window). Bit 1 `HOST_FLAG_VIRTUAL_DISPLAYS`: VIRTUAL_DISPLAY_CREATE works on this PC. Bit 2 `HOST_FLAG_SCREEN_OFF`: SCREEN_OFF works on this PC |
| lan_ipv4 | 4 bytes | Optional (older hosts omit it; 0 = unknown). The PC's network address in network byte order (the source of its default route), so a headset on the USB cable can tell its room where to watch from |

When the flags change while clients are connected (the settings window turns
remote control on or off), the host sends every paired client a fresh
HELLO_ACK with the new flags; a client treats a later HELLO_ACK as an update
of the host's name and flags, not as a new session.

---

### `0x09` HELLO_REJECT — Host → Client

Sent instead of HELLO_ACK; the host closes the connection right after.

| Field | Type | Description |
|-------|------|-------------|
| reason | uint8 | 1 `REJECT_PIN_REQUIRED` (no PIN sent), 2 `REJECT_WRONG_PIN`, 3 `REJECT_SERVER_FULL` (`--max-clients` reached), 4 `REJECT_LOCKED_OUT` (too many wrong PINs, retry in a minute), 5 `REJECT_ENCRYPTION_REQUIRED` (plain TCP from the network: use TLS, or start the host with `--allow-plaintext`) |

A client should ask the user for the PIN on 1 and 2 instead of retrying, and
stop retrying on 4. A headset disconnected from the host's settings window
gets reason 1 on its next HELLO (once, whatever PIN it sends), so it stops
reconnecting by itself and has to be paired again.

---

### `0x03` MONITOR_LIST — Host → Client

Sent after HELLO_ACK to enumerate available displays, and again to every
client whenever a virtual monitor is added or removed.

```
Payload: uint8 count + count × MonitorInfo [+ count × uint8 flags]
```

The trailing flags (optional, older hosts omit them) are one byte per
monitor, in the same order: bit 0 `MONITOR_FLAG_VIRTUAL` (made by this host
on request, removable with VIRTUAL_DISPLAY_REMOVE), bit 1
`MONITOR_FLAG_PRIMARY`.

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
 0         1         3         5         6                  10
 +---------+---------+---------+---------+------------------+
 | mon_id  | width   | height  | codec   | first_frame      |
 +---------+---------+---------+---------+------------------+
```

| Field | Type | Description |
|-------|------|-------------|
| monitor_id | uint8 | Monitor being streamed |
| width | uint16 LE | Frame width |
| height | uint16 LE | Frame height |
| codec | uint8 | 0=H.264, 1=H.265/HEVC, 2=MJPEG, 3=AV1 |
| first_frame | uint32 LE | Optional (older hosts send 6 bytes and start at 0). Number of this stream's first frame. Frame numbers keep growing across restarts of a monitor's stream, so frames numbered below it are late leftovers of the previous stream and are dropped |

---

### `0x06` STREAM_STOP — Host → Client

Notifies the client that the stream of a specific monitor has stopped
(e.g. the monitor was deselected via MONITOR_SELECT / MULTI_MONITOR_SELECT).

| Field | Type | Description |
|-------|------|-------------|
| monitor_id | uint8 | Monitor whose stream ended |

Clients should treat an empty payload (legacy) as "all streams stopped".

---

### `0x07` AUDIO_START — Host → Client

Sent right after the client connects, when host audio capture is running.

```
 0             2         3            5
 +-------------+---------+------------+
 | sample_rate | channels| audio_port |
 +-------------+---------+------------+
```

| Field | Type | Description |
|-------|------|-------------|
| sample_rate | uint16 LE | Always 48000 |
| channels | uint8 | 1 or 2 |
| audio_port | uint16 LE | UDP port the audio packets arrive on |

---

### `0x08` AUDIO_STOP — Host → Client

Empty payload. The audio stream has ended.

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
| scroll_delta | int16 LE | Vertical scroll, in Windows wheel units (120 = one notch; smaller values accumulate) |
| scroll_delta_h | int16 LE | Horizontal scroll, same units |

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
| scancode | uint16 LE | Windows virtual-key code (`VK_*`) on every OS; Linux and macOS hosts translate it |
| pressed | uint8 | 1=key down, 0=key up |
| modifiers | uint8 | Bitmask: bit0=Shift, bit1=Ctrl, bit2=Alt, bit3=Win/Super. The host presses these around the key (the VR keyboard latches them itself) |

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

Stream quality settings. Applies to all streams. A new `codec` or `max_width`
restarts the active streams (STREAM_STOP then a new STREAM_START per monitor);
the reference client keeps each screen where it was. A message that changes
only `bitrate_kbps`, `jpeg_quality` or `max_fps` is applied to the running
encoders: no STREAM_STOP/START, the client keeps its decoder (a backend that
has to re-open its encoder continues with an IDR carrying its parameter sets).

`bitrate_kbps` and `jpeg_quality` are ceilings. The host adapts below them to
the link, per client, from its FRAME_ACKs (see FRAME_ACK); the frame rate is
also lowered, below `max_fps`, when MJPEG needs it or when the host's encoder
cannot keep up (a CPU encoder such as libx264 defaults to 30 fps).

| Field | Type | Description |
|-------|------|-------------|
| codec | uint8 | 0 = H.264, 1 = H.265/HEVC, 2 = MJPEG, 3 = AV1, 0xFF = host default. If the host cannot encode the requested codec it falls back (→ H.264 → MJPEG) and announces the actual codec in STREAM_START. |
| bitrate_kbps | uint32 LE | H.264/HEVC/AV1 bitrate ceiling; 0 = host default (20000) |
| jpeg_quality | uint8 | MJPEG quality 10–95; 0 = host default |
| max_width | uint16 LE | Downscale streams to this width (aspect preserved, host clamps to native); 0 = native resolution |
| max_fps | uint8 | FPS cap; 0 = auto (display refresh for a GPU encoder, 30 for a CPU H.264 encoder, 24 for MJPEG) |

When a stream is downscaled the host announces the scaled dimensions in
STREAM_START and maps incoming INPUT_MOUSE coordinates (which are in stream
pixels) back to native monitor pixels.

---

### `0x22` VIRTUAL_DISPLAY_CREATE — Client → Host

Ask for an extra monitor that exists only to be shown in VR (X11: a RandR
monitor; GNOME: a Mutter virtual monitor; macOS: a CGVirtualDisplay). Only
sent when HELLO_ACK set `HOST_FLAG_VIRTUAL_DISPLAYS`.

| Field | Type | Description |
|-------|------|-------------|
| width | uint16 LE | Pixels; the host clamps to 640–7680 and rounds down to even |
| height | uint16 LE | Pixels; clamped to 480–4320, even |
| refresh_rate | uint8 | Hz, 0 = 60 (clamped to 24–144) |

The host answers with VIRTUAL_DISPLAY_RESULT and, on success, sends every
client a new MONITOR_LIST. Virtual monitors get ids from 100
(`VIRTUAL_MONITOR_ID_BASE`), at most 4 at a time, and are removed when the
host quits. The client streams one like any other monitor (MULTI_MONITOR_SELECT).

### `0x23` VIRTUAL_DISPLAY_REMOVE — Client → Host

| Field | Type | Description |
|-------|------|-------------|
| monitor_id | uint8 | A monitor flagged `MONITOR_FLAG_VIRTUAL` |

If it is streaming, the host first sends STREAM_STOP for it. Answered with
VIRTUAL_DISPLAY_RESULT, then a new MONITOR_LIST to every client.

### `0x24` VIRTUAL_DISPLAY_RESULT — Host → Client

| Field | Type | Description |
|-------|------|-------------|
| status | uint8 | 0 `VDISPLAY_OK`, 1 `VDISPLAY_UNSUPPORTED` (this desktop cannot make them), 2 `VDISPLAY_FAILED` (see the host log), 3 `VDISPLAY_LIMIT` (4 already exist) |
| removed | uint8 | 1 = answer to REMOVE, 0 = answer to CREATE |
| monitor_id | uint8 | The monitor created / removed; 0xFF on failure |

### `0x25` SCREEN_OFF — Both ways

Only sent when HELLO_ACK set `HOST_FLAG_SCREEN_OFF`.

| Field | Type | Description |
|-------|------|-------------|
| off | uint8 | 1 = the PC's main (primary) monitor is dark, 0 = lit |

Client → host: 1 darkens the main monitor, 0 lights it again. Only its picture
goes black: it stays in the desktop and keeps streaming (X11: zero CRTC gamma;
GNOME Wayland: zero CRTC gamma through Mutter's DisplayConfig, plus a laptop
panel's backlight at its minimum, re-applied on each renewal since Mutter puts
its own ramp back when the monitors change; macOS: zero display transfer formula; Windows 10 2004+: a black click-through
window left out of capture). `off = 1` is a lease: the client re-sends it every
2 s while it wants the screen dark, and the host lights it again 10 s
(`SCREEN_OFF_LEASE_MS`) after the last one, when that client disconnects, when
another headset takes the PC over (streams from it), when the host turns
view-only and when it exits. So the screen is never dark without a headset on
it, and every new connection lights it. Only the client that drives the PC (the
one streaming from it) is obeyed.

Host → client: the screen's state each time it changes for that client, and
`off = 0` right after a request it could not honour (view-only, a client that
does not drive the PC, the backend failed). The client's switch follows these.

---

### `0x26` WATCH_CODE — Client → Host

| Field | Type | Description |
|-------|------|-------------|
| code | uint32 LE | Headsets that send this in a `HELLO_FLAG_WATCH` HELLO may watch this client's streams; 0 = nobody |

Sent by a headset sharing its PC's screens with a multiplayer room, after its
HELLO was accepted (the client then waits for the answer to its next
LATENCY_PROBE, which proves the host has the code, before telling the room).
Another code drops the watchers of the old one; only the client that set a
code can take it back with 0; that client leaving takes it back too. Ignored
from watchers.

---

### `0x27` IDENTITY — Host → Client

| Field | Type | Description |
|-------|------|-------------|
| certificate | bytes | The host's TLS certificate, PEM (ASCII, up to a few hundred bytes) |

Sent right after a HELLO arrives and before HELLO_ACK or HELLO_REJECT: always
over TLS, and on a plain connection when the HELLO has `HELLO_FLAG_IDENTITY`
(so a headset on the USB cable learns the certificate of the PC it pairs
with). It is the certificate of this TLS session; a client that cannot read
the peer certificate from its TLS library uses it to pin the host on its next
connection.

---

### `0x28` MEDIA_KEY — Host → Client

| Field | Type | Description |
|-------|------|-------------|
| key | 48 bytes | AES-128 key (16), then HMAC-SHA-256 key (32) |

Over TLS only, before HELLO_ACK (watchers: before STREAM_START), never with
`HELLO_FLAG_TCP_MEDIA`. Random per connection. From then on every UDP datagram
the host sends this client, video and audio, is sealed with it, see [Sealed
datagrams](#sealed-datagrams).

---

### `0x30` FRAME_ACK — Client → Host

Acknowledges a video frame the client has completed (sent for every one).
The host's adaptive bitrate runs on these, per client across all its monitors:

- frames skipped between two ACKs of a monitor (within a second) were lost;
- the time from sending a frame to its ACK is the queue on the way;
- no ACK at all for 1.5 s while frames are sent is a stall.

More than 1 frame in 20 lost, an ACK later than 250 ms, or a stall cuts the
rate to 70 % (at most once a second, down to 5 % of the ceiling); after 4 s
without a cut each clean second raises it by 10 % + 2 % of the ceiling. A
connection starts at half the ceiling. Clients that never send FRAME_ACK are
not throttled. Losing ACKs never stops the stream.

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

### `0x31` REQUEST_KEYFRAME — Client → Host

Asks the host to encode an IDR for one monitor. Used by an inter-frame codec
(H.264/HEVC/AV1) to recover the decode chain after packet loss: the host sends
no periodic keyframe, so a client that sees a gap in frame numbers asks for one.
No-op for MJPEG, where every frame is already independently decodable.

```
 0         1
 +---------+
 | mon_id  |
 +---------+
```

| Field | Type | Description |
|-------|------|-------------|
| monitor_id | uint8 | Monitor whose stream should emit an IDR |

The client throttles these (≥250 ms apart per monitor) so a burst of losses
cannot trigger an IDR storm.

---

### `0x40` LATENCY_PROBE — Client → Host

Round-trip latency measurement. The host echoes it back as `LATENCY_RESPONSE`.

It doubles as the liveness check. The reference client sends one every 2 s and
drops the connection (then auto-reconnects) after 10 s with no TCP data from the
host, so a hung host or a Wi-Fi drop without FIN/RST is noticed. The host
detects a vanished client with TCP keepalive instead (5 s idle, 3 probes 2 s
apart), so clients that never probe (the web bridge, test tools) still work.

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

### `0x50` VIDEO_FRAME — Host → Client (TCP media mode only)

One whole encoded frame — the bytes its UDP chunks would reassemble to.

| Field | Size | Description |
|-------|------|-------------|
| monitor_id | 1 byte | Which monitor this frame belongs to |
| frame_number | 4 bytes LE | Same per-monitor numbering as the UDP video channel |
| data | length − 5 bytes | Encoded frame |

The client still sends `FRAME_ACK` per frame. A frame can be several MB, far
above the 64 KB the host accepts for client → host messages.

---

### `0x51` AUDIO_DATA — Host → Client (TCP media mode only)

Payload is exactly one audio packet as sent on the UDP audio channel (header +
PCM, see below).

---

### `0xFF` PING

Empty payload. The receiver echoes it back — and both ends echo, so a PING
either side originates would bounce back and forth forever. Neither side sends
one on its own; use `LATENCY_PROBE` for liveness.

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

Frame numbers are **per monitor**, so a reassembly buffer must be keyed on
`(monitor_id, frame_number)` — keying on the frame number alone interleaves
chunks from two monitors into one corrupt frame.

A frame is complete when `chunks_received == chunk_count`. Incomplete frames are
discarded on a timeout (the reference client uses 5 s) rather than as soon as a
higher `frame_number` arrives: a large IDR can take longer to transmit than the
next few frames, and dropping it early loses the one frame a recovering decoder
needs.

### Parity chunks (FEC)

After a frame's `chunk_count` data chunks the host sends
`p = max(1, ceil(chunk_count × 20 / 100))` parity chunks with the same header,
`chunk_index` = `chunk_count` … `chunk_count + p − 1`. Clients that do not
know them drop them (`chunk_index >= chunk_count`). The payload of parity chunk
`j`:

| Field | Size | Description |
|-------|------|-------------|
| frame_size | 4 bytes LE | The whole frame's bytes |
| parity_count | 2 bytes LE | `p` |
| xor | min(frame_size, 1400) bytes | XOR of data chunks `j`, `j + p`, `j + 2p`…, each zero-padded to this length |

With one data chunk of a group missing, XOR-ing the parity with the group's
other chunks gives it back (cut to 1400 bytes, or to
`frame_size − (chunk_count − 1) × 1400` for the last chunk). So one loss per
group, and any burst of up to `p` consecutive losses, costs nothing; a frame
missing two chunks of one group is lost as before (the client asks for an IDR).

### Video Codecs

| Value | Name | Description |
|-------|------|-------------|
| 0 | H.264 | Media Foundation MFT (NVENC/AMF/QSV, or the Windows software MFT) |
| 1 | H.265 | Media Foundation MFT, hardware only |
| 2 | MJPEG | Software encoder (stb_image_write); always available, default |
| 3 | AV1   | Media Foundation MFT, hardware only (recent GPUs) |

The host resolves the request through a fallback chain (requested → H.264 →
MJPEG) and announces what it actually used in `STREAM_START.codec`, which may
differ from what was asked for.

MJPEG frames are valid JPEG files. The client decodes them with
`Image.load_jpg_from_buffer()` (Godot) or `stb_image.h` (C++). H.264/HEVC are
Annex-B; the host re-inserts SPS/PPS in-band on any access unit that lacks them,
so a client can start decoding from whichever frame it receives first.

---

## Audio Channel (UDP)

Raw PCM-16 stereo 48 kHz, one datagram per ~10 ms packet.

```
 0         4         6         7         8         8+N
 +---------+---------+---------+---------+--- ...---+
 | seq     | samples | channels| reserved| PCM data |
 +---------+---------+---------+---------+--- ...---+
```

| Field | Size | Description |
|-------|------|-------------|
| seq | 4 bytes LE | Monotonic packet sequence number |
| samples | 2 bytes LE | Samples per channel in this packet |
| channels | 1 byte | 1 = mono, 2 = stereo |
| reserved | 1 byte | Padding / future use |
| PCM data | `samples * channels * 2` bytes | Interleaved signed 16-bit LE |

The host resamples and downmixes the WASAPI endpoint's mix format (often
44.1 kHz, sometimes 6 or 8 channels) to this fixed format before sending.

---

## Sealed datagrams

A client that got `MEDIA_KEY` receives each video and audio datagram as

```
 0        16                         16+C       16+C+16
 +--------+--------------------------+----------+
 | IV     | ciphertext (C bytes)     | tag      |
 +--------+--------------------------+----------+
```

- ciphertext: AES-128-CBC with `key[0..15]` and the IV over the plain datagram
  (the formats above) plus PKCS#7 padding, so C is a multiple of 16;
- tag: the first 16 bytes of HMAC-SHA-256 with `key[16..47]` over IV and
  ciphertext (encrypt-then-MAC).

The client checks the tag before anything else (constant time) and drops the
datagram if it does not match; it also drops plain datagrams once it expects
sealed ones. The host's IVs are unpredictable (AES of a counter under a key
of its own). A 1415-byte video datagram becomes 1456 bytes: still one
Ethernet frame. Why not AES-GCM: the Godot client has AES and HMAC but no
AEAD, see `docs/SECURITY.md`.

---

## Connection Sequence

```
Client                                   Host
  |                                        |
  |--- TCP connect ----------------------->|
  |=== TLS 1.2 handshake =================>|   (not from 127.0.0.0/8)
  |--- HELLO (0x01) ---------------------->|
  |<-- IDENTITY (0x27) --------------------|   (TLS, or HELLO_FLAG_IDENTITY)
  |<-- MEDIA_KEY (0x28) -------------------|   (TLS, UDP media)
  |<-- HELLO_ACK (0x02) -------------------|
  |<-- MONITOR_LIST (0x03) ----------------|
  |<-- AUDIO_START (0x07) -----------------|   (if host audio is enabled)
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
  |--- REQUEST_KEYFRAME (0x31) ---------->|   (after packet loss)
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
| 1 (current) | HELLO handshake, monitor list, single- and multi-monitor streaming, mouse/keyboard input, MJPEG/H.264/HEVC/AV1 video, PCM audio channel, latency probing, frame ACK, keyframe request; HELLO flags + VIDEO_FRAME/AUDIO_DATA for TCP media (USB); HELLO_ACK/discovery/MONITOR_LIST flags and VIRTUAL_DISPLAY_* (view-only hosts, virtual monitors); WATCH_CODE, `HELLO_FLAG_WATCH`, HELLO `udp_port` and HELLO_ACK `lan_ipv4` (multiplayer rooms); TLS, IDENTITY, MEDIA_KEY, `HELLO_FLAG_IDENTITY`, sealed datagrams and `REJECT_ENCRYPTION_REQUIRED` — additive, except that plain clients from the network need `--allow-plaintext` |
