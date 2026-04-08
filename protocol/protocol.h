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
constexpr uint16_t DEFAULT_TCP_PORT = 19800;
constexpr uint16_t DEFAULT_UDP_PORT = 19801;

/// Maximum UDP payload size (staying under typical MTU)
constexpr uint16_t MAX_UDP_PAYLOAD = 1400;

/// Video codecs
enum class VideoCodec : uint8_t {
    H264  = 0,
    H265  = 1,
    MJPEG = 2,  ///< Software MJPEG encoder (stb_image_write)
};

/// Control message types
enum class MessageType : uint8_t {
    HELLO                = 0x01,
    HELLO_ACK            = 0x02,
    MONITOR_LIST         = 0x03,
    MONITOR_SELECT       = 0x04,
    STREAM_START         = 0x05,
    STREAM_STOP          = 0x06,
    INPUT_MOUSE          = 0x10,
    INPUT_KEYBOARD       = 0x11,
    INPUT_POINTER        = 0x12,
    MULTI_MONITOR_SELECT = 0x20, ///< Select multiple monitors simultaneously
    FRAME_ACK            = 0x30, ///< Acknowledge a received frame (flow control)
    LATENCY_PROBE        = 0x40, ///< Sent by client to measure round-trip latency
    LATENCY_RESPONSE     = 0x41, ///< Server echoes LATENCY_PROBE back
    PING                 = 0xFF,
};

/// TLV message header for control channel (TCP)
#pragma pack(push, 1)

struct ControlHeader {
    uint8_t  type;
    uint32_t length;
};

struct Hello {
    uint8_t protocol_version;
    char    client_name[32];
};

struct HelloAck {
    uint8_t  protocol_version;
    uint16_t udp_port;
    uint8_t  monitor_count;
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
    // Followed by count * MonitorInfo
};

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
};

struct InputMouse {
    uint8_t  monitor_id;
    uint16_t x;
    uint16_t y;
    uint8_t  buttons;       ///< bitmask: bit0=left, bit1=right, bit2=middle
    int16_t  scroll_delta;
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

/// Video packet header for video channel (UDP)
struct VideoPacketHeader {
    uint8_t  monitor_id;
    uint32_t frame_number;
    uint16_t chunk_index;
    uint16_t chunk_count;
    // Followed by payload bytes
};

#pragma pack(pop)

/// Helper to compute the number of chunks for a given frame size
inline uint16_t compute_chunk_count(uint32_t frame_size) {
    return static_cast<uint16_t>((frame_size + MAX_UDP_PAYLOAD - 1) / MAX_UDP_PAYLOAD);
}

}  // namespace protocol
}  // namespace immersive
