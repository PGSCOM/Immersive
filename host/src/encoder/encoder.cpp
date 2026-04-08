/// GPU Video Encoder implementation.
///
/// Provides a factory for hardware-accelerated video encoders.
/// The primary encoder is a software MJPEG encoder using stb_image_write.
/// NVENC/AMF/QSV backends can be enabled via compile-time flags.

#include "encoder/encoder.h"

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
#ifdef IMMERSIVE_NVENC
    std::cout << "[Encoder] NVENC support compiled in (runtime check TODO)\n";
#endif
#ifdef IMMERSIVE_AMF
    std::cout << "[Encoder] AMF support compiled in (runtime check TODO)\n";
#endif
#ifdef IMMERSIVE_QSV
    std::cout << "[Encoder] QSV support compiled in (runtime check TODO)\n";
#endif

    std::cout << "[Encoder] Using MJPEG software encoder\n";
    return EncoderBackend::SOFTWARE;
}

std::unique_ptr<IVideoEncoder> create_encoder(EncoderBackend backend) {
    switch (backend) {
    case EncoderBackend::NVENC:
        // TODO: return std::make_unique<NvencEncoder>();
        std::cout << "[Encoder] NVENC encoder not yet implemented, using MJPEG\n";
        return std::make_unique<MjpegEncoder>();

    case EncoderBackend::AMF:
        // TODO: return std::make_unique<AmfEncoder>();
        std::cout << "[Encoder] AMF encoder not yet implemented, using MJPEG\n";
        return std::make_unique<MjpegEncoder>();

    case EncoderBackend::QSV:
        // TODO: return std::make_unique<QsvEncoder>();
        std::cout << "[Encoder] QSV encoder not yet implemented, using MJPEG\n";
        return std::make_unique<MjpegEncoder>();

    case EncoderBackend::SOFTWARE:
    default:
        return std::make_unique<MjpegEncoder>();
    }
}

}  // namespace immersive
