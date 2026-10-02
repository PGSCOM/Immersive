#pragma once

/// Immersive-2 Wire Protocol Definitions
/// Shared between host and client implementations.

#include <cstdint>
#include <cstring>

#ifdef INPUT_MOUSE
#undef INPUT_MOUSE
#endif

#ifdef INPUT_KEYBOARD
#undef INPUT_KEYBOARD
#endif

namespace immersive {
namespace protocol {

/// Protocol version
constexpr uint8_t PROTOCOL_VERSION = 1;

/// Default ports
constexpr uint16_t DEFAULT_TCP_PORT  = 19800;
constexpr uint16_t DEFAULT_UDP_PORT  = 19801;
constexpr uint16_t DEFAULT_AUDIO_PORT = 19802;  ///< Separate UDP port for audio

/// Maximum UDP payload size (staying under typical MTU)
constexpr uint16_t MAX_UDP_PAYLOAD = 1400;

/// Video codecs
enum class VideoCodec : uint8_t {
    H264  = 0,
    H265  = 1,  ///< HEVC (hardware MFT only)
    MJPEG = 2,  ///< Software MJPEG encoder (stb_image_write)
    AV1   = 3,  ///< AV1 (hardware MFT only, recent GPUs)
};

/// Control message types
enum class MessageType : uint8_t {
    HELLO                = 0x01,
    HELLO_ACK            = 0x02,
    MONITOR_LIST         = 0x03,
    MONITOR_SELECT       = 0x04,
    STREAM_START         = 0x05,
    STREAM_STOP          = 0x06,
    AUDIO_START          = 0x07,  ///< Server → client: audio stream started
    AUDIO_STOP           = 0x08,  ///< Server → client: audio stream stopped
    HELLO_REJECT         = 0x09,  ///< Server → client: handshake refused, host then closes
    INPUT_MOUSE          = 0x10,
    INPUT_KEYBOARD       = 0x11,
    INPUT_POINTER        = 0x12,
    MULTI_MONITOR_SELECT = 0x20, ///< Select multiple monitors simultaneously
    STREAM_CONFIG        = 0x21, ///< Client requests stream quality settings
    VIRTUAL_DISPLAY_CREATE = 0x22, ///< Client → host: add a virtual monitor
    VIRTUAL_DISPLAY_REMOVE = 0x23, ///< Client → host: remove a virtual monitor this host made
    VIRTUAL_DISPLAY_RESULT = 0x24, ///< Host → client: outcome of CREATE / REMOVE
    SCREEN_OFF           = 0x25, ///< Both ways: the PC's main screen dark / lit (ScreenOff)
    FRAME_ACK            = 0x30, ///< Acknowledge a received frame (flow control)
    REQUEST_KEYFRAME     = 0x31, ///< Client asks the host to emit an IDR (loss recovery)
    LATENCY_PROBE        = 0x40, ///< Sent by client to measure round-trip latency
    LATENCY_RESPONSE     = 0x41, ///< Server echoes LATENCY_PROBE back
    VIDEO_FRAME          = 0x50, ///< Host → client: whole frame over TCP (HELLO_FLAG_TCP_MEDIA)
    AUDIO_DATA           = 0x51, ///< Host → client: audio packet over TCP (HELLO_FLAG_TCP_MEDIA)
    PING                 = 0xFF,
};

/// TLV message header for control channel (TCP)
#pragma pack(push, 1)

struct ControlHeader {
    uint8_t  type;
    uint32_t length;
};

/// Hello.flags bit: send video and audio in-band on the TCP control channel
/// (VIDEO_FRAME / AUDIO_DATA) instead of UDP. Used over USB, where
/// `adb reverse` tunnels TCP only. Older clients send no flags byte (= UDP).
constexpr uint8_t HELLO_FLAG_TCP_MEDIA = 0x01;

struct Hello {
    uint8_t  protocol_version;
    char     client_name[32];
    uint8_t  flags;  ///< HELLO_FLAG_* bitmask; optional (absent = 0)
    uint32_t pin;    ///< Pairing PIN (100000-999999); optional (absent = 0 = none)
};

struct HelloAck {
    uint8_t  protocol_version;
    uint16_t udp_port;
    uint8_t  monitor_count;
    char     host_name[64];  ///< UTF-8, NUL-padded; optional (older hosts omit it)
    uint8_t  flags;          ///< HOST_FLAG_*; optional (absent = 0)
};

/// HelloAck.flags bits.
constexpr uint8_t HOST_FLAG_VIEW_ONLY        = 0x01;  ///< --view-only: input is ignored
constexpr uint8_t HOST_FLAG_VIRTUAL_DISPLAYS = 0x02;  ///< VIRTUAL_DISPLAY_CREATE works here
constexpr uint8_t HOST_FLAG_SCREEN_OFF       = 0x04;  ///< SCREEN_OFF works here

/// HelloReject.reason values.
constexpr uint8_t REJECT_PIN_REQUIRED = 1;  ///< Host needs a PIN and none was sent
constexpr uint8_t REJECT_WRONG_PIN    = 2;
constexpr uint8_t REJECT_SERVER_FULL  = 3;  ///< --max-clients reached
constexpr uint8_t REJECT_LOCKED_OUT   = 4;  ///< Too many wrong PINs from this address; retry later

/// Sent instead of HELLO_ACK when the host refuses the client. Only
/// connections from 127.0.0.1 (USB via `adb reverse`, a local bridge) skip the
/// PIN; every other client must send the host's pairing PIN in HELLO.
struct HelloReject {
    uint8_t reason;  ///< REJECT_*
};

/// LAN discovery (UDP). The host listens on UDP <tcp_port> (19800 by default,
/// a separate namespace from the TCP control port). A client broadcasts a
/// DiscoveryRequest there; every host answers the sender with a unicast
/// DiscoveryReply, so the headset can list PCs without typing an IP.
constexpr uint32_t DISCOVERY_REQUEST_MAGIC = 0x3F324D49;  ///< "IM2?"
constexpr uint32_t DISCOVERY_REPLY_MAGIC   = 0x21324D49;  ///< "IM2!"
constexpr uint8_t  DISCOVERY_FLAG_PIN      = 0x01;  ///< connecting needs the PIN
constexpr uint8_t  DISCOVERY_FLAG_VIEW_ONLY = 0x02; ///< the PC shares its screens but takes no input

struct DiscoveryRequest {
    uint32_t magic;             ///< DISCOVERY_REQUEST_MAGIC
    uint8_t  protocol_version;
};

struct DiscoveryReply {
    uint32_t magic;             ///< DISCOVERY_REPLY_MAGIC
    uint8_t  protocol_version;
    uint16_t tcp_port;
    uint8_t  monitor_count;
    uint8_t  flags;             ///< DISCOVERY_FLAG_*
    char     host_name[64];     ///< UTF-8, NUL-padded
};

struct MonitorInfo {
    uint8_t  monitor_id;
    uint16_t width;
    uint16_t height;
    uint8_t  refresh_rate;
    char     name[64];
};

struct MonitorList {
    uint8_t     count;
    // Followed by count * MonitorInfo, then (optional, older hosts omit it)
    // count * uint8_t MONITOR_FLAG_* in the same order.
};

constexpr uint8_t MONITOR_FLAG_VIRTUAL = 0x01;  ///< made by this host on request; removable
constexpr uint8_t MONITOR_FLAG_PRIMARY = 0x02;

/// Ask the host for an extra, virtual monitor of this size. The host answers
/// with VIRTUAL_DISPLAY_RESULT and sends every client a new MONITOR_LIST.
/// Virtual monitors get ids >= VIRTUAL_MONITOR_ID_BASE, which stay the same
/// while they exist (physical ids are 0..).
struct VirtualDisplayCreate {
    uint16_t width;
    uint16_t height;
    uint8_t  refresh_rate;  ///< 0 = 60
};

struct VirtualDisplayRemove {
    uint8_t monitor_id;
};

constexpr uint8_t VIRTUAL_MONITOR_ID_BASE = 100;
constexpr uint8_t MAX_VIRTUAL_DISPLAYS    = 4;

/// VirtualDisplayResult.status values.
constexpr uint8_t VDISPLAY_OK          = 0;
constexpr uint8_t VDISPLAY_UNSUPPORTED = 1;  ///< this PC / desktop cannot make them
constexpr uint8_t VDISPLAY_FAILED      = 2;  ///< it tried and failed (see the host log)
constexpr uint8_t VDISPLAY_LIMIT       = 3;  ///< MAX_VIRTUAL_DISPLAYS already exist

struct VirtualDisplayResult {
    uint8_t status;      ///< VDISPLAY_*
    uint8_t removed;     ///< 1 = answer to REMOVE, 0 = answer to CREATE
    uint8_t monitor_id;  ///< the monitor created / removed; 0xFF on failure
};

/// Client → host: off = 1 darkens the PC's main (primary) monitor, which
/// keeps streaming; 0 lights it again. off = 1 is a lease the client re-sends
/// every 2 s while it wants the screen dark: the host lights it again
/// SCREEN_OFF_LEASE_MS after the last one, when that client leaves, when
/// another headset connects or takes the PC over, when the host turns
/// view-only and when it exits, so a PC never stays dark with no headset on
/// it. Only the client streaming from the PC is obeyed. Host → client: the
/// screen's state after it changed (or off = 0 when it refused).
struct ScreenOff {
    uint8_t off;
};

constexpr uint32_t SCREEN_OFF_LEASE_MS = 10000;

struct MonitorSelect {
    uint8_t monitor_id;
};

/// Select up to 3 monitors simultaneously.
/// monitor_ids[i] == 0xFF means slot unused.
struct MultiMonitorSelect {
    uint8_t monitor_count;          ///< Number of valid entries (1-3)
    uint8_t monitor_ids[3];         ///< Monitor IDs to activate
    uint8_t _reserved;
};

struct StreamStart {
    uint8_t  monitor_id;
    uint16_t width;
    uint16_t height;
    uint8_t  codec;  ///< VideoCodec enum value
    /// Number of this stream's first frame (optional; older hosts omit it and
    /// start at 0). Numbers keep growing across restarts of a monitor's
    /// stream, so a client can drop late frames of the previous stream.
    uint32_t first_frame;
};

/// Sent by the server when a monitor stream ends (e.g. it was deselected).
struct StreamStop {
    uint8_t monitor_id;
};

/// Stream quality settings requested by the client (applies to all streams).
/// Zero / 0xFF fields mean "keep the host default". The host restarts the
/// active streams when this message is received.
struct StreamConfig {
    uint8_t  codec;         ///< VideoCodec value; 0xFF = host default
    uint32_t bitrate_kbps;  ///< H.264 bitrate; 0 = default
    uint8_t  jpeg_quality;  ///< MJPEG quality 10-95; 0 = default
    uint16_t max_width;     ///< Downscale to this width (aspect kept); 0 = native
    uint8_t  max_fps;       ///< FPS cap; 0 = auto
};

struct InputMouse {
    uint8_t  monitor_id;
    uint16_t x;
    uint16_t y;
    uint8_t  buttons;       ///< bitmask: bit0=left, bit1=right, bit2=middle
    int16_t  scroll_delta;
    int16_t  scroll_delta_h;
};

struct InputKeyboard {
    uint8_t  monitor_id;
    uint16_t scancode;
    uint8_t  pressed;       ///< 1 = down, 0 = up
    uint8_t  modifiers;     ///< bitmask: bit0=shift, bit1=ctrl, bit2=alt
};

/// Acknowledge receipt of a video frame (flow control).
struct FrameAck {
    uint8_t  monitor_id;
    uint32_t frame_number;
};

/// Ask the host to encode a keyframe (IDR) for a monitor's stream. Used by the
/// client to recover an inter-frame codec (H.264/HEVC/AV1) after packet loss
/// instead of waiting for the next periodic keyframe (GOP boundary).
struct RequestKeyframe {
    uint8_t monitor_id;
};

/// Latency probe — sent by client with a timestamp.
/// Server immediately echoes it back as LATENCY_RESPONSE.
struct LatencyProbe {
    uint64_t probe_id;          ///< Unique probe identifier (monotonic counter)
    uint64_t client_timestamp;  ///< Client microsecond timestamp
};

/// Latency response — server echoes the probe unchanged.
struct LatencyResponse {
    uint64_t probe_id;          ///< Same as in LatencyProbe
    uint64_t client_timestamp;  ///< Echoed back from LatencyProbe
    uint64_t server_timestamp;  ///< Server microsecond timestamp (informational)
};

/// Audio packet header for audio channel (UDP).
/// Carries raw PCM-16 stereo 48 kHz audio samples.
struct AudioPacketHeader {
    uint32_t seq;       ///< Monotonically increasing sequence number
    uint16_t samples;   ///< Number of PCM samples in this packet (per channel)
    uint8_t  channels;  ///< Number of channels (1 = mono, 2 = stereo)
    uint8_t  reserved;  ///< Padding / future use
    // Followed by samples*channels*2 bytes of interleaved PCM-16 LE
};

/// Audio-stream-started notification (TCP control channel).
struct AudioStart {
    uint16_t sample_rate;  ///< Always 48000
    uint8_t  channels;     ///< 1 or 2
    uint16_t audio_port;   ///< UDP port on which audio packets are sent
};

/// Video packet header for video channel (UDP)
struct VideoPacketHeader {
    uint8_t  monitor_id;
    uint32_t frame_number;
    uint16_t chunk_index;
    uint16_t chunk_count;
    // Followed by payload bytes
};

/// VIDEO_FRAME payload header (TCP media mode). Followed by the whole encoded
/// frame — the same bytes the UDP chunks of that frame would reassemble to.
/// AUDIO_DATA's payload is exactly one UDP audio packet (AudioPacketHeader + PCM).
struct VideoFrameHeader {
    uint8_t  monitor_id;
    uint32_t frame_number;
};

#pragma pack(pop)

/// Helper to compute the number of chunks for a given frame size
inline uint16_t compute_chunk_count(uint32_t frame_size) {
    return static_cast<uint16_t>((frame_size + MAX_UDP_PAYLOAD - 1) / MAX_UDP_PAYLOAD);
}

}  // namespace protocol
}  // namespace immersive
