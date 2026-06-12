#pragma once

/// GPU Video Encoder interface.
/// Abstracts hardware-accelerated video encoding (NVENC, AMF, QSV).

#include <cstdint>
#include <memory>
#include <vector>
#include <string>

namespace immersive {

/// Supported encoder backends
enum class EncoderBackend {
    NVENC,   // NVIDIA
    AMF,     // AMD
    QSV,     // Intel QuickSync
    SOFTWARE // Fallback CPU encoder
};

/// Video codec
enum class VideoCodec {
    H264,
    H265,
    AV1,
};

/// Encoder configuration
struct EncoderConfig {
    uint32_t     width         = 1920;
    uint32_t     height        = 1080;
    uint32_t     fps           = 60;
    uint32_t     bitrate_kbps  = 20000;  // 20 Mbps default
    VideoCodec   codec         = VideoCodec::H264;
    uint32_t     gop_size      = 60;     // keyframe interval
    uint32_t     jpeg_quality  = 35;     // MJPEG quality (10-95)
};

/// An encoded video packet
struct EncodedPacket {
    std::vector<uint8_t> data;
    uint64_t             timestamp_us;
    bool                 is_keyframe;
};

/// Interface for video encoders
class IVideoEncoder {
public:
    virtual ~IVideoEncoder() = default;

    /// Initialize the encoder with the given configuration
    virtual bool initialize(const EncoderConfig& config) = 0;

    /// Encode a raw BGRA frame
    /// Returns encoded packets (may be empty if encoder is buffering)
    virtual std::vector<EncodedPacket> encode(
        const uint8_t* bgra_data,
        uint32_t       width,
        uint32_t       height,
        uint32_t       pitch,
        uint64_t       timestamp_us) = 0;

    /// Flush remaining packets from the encoder
    virtual std::vector<EncodedPacket> flush() = 0;

    /// Request a keyframe on the next encode call
    virtual void request_keyframe() = 0;

    /// Get the encoder backend type
    virtual EncoderBackend backend() const = 0;

    /// Get human-readable encoder name
    virtual std::string name() const = 0;
};

/// Detect the best available encoder backend
EncoderBackend detect_best_encoder();

/// Create an encoder for the specified backend
std::unique_ptr<IVideoEncoder> create_encoder(EncoderBackend backend);

}  // namespace immersive
