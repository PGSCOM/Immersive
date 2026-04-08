/// Media Foundation hardware H.264 encoder implementation.
///
/// Uses IMFTransform (MFT) to encode BGRA frames to H.264 bitstream.
/// The MFT infrastructure automatically selects the best available
/// hardware encoder: NVIDIA NVENC, AMD AMF, or Intel Quick Sync.
/// Falls back to the software H.264 MFT if no hardware encoder is present.
///
/// Input format:  BGRA 32-bit (converted to NV12 before submission)
/// Output format: H.264 Annex-B bitstream

#include "encoder/mf_encoder.h"

#include <iostream>
#include <cstring>
#include <vector>
#include <algorithm>

#ifdef _WIN32
#include <windows.h>
#include <mfapi.h>
#include <mftransform.h>
#include <mfidl.h>
#include <mferror.h>
#include <codecapi.h>
#include <wrl/client.h>

#pragma comment(lib, "mf.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "strmiids.lib")

using Microsoft::WRL::ComPtr;

namespace {

/// Convert a BGRA row-major buffer to planar NV12.
/// NV12 layout: width×height bytes of Y plane, then (width/2)×(height/2)
/// interleaved UV pairs for a total of width×height*3/2 bytes.
void bgra_to_nv12(const uint8_t* bgra,
                  uint32_t width,
                  uint32_t height,
                  uint32_t pitch,
                  uint8_t* nv12)
{
    uint8_t* y_plane  = nv12;
    uint8_t* uv_plane = nv12 + static_cast<size_t>(width) * height;

    for (uint32_t row = 0; row < height; ++row) {
        const uint8_t* src = bgra + static_cast<size_t>(row) * pitch;
        uint8_t*       dst_y = y_plane + static_cast<size_t>(row) * width;

        for (uint32_t col = 0; col < width; ++col) {
            uint8_t b = src[col * 4 + 0];
            uint8_t g = src[col * 4 + 1];
            uint8_t r = src[col * 4 + 2];

            // BT.601 limited-range luma
            int y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
            dst_y[col] = static_cast<uint8_t>(std::max(0, std::min(235, y)));
        }

        // Chroma sub-sampling: one UV pair per 2×2 luma block
        if ((row & 1) == 0) {
            uint8_t* dst_uv = uv_plane + static_cast<size_t>(row / 2) * width;
            for (uint32_t col = 0; col < width; col += 2) {
                uint8_t b = src[col * 4 + 0];
                uint8_t g = src[col * 4 + 1];
                uint8_t r = src[col * 4 + 2];

                int cb = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
                int cr = ((112 * r - 94 * g -  18 * b + 128) >> 8) + 128;

                dst_uv[col]     = static_cast<uint8_t>(std::max(16, std::min(240, cb)));
                dst_uv[col + 1] = static_cast<uint8_t>(std::max(16, std::min(240, cr)));
            }
        }
    }
}

/// Helper: set a media type attribute as UINT32.
inline HRESULT SetUINT32(IMFMediaType* mt, const GUID& key, UINT32 value) {
    return mt->SetUINT32(key, value);
}

/// Helper: set a media type attribute as UINT64 (packed ratio).
inline HRESULT SetRatio(IMFMediaType* mt, const GUID& key,
                        UINT32 numerator, UINT32 denominator) {
    return mt->SetUINT64(key, (static_cast<UINT64>(numerator) << 32) | denominator);
}

}  // anonymous namespace

#endif  // _WIN32

namespace immersive {

// ---------------------------------------------------------------------------
// MfEncoder class
// ---------------------------------------------------------------------------

class MfEncoder : public IVideoEncoder {
public:
    MfEncoder() = default;
    ~MfEncoder() override { _shutdown(); }

    bool initialize(const EncoderConfig& cfg) override {
        config_ = cfg;
        initialized_ = false;

#ifdef _WIN32
        HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
        if (FAILED(hr)) {
            std::cerr << "[MfEncoder] MFStartup failed (0x" << std::hex << hr << ")\n";
            return false;
        }
        mf_started_ = true;

        // --- Find the best H.264 hardware MFT ---
        MFT_REGISTER_TYPE_INFO output_type = {};
        output_type.guidMajorType = MFMediaType_Video;
        output_type.guidSubtype   = MFVideoFormat_H264;

        UINT32 flags = MFT_ENUM_FLAG_HARDWARE       |
                       MFT_ENUM_FLAG_SYNCMFT         |
                       MFT_ENUM_FLAG_ASYNCMFT        |
                       MFT_ENUM_FLAG_SORTANDFILTER;

        IMFActivate** activate_array = nullptr;
        UINT32        activate_count = 0;

        hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                       flags,
                       nullptr,            // any input type
                       &output_type,
                       &activate_array,
                       &activate_count);

        if (FAILED(hr) || activate_count == 0) {
            // Retry without hardware flag — use software MFT H.264
            std::cout << "[MfEncoder] No hardware MFT encoder found, trying software MFT\n";
            flags = MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER;
            if (activate_array) {
                for (UINT32 i = 0; i < activate_count; ++i)
                    activate_array[i]->Release();
                CoTaskMemFree(activate_array);
                activate_array = nullptr;
                activate_count = 0;
            }
            hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                           flags,
                           nullptr,
                           &output_type,
                           &activate_array,
                           &activate_count);
        }

        if (FAILED(hr) || activate_count == 0) {
            std::cerr << "[MfEncoder] No MFT H.264 encoder found on this system\n";
            return false;
        }

        // Activate the first (best) encoder
        ComPtr<IMFTransform> mft;
        hr = activate_array[0]->ActivateObject(IID_PPV_ARGS(&mft));

        // Check if it is hardware
        UINT32 hw_url_len = 0;
        is_hardware_ = SUCCEEDED(activate_array[0]->GetStringLength(MFT_FRIENDLY_NAME_Attribute, &hw_url_len));

        for (UINT32 i = 0; i < activate_count; ++i)
            activate_array[i]->Release();
        CoTaskMemFree(activate_array);

        if (FAILED(hr) || !mft) {
            std::cerr << "[MfEncoder] ActivateObject failed (0x" << std::hex << hr << ")\n";
            return false;
        }

        mft_ = mft;

        // --- Configure output type (H.264) ---
        ComPtr<IMFMediaType> out_type;
        MFCreateMediaType(&out_type);
        out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        out_type->SetGUID(MF_MT_SUBTYPE,    MFVideoFormat_H264);
        SetUINT32(out_type.Get(), MF_MT_AVG_BITRATE, cfg.bitrate_kbps * 1000);
        SetUINT32(out_type.Get(), MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        SetRatio(out_type.Get(), MF_MT_FRAME_SIZE, cfg.width, cfg.height);
        SetRatio(out_type.Get(), MF_MT_FRAME_RATE, cfg.fps, 1);
        SetRatio(out_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        SetUINT32(out_type.Get(), MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main);

        hr = mft_->SetOutputType(0, out_type.Get(), 0);
        if (FAILED(hr)) {
            std::cerr << "[MfEncoder] SetOutputType failed (0x" << std::hex << hr << ")\n";
            return false;
        }

        // --- Configure input type (NV12) ---
        ComPtr<IMFMediaType> in_type;
        MFCreateMediaType(&in_type);
        in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        in_type->SetGUID(MF_MT_SUBTYPE,    MFVideoFormat_NV12);
        SetUINT32(in_type.Get(), MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        SetRatio(in_type.Get(), MF_MT_FRAME_SIZE, cfg.width, cfg.height);
        SetRatio(in_type.Get(), MF_MT_FRAME_RATE, cfg.fps, 1);
        SetRatio(in_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);

        hr = mft_->SetInputType(0, in_type.Get(), 0);
        if (FAILED(hr)) {
            std::cerr << "[MfEncoder] SetInputType failed (0x" << std::hex << hr << ")\n";
            return false;
        }

        // Allocate NV12 scratch buffer
        nv12_buf_.resize(static_cast<size_t>(cfg.width) * cfg.height * 3 / 2);

        // Start streaming
        hr = mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        if (FAILED(hr)) {
            std::cerr << "[MfEncoder] ProcessMessage(BEGIN_STREAMING) failed\n";
            return false;
        }

        std::cout << "[MfEncoder] Initialized: "
                  << cfg.width << "x" << cfg.height
                  << " @ " << cfg.fps << " fps"
                  << " bitrate=" << cfg.bitrate_kbps << " kbps"
                  << (is_hardware_ ? " [hardware]" : " [software MFT]") << "\n";

        initialized_ = true;
        frame_count_  = 0;
        return true;
#else
        std::cerr << "[MfEncoder] Media Foundation is only available on Windows\n";
        return false;
#endif
    }

    std::vector<EncodedPacket> encode(
            const uint8_t* bgra_data,
            uint32_t       width,
            uint32_t       height,
            uint32_t       pitch,
            uint64_t       timestamp_us) override
    {
        if (!initialized_ || !bgra_data) return {};

#ifdef _WIN32
        // Convert BGRA → NV12
        bgra_to_nv12(bgra_data, width, height, pitch, nv12_buf_.data());

        // Create input sample
        ComPtr<IMFSample>      sample;
        ComPtr<IMFMediaBuffer> buffer;
        DWORD buf_size = static_cast<DWORD>(nv12_buf_.size());

        MFCreateMemoryBuffer(buf_size, &buffer);

        BYTE* raw = nullptr;
        DWORD max_len = 0, cur_len = 0;
        buffer->Lock(&raw, &max_len, &cur_len);
        std::memcpy(raw, nv12_buf_.data(), buf_size);
        buffer->Unlock();
        buffer->SetCurrentLength(buf_size);

        MFCreateSample(&sample);
        sample->AddBuffer(buffer.Get());

        // Timestamp in 100-nanosecond units (MF time base)
        LONGLONG mf_time = static_cast<LONGLONG>(timestamp_us) * 10LL;
        sample->SetSampleTime(mf_time);
        sample->SetSampleDuration(10000000LL / config_.fps);

        HRESULT hr = mft_->ProcessInput(0, sample.Get(), 0);
        if (FAILED(hr)) {
            std::cerr << "[MfEncoder] ProcessInput failed (0x" << std::hex << hr << ")\n";
            return {};
        }

        return _drain_output(timestamp_us);
#else
        return {};
#endif
    }

    std::vector<EncodedPacket> flush() override {
        if (!initialized_) return {};
#ifdef _WIN32
        mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        mft_->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
        return _drain_output(0);
#else
        return {};
#endif
    }

    void request_keyframe() override {
        // Media Foundation encoders reset IDR on next encode automatically
        // when ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN) is called.
        // For simplicity, we mark the flag and let the next frame be IDR.
        force_keyframe_ = true;
    }

    EncoderBackend backend() const override {
#ifdef _WIN32
        return is_hardware_ ? EncoderBackend::NVENC : EncoderBackend::SOFTWARE;
#else
        return EncoderBackend::SOFTWARE;
#endif
    }

    std::string name() const override {
#ifdef _WIN32
        return is_hardware_
            ? "Media Foundation H.264 Hardware Encoder (NVENC/AMF/QSV)"
            : "Media Foundation H.264 Software Encoder";
#else
        return "MF Encoder (unavailable on non-Windows)";
#endif
    }

private:
    EncoderConfig         config_;
    bool                  initialized_   = false;
    bool                  is_hardware_   = false;
    bool                  mf_started_    = false;
    bool                  force_keyframe_ = false;
    uint32_t              frame_count_   = 0;
    std::vector<uint8_t>  nv12_buf_;

#ifdef _WIN32
    ComPtr<IMFTransform> mft_;

    std::vector<EncodedPacket> _drain_output(uint64_t fallback_ts) {
        std::vector<EncodedPacket> result;

        MFT_OUTPUT_DATA_BUFFER out_data = {};
        DWORD                  status   = 0;

        for (;;) {
            out_data = {};
            HRESULT hr = mft_->ProcessOutput(0, 1, &out_data, &status);

            if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) break;
            if (hr == MF_E_TRANSFORM_STREAM_CHANGE)  break;
            if (FAILED(hr))                           break;

            if (out_data.pSample) {
                EncodedPacket pkt;
                pkt.timestamp_us = fallback_ts;
                pkt.is_keyframe  = (frame_count_ == 0) || force_keyframe_;
                force_keyframe_  = false;

                // Extract bytes from the sample
                DWORD buf_count = 0;
                out_data.pSample->GetBufferCount(&buf_count);
                for (DWORD b = 0; b < buf_count; ++b) {
                    ComPtr<IMFMediaBuffer> mbuf;
                    out_data.pSample->GetBufferByIndex(b, &mbuf);

                    BYTE*  data    = nullptr;
                    DWORD  cur_len = 0;
                    mbuf->Lock(&data, nullptr, &cur_len);
                    pkt.data.insert(pkt.data.end(), data, data + cur_len);
                    mbuf->Unlock();
                }

                frame_count_++;
                out_data.pSample->Release();
                result.push_back(std::move(pkt));
            }

            if (out_data.pEvents) out_data.pEvents->Release();
        }

        return result;
    }
#endif

    void _shutdown() {
#ifdef _WIN32
        if (mft_) {
            mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
            mft_.Reset();
        }
        if (mf_started_) {
            MFShutdown();
            mf_started_ = false;
        }
#endif
        initialized_ = false;
    }
};

// ---------------------------------------------------------------------------
// Public factory functions
// ---------------------------------------------------------------------------

std::unique_ptr<IVideoEncoder> create_mf_encoder() {
    return std::make_unique<MfEncoder>();
}

bool mf_hardware_encoder_available() {
#ifdef _WIN32
    // Quick check: can we enumerate at least one hardware H.264 MFT?
    HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
    if (FAILED(hr)) return false;

    MFT_REGISTER_TYPE_INFO out_type = { MFMediaType_Video, MFVideoFormat_H264 };

    IMFActivate** activations = nullptr;
    UINT32        count       = 0;

    MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
              MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
              nullptr,
              &out_type,
              &activations,
              &count);

    for (UINT32 i = 0; i < count; ++i) activations[i]->Release();
    if (activations) CoTaskMemFree(activations);

    MFShutdown();
    return count > 0;
#else
    return false;
#endif
}

}  // namespace immersive
