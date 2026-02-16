#pragma once

/// Immersive-2 Wire Protocol Definitions
/// Shared between host and client implementations.

#include <cstdint>
#include <cstring>

namespace immersive {
namespace protocol {

/// Protocol version
constexpr uint8_t PROTOCOL_VERSION = 1;

/// Default ports
constexpr uint16_t DEFAULT_TCP_PORT = 19800;
constexpr uint16_t DEFAULT_UDP_PORT = 19801;

/// Maximum UDP payload size (staying under typical MTU)
constexpr uint16_t MAX_UDP_PAYLOAD = 1400;

/// Control message types
enum class MessageType : uint8_t {
    HELLO           = 0x01,
    HELLO_ACK       = 0x02,
    MONITOR_LIST    = 0x03,
    MONITOR_SELECT  = 0x04,
    STREAM_START    = 0x05,
    STREAM_STOP     = 0x06,
    INPUT_MOUSE     = 0x10,
    INPUT_KEYBOARD  = 0x11,
    INPUT_POINTER   = 0x12,
    PING            = 0xFF,
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

struct StreamStart {
    uint8_t  monitor_id;
    uint16_t width;
    uint16_t height;
    uint8_t  codec;  // 0 = H.264, 1 = H.265
};

struct InputMouse {
    uint8_t  monitor_id;
    uint16_t x;
    uint16_t y;
    uint8_t  buttons;       // bitmask: bit0=left, bit1=right, bit2=middle
    int16_t  scroll_delta;
};

struct InputKeyboard {
    uint8_t  monitor_id;
    uint16_t scancode;
    uint8_t  pressed;       // 1 = down, 0 = up
    uint8_t  modifiers;     // bitmask: bit0=shift, bit1=ctrl, bit2=alt
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
