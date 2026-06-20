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
    INPUT_MOUSE          = 0x10,
    INPUT_KEYBOARD       = 0x11,
    INPUT_POINTER        = 0x12,
    MULTI_MONITOR_SELECT = 0x20, ///< Select multiple monitors simultaneously
    STREAM_CONFIG        = 0x21, ///< Client requests stream quality settings
    FRAME_ACK            = 0x30, ///< Acknowledge a received frame (flow control)
    REQUEST_KEYFRAME     = 0x31, ///< Client asks the host to emit an IDR (loss recovery)
    LATENCY_PROBE        = 0x40, ///< Sent by client to measure round-trip latency
    LATENCY_RESPONSE     = 0x41, ///< Server echoes LATENCY_PROBE back
    // Multi-user room messages (0x50-0x5F)
    ROOM_JOIN            = 0x50, ///< Client → Server: request to join a room
    ROOM_JOINED          = 0x51, ///< Server → Client: joined successfully
    ROOM_LEFT            = 0x52, ///< Server → Client: a user left the room
    USER_PRESENCE        = 0x53, ///< Server → Client: user presence update
    USER_POSE            = 0x54, ///< Bidirectional: head + hand transforms
    SCREEN_SHARE_STATE   = 0x55, ///< Client → Server: which monitors are shared
    REMOTE_SCREEN_LAYOUT = 0x56, ///< Server → Client: another user's monitor layout
    MONITOR_LAYOUT_UPDATE= 0x57, ///< Client → Server: update monitor positions/sizes
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

// ---------------------------------------------------------------------------
// Multi-user room structs
// ---------------------------------------------------------------------------

/// Client requests to join a room.
struct RoomJoin {
    char room_id[16];       ///< UTF-8 room identifier (null-padded)
    char display_name[32];  ///< UTF-8 display name (null-terminated)
};

/// Server confirms room join and sends participant list.
struct RoomJoined {
    char     room_id[16];   ///< Echoed room identifier
    uint32_t user_id;       ///< Assigned ephemeral user ID
    uint8_t  participant_count; ///< Number of participants already in the room
    // Followed by participant_count * (user_id + display_name[32])
};

/// A user left the room.
struct RoomLeft {
    uint32_t user_id;       ///< User who left
};

/// User presence update (join/leave/change).
struct UserPresence {
    uint32_t user_id;       ///< User ID
    char     display_name[32]; ///< UTF-8 display name
    uint8_t  is_local;      ///< 1 = this client, 0 = remote
    uint8_t  is_online;     ///< 1 = present, 0 = left
};

/// Pose for a single tracked object (position + quaternion).
struct TrackedPose {
    float pos_x, pos_y, pos_z;     ///< Position in meters
    float rot_w, rot_x, rot_y, rot_z; ///< Quaternion (w, x, y, z)
};

/// Head + hands pose update for a user.
struct UserPose {
    uint32_t user_id;       ///< User ID
    TrackedPose head;       ///< Head transform
    TrackedPose left_hand;  ///< Left hand transform
    TrackedPose right_hand; ///< Right hand transform
};

/// Which monitors a user is sharing.
struct ScreenShareState {
    uint32_t user_id;       ///< User ID
    uint8_t  monitor_count; ///< Number of shared monitors (0-3)
    uint8_t  monitor_ids[3]; ///< Monitor IDs being shared
    uint8_t  enabled;       ///< 1 = sharing, 0 = stopped sharing
};

/// Monitor layout entry for a single monitor (position + size in VR space).
struct MonitorLayoutEntry {
    uint8_t  monitor_id;    ///< Monitor ID
    float    pos_x, pos_y, pos_z;    ///< Position in meters
    float    rot_w, rot_x, rot_y, rot_z; ///< Rotation quaternion
    float    width, height; ///< Size in meters
    uint16_t resolution_w;  ///< Native resolution width
    uint16_t resolution_h;  ///< Native resolution height
};

/// Another user's monitor layout (sent when they join or update layout).
struct RemoteScreenLayout {
    uint32_t user_id;       ///< User ID
    uint8_t  monitor_count; ///< Number of monitors (0-3)
    // Followed by monitor_count * MonitorLayoutEntry
};

/// Client updates their monitor layout.
struct MonitorLayoutUpdate {
    uint32_t user_id;       ///< User ID
    uint8_t  monitor_count; ///< Number of monitors (0-3)
    // Followed by monitor_count * MonitorLayoutEntry
};

#pragma pack(pop)

/// Helper to compute the number of chunks for a given frame size
inline uint16_t compute_chunk_count(uint32_t frame_size) {
    return static_cast<uint16_t>((frame_size + MAX_UDP_PAYLOAD - 1) / MAX_UDP_PAYLOAD);
}

}  // namespace protocol
}  // namespace immersive
