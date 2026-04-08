/// GPU Video Encoder implementation.
///
/// Provides a factory for hardware-accelerated video encoders.
/// The primary encoder is a software MJPEG encoder using stb_image_write.
/// NVENC/AMF/QSV backends are served via Media Foundation MFT (Windows 8+).

#include "encoder/encoder.h"
#include "encoder/mf_encoder.h"

#include <algorithm>
#include <iostream>
#include <cstring>
#include <vector>
#include <cstdlib>

// ---------------------------------------------------------------------------
// stb_image_write — single-header JPEG encoder
// ---------------------------------------------------------------------------
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBIW_ASSERT(x)          // disable assertions for release builds
#include "encoder/stb_image_write.h"

namespace immersive {

// ---------------------------------------------------------------------------
// MJPEG Software Encoder
// Compresses BGRA frames to JPEG using stb_image_write.
// This is the primary path when compiled with ENABLE_NVENC=OFF, etc.
// ---------------------------------------------------------------------------

class MjpegEncoder : public IVideoEncoder {
public:
    bool initialize(const EncoderConfig& config) override {
        config_       = config;
        initialized_  = true;
        frame_count_  = 0;
        force_keyframe_ = true;  // MJPEG frames are always independently decodable

        // JPEG quality: scale from bitrate hint (clamp 40–95)
        // Heuristic: 20000 kbps ~> quality 90
        int q = static_cast<int>(config_.bitrate_kbps / 250);
        quality_ = std::max(40, std::min(95, q));

        std::cout << "[MjpegEncoder] Initialized: "
                  << config_.width << "x" << config_.height
                  << " @ " << config_.fps << " fps"
                  << ", JPEG quality=" << quality_ << "\n";
        return true;
    }

    std::vector<EncodedPacket> encode(
            const uint8_t* bgra_data,
            uint32_t       width,
            uint32_t       height,
            uint32_t       pitch,
            uint64_t       timestamp_us) override {
        if (!initialized_ || !bgra_data) return {};

        // stb_image_write expects RGB or RGBA (not BGRA).
        // Convert BGRA → RGBA in-place into a temporary buffer.
        std::vector<uint8_t> rgba(width * height * 4);
        for (uint32_t y = 0; y < height; ++y) {
            const uint8_t* src_row = bgra_data + static_cast<size_t>(y) * pitch;
            uint8_t*       dst_row = rgba.data() + static_cast<size_t>(y) * width * 4;
            for (uint32_t x = 0; x < width; ++x) {
                dst_row[x * 4 + 0] = src_row[x * 4 + 2]; // R ← B
                dst_row[x * 4 + 1] = src_row[x * 4 + 1]; // G ← G
                dst_row[x * 4 + 2] = src_row[x * 4 + 0]; // B ← R
                dst_row[x * 4 + 3] = src_row[x * 4 + 3]; // A ← A
            }
        }

        // Encode to JPEG via stb_image_write callback
        std::vector<uint8_t> jpeg_data;
        jpeg_data.reserve(width * height);  // rough upper bound

        auto write_cb = [](void* ctx, void* data, int size) {
            auto* out = reinterpret_cast<std::vector<uint8_t>*>(ctx);
            const uint8_t* bytes = reinterpret_cast<const uint8_t*>(data);
            out->insert(out->end(), bytes, bytes + size);
        };

        int ok = stbi_write_jpg_to_func(
            write_cb,
            &jpeg_data,
            static_cast<int>(width),
            static_cast<int>(height),
            4,                  // channels (RGBA)
            rgba.data(),
            quality_);

        if (!ok || jpeg_data.empty()) {
            std::cerr << "[MjpegEncoder] JPEG encode failed for frame "
                      << frame_count_ << "\n";
            return {};
        }

        EncodedPacket pkt;
        pkt.timestamp_us = timestamp_us;
        pkt.is_keyframe  = true;  // MJPEG: every frame is a keyframe
        pkt.data         = std::move(jpeg_data);

        frame_count_++;
        force_keyframe_ = false;

        return {std::move(pkt)};
    }

    std::vector<EncodedPacket> flush() override {
        return {};  // MJPEG has no buffered frames
    }

    void request_keyframe() override {
        force_keyframe_ = true;  // no-op for MJPEG (always key), kept for API compat
    }

    EncoderBackend backend() const override {
        return EncoderBackend::SOFTWARE;
    }

    std::string name() const override {
        return "MJPEG Software Encoder (stb_image_write)";
    }

private:
    EncoderConfig config_;
    bool          initialized_   = false;
    uint32_t      frame_count_   = 0;
    bool          force_keyframe_ = true;
    int           quality_        = 80;
};

// ---------------------------------------------------------------------------
// Factory functions
// ---------------------------------------------------------------------------

EncoderBackend detect_best_encoder() {
#ifdef _WIN32
    // Try Media Foundation hardware encoder first
    if (mf_hardware_encoder_available()) {
        std::cout << "[Encoder] Media Foundation hardware encoder detected (NVENC/AMF/QSV)\n";
        return EncoderBackend::NVENC;  // MF hardware — reported as NVENC for compatibility
    }
    std::cout << "[Encoder] No MF hardware encoder detected, falling back to MJPEG\n";
#else
    std::cout << "[Encoder] Non-Windows build, using MJPEG software encoder\n";
#endif
    return EncoderBackend::SOFTWARE;
}

std::unique_ptr<IVideoEncoder> create_encoder(EncoderBackend backend) {
    switch (backend) {
    case EncoderBackend::NVENC:
    case EncoderBackend::AMF:
    case EncoderBackend::QSV: {
#ifdef _WIN32
        // All three hardware paths use the MF encoder on Windows
        auto mf = create_mf_encoder();
        if (mf) {
            std::cout << "[Encoder] Using Media Foundation hardware H.264 encoder\n";
            return mf;
        }
        // MF init failed at runtime — fall through to software
        std::cerr << "[Encoder] MF encoder creation failed, falling back to MJPEG\n";
#else
        std::cout << "[Encoder] Hardware encoder requested but not available on this platform, using MJPEG\n";
#endif
        return std::make_unique<MjpegEncoder>();
    }

    case EncoderBackend::SOFTWARE:
    default:
        return std::make_unique<MjpegEncoder>();
    }
}

}  // namespace immersive
