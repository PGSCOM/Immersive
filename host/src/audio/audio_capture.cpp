/// WASAPI loopback audio capture implementation.
///
/// Captures the Windows audio render endpoint (system audio / "what you hear")
/// using WASAPI in loopback mode, resamples to PCM-16 stereo 48 kHz,
/// and makes frames available via get_frame().

#include "audio/audio_capture.h"
#include <iostream>
#include <atomic>
#include <thread>
#include <mutex>
#include <queue>
#include <cstring>

#include <windows.h>
#include <objbase.h>   // CoInitializeEx needed for WASAPI thread init
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <wrl/client.h>

#pragma comment(lib, "avrt.lib")
#pragma comment(lib, "ole32.lib")

using Microsoft::WRL::ComPtr;

namespace {
    // Target output format
    constexpr uint32_t TARGET_SAMPLE_RATE = 48000;
    constexpr uint8_t  TARGET_CHANNELS    = 2;
    // Packet size: 480 samples per channel @ 48 kHz → 10 ms
    constexpr uint32_t PACKET_SAMPLES     = 480;
}  // anonymous namespace

namespace immersive {

// ---------------------------------------------------------------------------
// WASAPI loopback capture
// ---------------------------------------------------------------------------

class WasapiAudioCapture : public IAudioCapture {
public:
    WasapiAudioCapture() = default;

    ~WasapiAudioCapture() override {
        stop();
    }

    bool start() override {
        if (capturing_) return true;

        // Initialize COM (for this thread)
        HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        bool com_owned = SUCCEEDED(hr);

        // Get the default audio render endpoint
        ComPtr<IMMDeviceEnumerator> enumerator;
        hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_ALL,
                              IID_PPV_ARGS(&enumerator));
        if (FAILED(hr)) {
            std::cerr << "[AudioCapture] CoCreateInstance(MMDeviceEnumerator) failed (0x"
                      << std::hex << hr << ")\n";
            if (com_owned) CoUninitialize();
            return false;
        }

        ComPtr<IMMDevice> device;
        hr = enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &device);
        if (FAILED(hr)) {
            std::cerr << "[AudioCapture] GetDefaultAudioEndpoint failed (0x"
                      << std::hex << hr << ")\n";
            if (com_owned) CoUninitialize();
            return false;
        }

        // Activate IAudioClient
        ComPtr<IAudioClient> audio_client;
        hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL,
                               nullptr, reinterpret_cast<void**>(audio_client.GetAddressOf()));
        if (FAILED(hr)) {
            std::cerr << "[AudioCapture] IAudioClient activate failed (0x"
                      << std::hex << hr << ")\n";
            if (com_owned) CoUninitialize();
            return false;
        }

        // Get the mix format
        WAVEFORMATEX* mix_fmt = nullptr;
        audio_client->GetMixFormat(&mix_fmt);

        // Initialize in loopback mode (AUDCLNT_STREAMFLAGS_LOOPBACK)
        hr = audio_client->Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_LOOPBACK,
            10000000LL,   // 1 second buffer (100-ns units)
            0,
            mix_fmt,
            nullptr);

        if (FAILED(hr)) {
            std::cerr << "[AudioCapture] IAudioClient::Initialize failed (0x"
                      << std::hex << hr << ")\n";
            CoTaskMemFree(mix_fmt);
            if (com_owned) CoUninitialize();
            return false;
        }

        // Save mix format details for conversion
        mix_sample_rate_ = mix_fmt->nSamplesPerSec;
        mix_channels_    = mix_fmt->nChannels;
        mix_bits_        = mix_fmt->wBitsPerSample;

        CoTaskMemFree(mix_fmt);
        mix_fmt = nullptr;

        // Get the capture client
        ComPtr<IAudioCaptureClient> capture_client;
        hr = audio_client->GetService(__uuidof(IAudioCaptureClient),
                                       reinterpret_cast<void**>(capture_client.GetAddressOf()));
        if (FAILED(hr)) {
            std::cerr << "[AudioCapture] GetService(IAudioCaptureClient) failed (0x"
                      << std::hex << hr << ")\n";
            if (com_owned) CoUninitialize();
            return false;
        }

        audio_client_   = audio_client;
        capture_client_ = capture_client;
        com_owned_      = com_owned;

        // Start the audio stream
        hr = audio_client_->Start();
        if (FAILED(hr)) {
            std::cerr << "[AudioCapture] IAudioClient::Start failed (0x"
                      << std::hex << hr << ")\n";
            audio_client_.Reset();
            capture_client_.Reset();
            if (com_owned_) CoUninitialize();
            return false;
        }

        capturing_    = true;
        resample_pos_ = 0.0;
        accumulator_.clear();

        // Start capture thread
        capture_thread_ = std::thread([this]() { _capture_loop(); });

        std::cout << "[AudioCapture] WASAPI loopback started ("
                  << mix_sample_rate_ << " Hz, "
                  << (int)mix_channels_ << " ch, "
                  << (int)mix_bits_ << " bit)\n";
        return true;
    }

    void stop() override {
        if (!capturing_) return;
        capturing_ = false;

        if (capture_thread_.joinable()) capture_thread_.join();

        if (audio_client_) {
            audio_client_->Stop();
            audio_client_.Reset();
            capture_client_.Reset();
        }
        if (com_owned_) {
            CoUninitialize();
            com_owned_ = false;
        }
        std::cout << "[AudioCapture] Stopped\n";
    }

    std::unique_ptr<AudioFrame> get_frame() override {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        if (frame_queue_.empty()) return nullptr;
        auto frame = std::move(frame_queue_.front());
        frame_queue_.pop();
        return frame;
    }

    bool is_capturing() const override { return capturing_; }

private:
    std::atomic<bool>              capturing_{false};
    std::thread                    capture_thread_;
    std::mutex                     queue_mutex_;
    std::queue<std::unique_ptr<AudioFrame>> frame_queue_;
    uint32_t                       seq_counter_ = 0;

    ComPtr<IAudioClient>        audio_client_;
    ComPtr<IAudioCaptureClient> capture_client_;
    uint32_t                    mix_sample_rate_ = 48000;
    uint8_t                     mix_channels_    = 2;
    uint8_t                     mix_bits_        = 16;
    bool                        com_owned_       = false;

    void _capture_loop() {
        // WASAPI interfaces are MTA; a thread that never entered an apartment
        // is not a legal caller for them.
        const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        const bool thread_com = SUCCEEDED(com_hr);

        // Boost thread priority
        DWORD task_index = 0;
        HANDLE task = AvSetMmThreadCharacteristicsW(L"Audio", &task_index);

        while (capturing_) {
            // Sleep ~5 ms between polls
            Sleep(5);

            UINT32 next_packet_size = 0;
            HRESULT hr = capture_client_->GetNextPacketSize(&next_packet_size);
            if (FAILED(hr)) break;

            while (next_packet_size > 0) {
                BYTE*  data       = nullptr;
                UINT32 num_frames = 0;
                DWORD  flags      = 0;

                hr = capture_client_->GetBuffer(&data, &num_frames, &flags, nullptr, nullptr);
                if (FAILED(hr)) break;

                if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && num_frames > 0) {
                    _enqueue_samples(data, num_frames, flags);
                }

                capture_client_->ReleaseBuffer(num_frames);

                hr = capture_client_->GetNextPacketSize(&next_packet_size);
                if (FAILED(hr)) break;
            }
        }

        if (task) AvRevertMmThreadCharacteristics(task);
        if (thread_com) CoUninitialize();
    }

    /// Read one channel of one source frame as a normalised float.
    inline float _sample_at(const BYTE* raw, UINT32 frame, uint8_t ch) const {
        const size_t idx = static_cast<size_t>(frame) * mix_channels_ + ch;
        if (mix_bits_ == 32) {
            return reinterpret_cast<const float*>(raw)[idx];
        }
        return reinterpret_cast<const int16_t*>(raw)[idx] / 32768.0f;
    }

    void _enqueue_samples(const BYTE* raw, UINT32 num_frames, DWORD /*flags*/) {
        if (mix_bits_ != 32 && mix_bits_ != 16) return;  // unsupported depth
        if (mix_channels_ == 0 || num_frames == 0) return;

        // The wire format is fixed at PCM-16 stereo 48 kHz (see AudioStart), but
        // the WASAPI mix format is whatever the endpoint runs at — very often
        // 44.1 kHz, and sometimes 6 or 8 channels. Relabelling those samples as
        // 48 kHz stereo (what this used to do) plays them at the wrong pitch and
        // shuffles the channels. Downmix to 2 channels and resample linearly.
        const uint8_t use_ch = (mix_channels_ >= 2) ? 2 : 1;
        const double step = static_cast<double>(mix_sample_rate_) / TARGET_SAMPLE_RATE;

        while (resample_pos_ < num_frames) {
            const UINT32 i0 = static_cast<UINT32>(resample_pos_);
            const UINT32 i1 = (i0 + 1 < num_frames) ? i0 + 1 : i0;
            const float  t  = static_cast<float>(resample_pos_ - i0);

            for (uint8_t ch = 0; ch < 2; ++ch) {
                const uint8_t src_ch = (ch < use_ch) ? ch : 0;
                float v = _sample_at(raw, i0, src_ch) * (1.0f - t)
                        + _sample_at(raw, i1, src_ch) * t;
                if (v >  1.0f) v =  1.0f;
                if (v < -1.0f) v = -1.0f;
                accumulator_.push_back(static_cast<int16_t>(v * 32767.0f));
            }
            resample_pos_ += step;
        }
        // Carry the fractional remainder into the next WASAPI buffer so the
        // output stays continuous across packet boundaries.
        resample_pos_ -= num_frames;

        const size_t samples_per_packet = PACKET_SAMPLES * TARGET_CHANNELS;
        while (accumulator_.size() >= samples_per_packet) {
            auto frame         = std::make_unique<AudioFrame>();
            frame->sample_rate = TARGET_SAMPLE_RATE;
            frame->channels    = TARGET_CHANNELS;
            frame->seq         = seq_counter_++;
            frame->samples.assign(accumulator_.begin(),
                                  accumulator_.begin() + samples_per_packet);
            accumulator_.erase(accumulator_.begin(),
                               accumulator_.begin() + samples_per_packet);

            std::lock_guard<std::mutex> lock(queue_mutex_);
            // Limit queue depth to avoid unbounded memory growth
            if (frame_queue_.size() < 32) {
                frame_queue_.push(std::move(frame));
            }
        }
    }

    std::vector<int16_t> accumulator_;
    double               resample_pos_ = 0.0;  ///< fractional read cursor
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

std::unique_ptr<IAudioCapture> create_audio_capture() {
    return std::make_unique<WasapiAudioCapture>();
}

}  // namespace immersive
