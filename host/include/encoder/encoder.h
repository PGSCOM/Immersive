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

    /// True if encode() accepts frames of any size and scales them to the
    /// configured width/height itself (on the GPU or with SIMD). main.cpp
    /// then skips its own CPU downscale.
    virtual bool scales_input() const { return false; }
};

/// The OS hardware encoder for H.264 / HEVC / AV1: Media Foundation on
/// Windows, VideoToolbox on macOS, FFmpeg (NVENC → VAAPI → libx264) on Linux.
/// The codec is taken from EncoderConfig::codec at initialize() time; returns
/// nullptr (or fails initialize) when that codec cannot be encoded here.
///
/// Output contract, relied on by the client's MediaCodec decoder:
///  - one encode() call → the packets of exactly one access unit (no B-frames,
///    no reordering, no frame held back for lookahead);
///  - H.264/HEVC as Annex-B with start codes, AV1 as low-overhead OBUs;
///  - parameter sets (VPS/SPS/PPS, or the AV1 sequence header) in-band on
///    every keyframe, so a client that joins or recovers mid-stream can start
///    decoding at any IDR;
///  - request_keyframe() makes the next encoded frame an IDR;
///  - BT.601 limited-range colour, tagged in the VUI / colour config;
///  - CBR-ish rate control at EncoderConfig::bitrate_kbps with a small VBV
///    (~50 ms) so a single IDR stays a few dozen UDP chunks.
std::unique_ptr<IVideoEncoder> create_hw_encoder();

/// True if create_hw_encoder() can encode `codec` on this machine (probed
/// once and cached).
bool hw_encoder_available(VideoCodec codec);

/// Detect the best available encoder backend
EncoderBackend detect_best_encoder();

/// Create an encoder for the specified backend
std::unique_ptr<IVideoEncoder> create_encoder(EncoderBackend backend);

}  // namespace immersive
