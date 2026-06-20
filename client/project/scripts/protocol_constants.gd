## Immersive-2 Protocol Constants
## Mirror of protocol/protocol.h for GDScript clients.
## Keep in sync with the C++ header — byte layouts must match exactly.

class_name ImmersiveProtocol

# ---------------------------------------------------------------------------
# Protocol version
# ---------------------------------------------------------------------------

const PROTOCOL_VERSION: int = 1

# ---------------------------------------------------------------------------
# Default ports
# ---------------------------------------------------------------------------

const DEFAULT_TCP_PORT: int = 19800
const DEFAULT_UDP_PORT: int = 19801
const DEFAULT_AUDIO_PORT: int = 19802

# ---------------------------------------------------------------------------
# Video codecs
# ---------------------------------------------------------------------------

const VIDEO_CODEC_H264: int = 0
const VIDEO_CODEC_H265: int = 1
const VIDEO_CODEC_MJPEG: int = 2
const VIDEO_CODEC_AV1: int = 3

# ---------------------------------------------------------------------------
# Control message types
# ---------------------------------------------------------------------------

const MSG_HELLO: int = 0x01
const MSG_HELLO_ACK: int = 0x02
const MSG_MONITOR_LIST: int = 0x03
const MSG_MONITOR_SELECT: int = 0x04
const MSG_STREAM_START: int = 0x05
const MSG_STREAM_STOP: int = 0x06
const MSG_AUDIO_START: int = 0x07
const MSG_AUDIO_STOP: int = 0x08
const MSG_INPUT_MOUSE: int = 0x10
const MSG_INPUT_KEYBOARD: int = 0x11
const MSG_INPUT_POINTER: int = 0x12
const MSG_MULTI_MONITOR_SELECT: int = 0x20
const MSG_STREAM_CONFIG: int = 0x21
const MSG_FRAME_ACK: int = 0x30
const MSG_REQUEST_KEYFRAME: int = 0x31
const MSG_LATENCY_PROBE: int = 0x40
const MSG_LATENCY_RESPONSE: int = 0x41

# Multi-user room messages
const MSG_ROOM_JOIN: int = 0x50
const MSG_ROOM_JOINED: int = 0x51
const MSG_ROOM_LEFT: int = 0x52
const MSG_USER_PRESENCE: int = 0x53
const MSG_USER_POSE: int = 0x54
const MSG_SCREEN_SHARE_STATE: int = 0x55
const MSG_REMOTE_SCREEN_LAYOUT: int = 0x56
const MSG_MONITOR_LAYOUT_UPDATE: int = 0x57

const MSG_PING: int = 0xFF

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const MAX_UDP_PAYLOAD: int = 1400
const VIDEO_HEADER_SIZE: int = 9  # 1 + 4 + 2 + 2 bytes
