/// Media Foundation hardware H.264 encoder implementation.
///
/// Uses IMFTransform (MFT) to encode BGRA frames to H.264 bitstream.
/// The MFT infrastructure automatically selects the best available
/// hardware encoder: NVIDIA NVENC, AMD AMF, or Intel Quick Sync.
/// Falls back to the software H.264 MFT if no hardware encoder is present.
///
/// Hardware MFTs are asynchronous: they must be unlocked with
/// MF_TRANSFORM_ASYNC_UNLOCK and driven through the
/// METransformNeedInput / METransformHaveOutput event model.
/// The software H.264 MFT is synchronous and uses the classic
/// ProcessInput/ProcessOutput loop with caller-allocated output samples.
///
/// Input format:  BGRA 32-bit (converted to NV12 before submission)
/// Output format: H.264 Annex-B bitstream

#include "encoder/mf_encoder.h"

#include <iostream>
#include <cstring>
#include <vector>
#include <algorithm>
#include <chrono>
#include <thread>

#ifdef _WIN32
// WIN32_LEAN_AND_MEAN is set globally; MF headers need objbase.h explicitly
#include <windows.h>
#include <objbase.h>   // CoInitializeEx, CoUninitialize
#include <initguid.h>  // instantiate CODECAPI_* GUIDs in this TU
#include <mfapi.h>
#include <mftransform.h>
#include <mfidl.h>
#include <mferror.h>
#include <strmif.h>    // ICodecAPI
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
            for (uint32_t col = 0; col + 1 < width; col += 2) {
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

/// Helper: set a media type attribute as UINT64 (packed ratio).
inline HRESULT SetRatio(IMFMediaType* mt, const GUID& key,
                        UINT32 numerator, UINT32 denominator) {
    return mt->SetUINT64(key, (static_cast<UINT64>(numerator) << 32) | denominator);
}

/// MFVideoFormat_AV1 ('AV01') — defined locally so older SDKs also build.
const GUID kMFVideoFormat_AV1 =
    { 0x31305641, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 } };

/// Output subtype for a given codec.
GUID codec_subtype(immersive::VideoCodec codec) {
    switch (codec) {
    case immersive::VideoCodec::H265: return MFVideoFormat_HEVC;
    case immersive::VideoCodec::AV1:  return kMFVideoFormat_AV1;
    case immersive::VideoCodec::H264:
    default:                          return MFVideoFormat_H264;
    }
}

const char* codec_name_str(immersive::VideoCodec codec) {
    switch (codec) {
    case immersive::VideoCodec::H265: return "HEVC";
    case immersive::VideoCodec::AV1:  return "AV1";
    case immersive::VideoCodec::H264:
    default:                          return "H.264";
    }
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
#ifdef _WIN32
        // Allow re-initialization (e.g. when the user selects another monitor)
        _shutdown();

        config_ = cfg;

        // Initialize COM on this thread (required before MFStartup)
        HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        com_initialized_ = SUCCEEDED(com_hr) || (com_hr == RPC_E_CHANGED_MODE);

        HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
        if (FAILED(hr)) {
            std::cerr << "[MfEncoder] MFStartup failed (0x" << std::hex << hr << ")\n";
            if (com_initialized_) { CoUninitialize(); com_initialized_ = false; }
            return false;
        }
        mf_started_ = true;

        if (!_create_transform()) {
            _shutdown();
            return false;
        }

        if (!_configure_types()) {
            _shutdown();
            return false;
        }

        // Best-effort low-latency tuning via ICodecAPI
        _apply_codec_api_tuning();

        // Allocate NV12 scratch buffer
        nv12_buf_.resize(static_cast<size_t>(cfg.width) * cfg.height * 3 / 2);

        // Start streaming. Async MFTs only emit METransformNeedInput after
        // NOTIFY_START_OF_STREAM; both messages are harmless for sync MFTs.
        hr = mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        if (FAILED(hr)) {
            std::cerr << "[MfEncoder] ProcessMessage(BEGIN_STREAMING) failed (0x"
                      << std::hex << hr << ")\n";
            _shutdown();
            return false;
        }
        mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

        std::cout << "[MfEncoder] Initialized " << codec_name_str(cfg.codec) << ": "
                  << cfg.width << "x" << cfg.height
                  << " @ " << cfg.fps << " fps"
                  << " bitrate=" << cfg.bitrate_kbps << " kbps"
                  << (is_hardware_ ? " [hardware]" : " [software MFT]")
                  << (is_async_ ? " [async]" : " [sync]") << "\n";

        initialized_         = true;
        frame_count_         = 0;
        need_input_credits_  = 0;
        return true;
#else
        (void)cfg;
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
        if (width != config_.width || height != config_.height) {
            // Capture resolution no longer matches the encoder configuration
            // (e.g. display mode change). The caller must re-initialize.
            std::cerr << "[MfEncoder] Frame size " << std::dec << width << "x" << height
                      << " does not match encoder " << config_.width << "x"
                      << config_.height << ", dropping frame\n";
            return {};
        }

        // Convert BGRA → NV12
        bgra_to_nv12(bgra_data, width, height, pitch, nv12_buf_.data());

        // Create input sample
        ComPtr<IMFSample>      sample;
        ComPtr<IMFMediaBuffer> buffer;
        DWORD buf_size = static_cast<DWORD>(nv12_buf_.size());

        if (FAILED(MFCreateMemoryBuffer(buf_size, &buffer))) return {};

        BYTE* raw = nullptr;
        DWORD max_len = 0, cur_len = 0;
        buffer->Lock(&raw, &max_len, &cur_len);
        std::memcpy(raw, nv12_buf_.data(), buf_size);
        buffer->Unlock();
        buffer->SetCurrentLength(buf_size);

        if (FAILED(MFCreateSample(&sample))) return {};
        sample->AddBuffer(buffer.Get());

        // Timestamp in 100-nanosecond units (MF time base)
        LONGLONG mf_time = static_cast<LONGLONG>(timestamp_us) * 10LL;
        sample->SetSampleTime(mf_time);
        sample->SetSampleDuration(10000000LL / std::max<uint32_t>(1, config_.fps));

        if (force_keyframe_) {
            _force_keyframe_now();
            force_keyframe_ = false;
        }

        std::vector<EncodedPacket> result;

        if (is_async_) {
            _encode_async(sample.Get(), result);
        } else {
            HRESULT hr = mft_->ProcessInput(0, sample.Get(), 0);
            if (FAILED(hr)) {
                std::cerr << "[MfEncoder] ProcessInput failed (0x" << std::hex << hr << ")\n";
                return {};
            }
            // Drain all currently available output
            while (_process_output_once(result)) {}
        }

        for (auto& pkt : result) {
            if (pkt.timestamp_us == 0) pkt.timestamp_us = timestamp_us;
        }
        return result;
#else
        (void)width; (void)height; (void)pitch; (void)timestamp_us;
        return {};
#endif
    }

    std::vector<EncodedPacket> flush() override {
        if (!initialized_) return {};
#ifdef _WIN32
        std::vector<EncodedPacket> result;
        mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        mft_->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);

        if (is_async_) {
            // Pump events until DrainComplete (bounded wait)
            auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
            bool drained = false;
            while (!drained && std::chrono::steady_clock::now() < deadline) {
                if (!_pump_one_event(result, &drained)) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
            }
        } else {
            while (_process_output_once(result)) {}
        }
        return result;
#else
        return {};
#endif
    }

    void request_keyframe() override {
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
        std::string n = "Media Foundation ";
        n += codec_name_str(config_.codec);
        n += is_hardware_ ? " Hardware Encoder (NVENC/AMF/QSV)"
                          : " Software Encoder";
        return n;
#else
        return "MF Encoder (unavailable on non-Windows)";
#endif
    }

private:
    EncoderConfig         config_;
    bool                  initialized_     = false;
    bool                  is_hardware_     = false;
    bool                  is_async_        = false;
    bool                  mf_started_      = false;
    bool                  com_initialized_ = false;
    bool                  force_keyframe_  = false;
    uint32_t              frame_count_     = 0;
    int                   need_input_credits_ = 0;
    std::vector<uint8_t>  nv12_buf_;

#ifdef _WIN32
    ComPtr<IMFTransform>           mft_;
    ComPtr<IMFMediaEventGenerator> event_gen_;
    ComPtr<ICodecAPI>              codec_api_;

    /// Enumerate and activate the best available encoder MFT for the codec.
    bool _create_transform() {
        MFT_REGISTER_TYPE_INFO output_type = {};
        output_type.guidMajorType = MFMediaType_Video;
        output_type.guidSubtype   = codec_subtype(config_.codec);

        IMFActivate** activate_array = nullptr;
        UINT32        activate_count = 0;

        // Pass 1: hardware encoders (these are async MFTs)
        HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                               MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                               nullptr,
                               &output_type,
                               &activate_array,
                               &activate_count);
        is_hardware_ = SUCCEEDED(hr) && activate_count > 0;

        if (!is_hardware_) {
            if (activate_array) { CoTaskMemFree(activate_array); activate_array = nullptr; }
            activate_count = 0;

            // Pass 2: synchronous software MFT. Only H.264 ships a software
            // encoder MFT with Windows; HEVC/AV1 are hardware-only.
            std::cout << "[MfEncoder] No hardware " << codec_name_str(config_.codec)
                      << " MFT found, trying software MFT\n";
            hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                           MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
                           nullptr,
                           &output_type,
                           &activate_array,
                           &activate_count);
        }

        if (FAILED(hr) || activate_count == 0) {
            std::cerr << "[MfEncoder] No MFT " << codec_name_str(config_.codec)
                      << " encoder found on this system\n";
            if (activate_array) CoTaskMemFree(activate_array);
            return false;
        }

        // Log the friendly name of the chosen encoder
        WCHAR friendly[256] = {};
        UINT32 name_len = 0;
        if (SUCCEEDED(activate_array[0]->GetString(MFT_FRIENDLY_NAME_Attribute,
                                                   friendly, 255, &name_len))) {
            char name_utf8[512] = {};
            WideCharToMultiByte(CP_UTF8, 0, friendly, -1,
                                name_utf8, sizeof(name_utf8), nullptr, nullptr);
            std::cout << "[MfEncoder] Using encoder: " << name_utf8 << "\n";
        }

        ComPtr<IMFTransform> mft;
        hr = activate_array[0]->ActivateObject(IID_PPV_ARGS(&mft));

        for (UINT32 i = 0; i < activate_count; ++i)
            activate_array[i]->Release();
        CoTaskMemFree(activate_array);

        if (FAILED(hr) || !mft) {
            std::cerr << "[MfEncoder] ActivateObject failed (0x" << std::hex << hr << ")\n";
            return false;
        }
        mft_ = mft;

        // Async MFTs must be unlocked before any type negotiation, and are
        // then driven exclusively through the media event generator.
        is_async_ = false;
        ComPtr<IMFAttributes> attrs;
        if (SUCCEEDED(mft_->GetAttributes(&attrs)) && attrs) {
            UINT32 async_flag = 0;
            if (SUCCEEDED(attrs->GetUINT32(MF_TRANSFORM_ASYNC, &async_flag)) && async_flag) {
                is_async_ = true;
                hr = attrs->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
                if (FAILED(hr)) {
                    std::cerr << "[MfEncoder] Failed to unlock async MFT (0x"
                              << std::hex << hr << ")\n";
                    return false;
                }
                if (FAILED(mft_.As(&event_gen_)) || !event_gen_) {
                    std::cerr << "[MfEncoder] Async MFT has no event generator\n";
                    return false;
                }
            }
        }

        return true;
    }

    /// Negotiate output (H.264/HEVC/AV1) then input (NV12) media types.
    /// Encoder MFTs require the output type to be set first.
    bool _configure_types() {
        const GUID subtype_wanted = codec_subtype(config_.codec);

        // --- Output type ---
        ComPtr<IMFMediaType> out_type;
        HRESULT hr = MFCreateMediaType(&out_type);
        if (FAILED(hr)) return false;

        out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        out_type->SetGUID(MF_MT_SUBTYPE, subtype_wanted);
        out_type->SetUINT32(MF_MT_AVG_BITRATE, config_.bitrate_kbps * 1000);
        out_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        if (config_.codec == VideoCodec::H264) {
            out_type->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main);
        } else if (config_.codec == VideoCodec::H265) {
            out_type->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH265VProfile_Main_420_8);
        }
        SetRatio(out_type.Get(), MF_MT_FRAME_SIZE, config_.width, config_.height);
        SetRatio(out_type.Get(), MF_MT_FRAME_RATE, config_.fps, 1);
        SetRatio(out_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);

        hr = mft_->SetOutputType(0, out_type.Get(), 0);
        if (FAILED(hr)) {
            // Fallback: iterate the types the encoder proposes
            bool output_set = false;
            for (DWORD i = 0; ; ++i) {
                ComPtr<IMFMediaType> t;
                if (FAILED(mft_->GetOutputAvailableType(0, i, &t))) break;
                GUID subtype = {};
                t->GetGUID(MF_MT_SUBTYPE, &subtype);
                if (subtype != subtype_wanted) continue;
                t->SetUINT32(MF_MT_AVG_BITRATE, config_.bitrate_kbps * 1000);
                t->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
                SetRatio(t.Get(), MF_MT_FRAME_SIZE, config_.width, config_.height);
                SetRatio(t.Get(), MF_MT_FRAME_RATE, config_.fps, 1);
                SetRatio(t.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
                if (SUCCEEDED(mft_->SetOutputType(0, t.Get(), 0))) {
                    output_set = true;
                    break;
                }
            }
            if (!output_set) {
                std::cerr << "[MfEncoder] Failed to set any "
                          << codec_name_str(config_.codec) << " output type\n";
                return false;
            }
        }

        // --- Input type (NV12) ---
        bool input_set = false;
        for (DWORD i = 0; ; ++i) {
            ComPtr<IMFMediaType> t;
            if (FAILED(mft_->GetInputAvailableType(0, i, &t))) break;
            GUID subtype = {};
            t->GetGUID(MF_MT_SUBTYPE, &subtype);
            if (subtype != MFVideoFormat_NV12) continue;
            t->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
            SetRatio(t.Get(), MF_MT_FRAME_SIZE, config_.width, config_.height);
            SetRatio(t.Get(), MF_MT_FRAME_RATE, config_.fps, 1);
            SetRatio(t.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
            if (SUCCEEDED(mft_->SetInputType(0, t.Get(), 0))) {
                input_set = true;
                break;
            }
        }

        if (!input_set) {
            // Fallback: build the NV12 type from scratch
            ComPtr<IMFMediaType> in_type;
            if (SUCCEEDED(MFCreateMediaType(&in_type))) {
                in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
                in_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
                in_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
                SetRatio(in_type.Get(), MF_MT_FRAME_SIZE, config_.width, config_.height);
                SetRatio(in_type.Get(), MF_MT_FRAME_RATE, config_.fps, 1);
                SetRatio(in_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
                input_set = SUCCEEDED(mft_->SetInputType(0, in_type.Get(), 0));
            }
        }

        if (!input_set) {
            std::cerr << "[MfEncoder] Failed to set NV12 input type\n";
            return false;
        }
        return true;
    }

    /// Best-effort encoder tuning: CBR + low latency.
    void _apply_codec_api_tuning() {
        if (FAILED(mft_.As(&codec_api_)) || !codec_api_) return;

        VARIANT v;
        VariantInit(&v);

        v.vt = VT_UI4;
        v.ulVal = eAVEncCommonRateControlMode_CBR;
        codec_api_->SetValue(&CODECAPI_AVEncCommonRateControlMode, &v);

        v.vt = VT_UI4;
        v.ulVal = config_.bitrate_kbps * 1000;
        codec_api_->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &v);

        v.vt = VT_BOOL;
        v.boolVal = VARIANT_TRUE;
        codec_api_->SetValue(&CODECAPI_AVLowLatencyMode, &v);

        v.vt = VT_UI4;
        v.ulVal = config_.gop_size;
        codec_api_->SetValue(&CODECAPI_AVEncMPVGOPSize, &v);
    }

    void _force_keyframe_now() {
        if (!codec_api_) return;
        VARIANT v;
        VariantInit(&v);
        v.vt = VT_UI4;
        v.ulVal = 1;
        codec_api_->SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &v);
    }

    /// Async path: wait for an input credit, submit the sample, then
    /// collect any output that is already available.
    void _encode_async(IMFSample* sample, std::vector<EncodedPacket>& result) {
        // Wait (bounded) until the encoder asks for input
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
        while (need_input_credits_ == 0 &&
               std::chrono::steady_clock::now() < deadline) {
            if (!_pump_one_event(result, nullptr)) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }

        if (need_input_credits_ > 0) {
            HRESULT hr = mft_->ProcessInput(0, sample, 0);
            if (FAILED(hr)) {
                std::cerr << "[MfEncoder] ProcessInput failed (0x" << std::hex << hr << ")\n";
            } else {
                need_input_credits_--;
            }
        } else {
            std::cerr << "[MfEncoder] Encoder did not request input in time, dropping frame\n";
        }

        // Collect whatever output is ready right now (without blocking)
        while (_pump_one_event(result, nullptr)) {}
    }

    /// Process a single pending MFT event. Returns false when no event is
    /// available. drained_out (optional) is set when DrainComplete arrives.
    bool _pump_one_event(std::vector<EncodedPacket>& result, bool* drained_out) {
        if (!event_gen_) return false;

        ComPtr<IMFMediaEvent> ev;
        HRESULT hr = event_gen_->GetEvent(MF_EVENT_FLAG_NO_WAIT, &ev);
        if (hr == MF_E_NO_EVENTS_AVAILABLE || FAILED(hr) || !ev) return false;

        MediaEventType type = MEUnknown;
        ev->GetType(&type);

        switch (type) {
        case METransformNeedInput:
            need_input_credits_++;
            break;
        case METransformHaveOutput:
            _process_output_once(result);
            break;
        case METransformDrainComplete:
            if (drained_out) *drained_out = true;
            break;
        default:
            break;
        }
        return true;
    }

    /// Run one ProcessOutput call, appending the encoded packet to `result`.
    /// Handles stream-change renegotiation and caller-allocated samples.
    /// Returns true if a packet was produced or the call should be retried.
    bool _process_output_once(std::vector<EncodedPacket>& result) {
        MFT_OUTPUT_STREAM_INFO stream_info = {};
        mft_->GetOutputStreamInfo(0, &stream_info);

        const bool mft_provides_samples =
            (stream_info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES |
                                    MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;

        MFT_OUTPUT_DATA_BUFFER out_data = {};
        out_data.dwStreamID = 0;

        ComPtr<IMFSample>      alloc_sample;
        ComPtr<IMFMediaBuffer> alloc_buffer;
        if (!mft_provides_samples) {
            DWORD size = stream_info.cbSize;
            if (size == 0) {
                size = config_.width * config_.height * 2;  // generous upper bound
            }
            if (FAILED(MFCreateSample(&alloc_sample)) ||
                FAILED(MFCreateMemoryBuffer(size, &alloc_buffer))) {
                return false;
            }
            alloc_sample->AddBuffer(alloc_buffer.Get());
            out_data.pSample = alloc_sample.Get();
        }

        DWORD status = 0;
        HRESULT hr = mft_->ProcessOutput(0, 1, &out_data, &status);

        if (out_data.pEvents) {
            out_data.pEvents->Release();
            out_data.pEvents = nullptr;
        }

        if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
            return false;
        }
        if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
            // Renegotiate the output type and retry on the next call
            ComPtr<IMFMediaType> new_type;
            if (SUCCEEDED(mft_->GetOutputAvailableType(0, 0, &new_type))) {
                mft_->SetOutputType(0, new_type.Get(), 0);
            }
            return true;
        }
        if (FAILED(hr)) {
            std::cerr << "[MfEncoder] ProcessOutput failed (0x" << std::hex << hr << ")\n";
            return false;
        }

        IMFSample* produced = out_data.pSample;
        if (!produced) return false;

        EncodedPacket pkt;
        pkt.timestamp_us = 0;  // caller fills in

        LONGLONG sample_time = 0;
        if (SUCCEEDED(produced->GetSampleTime(&sample_time))) {
            pkt.timestamp_us = static_cast<uint64_t>(sample_time / 10);
        }

        UINT32 clean_point = 0;
        produced->GetUINT32(MFSampleExtension_CleanPoint, &clean_point);
        pkt.is_keyframe = (clean_point != 0) || (frame_count_ == 0);

        DWORD buf_count = 0;
        produced->GetBufferCount(&buf_count);
        for (DWORD b = 0; b < buf_count; ++b) {
            ComPtr<IMFMediaBuffer> mbuf;
            if (FAILED(produced->GetBufferByIndex(b, &mbuf))) continue;

            BYTE*  data    = nullptr;
            DWORD  cur_len = 0;
            if (SUCCEEDED(mbuf->Lock(&data, nullptr, &cur_len))) {
                pkt.data.insert(pkt.data.end(), data, data + cur_len);
                mbuf->Unlock();
            }
        }

        // Samples allocated by the MFT must be released by the caller
        if (mft_provides_samples && out_data.pSample) {
            out_data.pSample->Release();
        }

        if (!pkt.data.empty()) {
            frame_count_++;
            result.push_back(std::move(pkt));
        }
        return true;
    }
#endif

    void _shutdown() {
#ifdef _WIN32
        if (mft_) {
            mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
            codec_api_.Reset();
            event_gen_.Reset();
            mft_.Reset();
        }
        if (mf_started_) {
            MFShutdown();
            mf_started_ = false;
        }
        if (com_initialized_) {
            CoUninitialize();
            com_initialized_ = false;
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

bool mf_encoder_available(VideoCodec codec) {
#ifdef _WIN32
    // COM must be initialized first
    bool com_init = false;
    HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    com_init = SUCCEEDED(com_hr) || (com_hr == RPC_E_CHANGED_MODE);

    HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
    if (FAILED(hr)) {
        if (com_init) CoUninitialize();
        return false;
    }

    MFT_REGISTER_TYPE_INFO out_type = { MFMediaType_Video, codec_subtype(codec) };

    auto enumerate = [&](UINT32 flags) -> UINT32 {
        IMFActivate** activations = nullptr;
        UINT32        count       = 0;
        MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                  flags | MFT_ENUM_FLAG_SORTANDFILTER,
                  nullptr,
                  &out_type,
                  &activations,
                  &count);
        for (UINT32 i = 0; i < count; ++i) activations[i]->Release();
        if (activations) CoTaskMemFree(activations);
        return count;
    };

    UINT32 count = enumerate(MFT_ENUM_FLAG_HARDWARE);
    if (count == 0 && codec == VideoCodec::H264) {
        // Windows ships a software H.264 encoder MFT
        count = enumerate(MFT_ENUM_FLAG_SYNCMFT);
    }

    MFShutdown();
    if (com_init) CoUninitialize();
    return count > 0;
#else
    (void)codec;
    return false;
#endif
}

bool mf_hardware_encoder_available() {
    return mf_encoder_available(VideoCodec::H264);
}

}  // namespace immersive
