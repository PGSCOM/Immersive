# Immersive-2 Wire Protocol

## Overview

Communication between the Windows host and the VR client uses two channels:

| Channel | Transport | Purpose                          |
|---------|-----------|----------------------------------|
| Control | TCP       | Handshake, configuration, input  |
| Video   | UDP       | Encoded video frames             |

Default ports: TCP **19800**, UDP **19801**.

## Control Channel (TCP)

All control messages use a simple TLV (Type-Length-Value) format:

```
┌──────────┬──────────┬─────────────────┐
│ Type (1) │ Len (4)  │ Payload (Len)   │
│  uint8   │ uint32le │ bytes           │
└──────────┴──────────┴─────────────────┘
```

### Message Types

| Type | Name              | Direction      | Description                        |
|------|-------------------|----------------|------------------------------------|
| 0x01 | HELLO             | Client → Host  | Initial handshake                  |
| 0x02 | HELLO_ACK         | Host → Client  | Handshake response with config     |
| 0x03 | MONITOR_LIST      | Host → Client  | Available monitors                 |
| 0x04 | MONITOR_SELECT    | Client → Host  | Request stream for a monitor       |
| 0x05 | STREAM_START      | Host → Client  | Stream is starting                 |
| 0x06 | STREAM_STOP       | Host → Client  | Stream has stopped                 |
| 0x10 | INPUT_MOUSE       | Client → Host  | Mouse movement / click             |
| 0x11 | INPUT_KEYBOARD    | Client → Host  | Key press / release                |
| 0x12 | INPUT_POINTER     | Client → Host  | VR pointer (3D ray)                |
| 0xFF | PING              | Bidirectional  | Keep-alive                         |

### HELLO (0x01)

```c
struct Hello {
    uint8_t  protocol_version;  // 1
    char     client_name[32];   // null-terminated
};
```

### HELLO_ACK (0x02)

```c
struct HelloAck {
    uint8_t  protocol_version;
    uint16_t udp_port;          // port for video stream
    uint8_t  monitor_count;
};
```

### MONITOR_LIST (0x03)

```c
struct MonitorInfo {
    uint8_t  monitor_id;
    uint16_t width;
    uint16_t height;
    uint8_t  refresh_rate;
    char     name[64];          // null-terminated
};

struct MonitorList {
    uint8_t      count;
    MonitorInfo  monitors[];    // variable length
};
```

### INPUT_MOUSE (0x10)

```c
struct InputMouse {
    uint8_t  monitor_id;
    uint16_t x;
    uint16_t y;
    uint8_t  buttons;           // bitmask: bit0=left, bit1=right, bit2=middle
    int16_t  scroll_delta;
};
```

### INPUT_KEYBOARD (0x11)

```c
struct InputKeyboard {
    uint8_t  monitor_id;
    uint16_t scancode;          // Windows virtual key code
    uint8_t  pressed;           // 1 = down, 0 = up
    uint8_t  modifiers;         // bitmask: bit0=shift, bit1=ctrl, bit2=alt
};
```

## Video Channel (UDP)

Video frames are split into packets with a simple header:

```
┌────────────┬────────────┬──────────┬──────────┬──────────────────┐
│ MonitorID  │ FrameNum   │ ChunkIdx │ ChunkCnt │ Payload          │
│  uint8     │  uint32le  │ uint16le │ uint16le │ bytes            │
└────────────┴────────────┴──────────┴──────────┴──────────────────┘
```

- **MonitorID**: Which monitor this frame belongs to
- **FrameNum**: Monotonically increasing frame counter
- **ChunkIdx**: Index of this chunk within the frame (0-based)
- **ChunkCnt**: Total chunks in this frame
- **Payload**: Encoded H.264/H.265 data fragment

Maximum UDP payload size: 1400 bytes (to stay under typical MTU).

## Flow

```
Client                          Host
  │                               │
  │──── HELLO ───────────────────▶│
  │◀─── HELLO_ACK ───────────────│
  │◀─── MONITOR_LIST ────────────│
  │──── MONITOR_SELECT ─────────▶│
  │◀─── STREAM_START ────────────│
  │◀─── [UDP video frames] ──────│
  │──── INPUT_MOUSE ────────────▶│
  │──── INPUT_KEYBOARD ─────────▶│
  │                               │
```
