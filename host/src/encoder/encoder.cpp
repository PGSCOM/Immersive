/// GPU Video Encoder implementation.
///
/// Provides a factory for hardware-accelerated video encoders.
/// Currently implements a stub encoder; NVENC/AMF/QSV backends
/// will be added as the SDK integrations are completed.

#include "encoder/encoder.h"

#include <iostream>
#include <cstring>

namespace immersive {

// ---------------------------------------------------------------------------
// Stub / Software encoder (used for development and testing)
// ---------------------------------------------------------------------------

class StubEncoder : public IVideoEncoder {
public:
    bool initialize(const EncoderConfig& config) override {
        config_ = config;
        initialized_ = true;
        frame_count_ = 0;
        force_keyframe_ = true;  // First frame is always a keyframe
        std::cout << "[StubEncoder] Initialized: " << config.width << "x" << config.height
                  << " @ " << config.fps << " fps, " << config.bitrate_kbps << " kbps\n";
        return true;
    }

    std::vector<EncodedPacket> encode(
            const uint8_t* bgra_data,
            uint32_t       width,
            uint32_t       height,
            uint32_t       pitch,
            uint64_t       timestamp_us) override {
        if (!initialized_) return {};

        // Stub: create a minimal "encoded" packet containing a small header.
        // Real implementations will call NVENC/AMF/QSV APIs here.
        EncodedPacket pkt;
        pkt.timestamp_us = timestamp_us;
        pkt.is_keyframe = force_keyframe_ ||
                          (frame_count_ % config_.gop_size == 0);
        force_keyframe_ = false;

        // Create a stub payload: 4-byte header + truncated pixel sample
        constexpr uint32_t STUB_PAYLOAD_SIZE = 1024;
        pkt.data.resize(STUB_PAYLOAD_SIZE);

        // Header: "IM2E" magic + frame number
        pkt.data[0] = 'I'; pkt.data[1] = 'M';
        pkt.data[2] = '2'; pkt.data[3] = 'E';
        uint32_t fn = frame_count_;
        std::memcpy(pkt.data.data() + 4, &fn, sizeof(fn));

        frame_count_++;

        return {std::move(pkt)};
    }

    std::vector<EncodedPacket> flush() override {
        return {};
    }

    void request_keyframe() override {
        force_keyframe_ = true;
    }

    EncoderBackend backend() const override {
        return EncoderBackend::SOFTWARE;
    }

    std::string name() const override {
        return "Stub Software Encoder";
    }

private:
    EncoderConfig config_;
    bool          initialized_ = false;
    uint32_t      frame_count_ = 0;
    bool          force_keyframe_ = true;
};

// ---------------------------------------------------------------------------
// Factory functions
// ---------------------------------------------------------------------------

EncoderBackend detect_best_encoder() {
    // TODO: Probe for NVENC, AMF, QSV availability by trying to load
    // their respective runtime libraries.
    //
    // For now, always fall back to the stub encoder.

#ifdef IMMERSIVE_NVENC
    // Try NVENC first (NVIDIA GPU)
    std::cout << "[Encoder] NVENC support compiled in (runtime check TODO)\n";
#endif
#ifdef IMMERSIVE_AMF
    std::cout << "[Encoder] AMF support compiled in (runtime check TODO)\n";
#endif
#ifdef IMMERSIVE_QSV
    std::cout << "[Encoder] QSV support compiled in (runtime check TODO)\n";
#endif

    std::cout << "[Encoder] Using software/stub encoder\n";
    return EncoderBackend::SOFTWARE;
}

std::unique_ptr<IVideoEncoder> create_encoder(EncoderBackend backend) {
    switch (backend) {
    case EncoderBackend::NVENC:
        // TODO: return std::make_unique<NvencEncoder>();
        std::cout << "[Encoder] NVENC encoder not yet implemented, using stub\n";
        return std::make_unique<StubEncoder>();

    case EncoderBackend::AMF:
        // TODO: return std::make_unique<AmfEncoder>();
        std::cout << "[Encoder] AMF encoder not yet implemented, using stub\n";
        return std::make_unique<StubEncoder>();

    case EncoderBackend::QSV:
        // TODO: return std::make_unique<QsvEncoder>();
        std::cout << "[Encoder] QSV encoder not yet implemented, using stub\n";
        return std::make_unique<StubEncoder>();

    case EncoderBackend::SOFTWARE:
    default:
        return std::make_unique<StubEncoder>();
    }
}

}  // namespace immersive
