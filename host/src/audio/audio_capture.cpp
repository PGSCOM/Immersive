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

#ifdef _WIN32
#include <windows.h>
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
#endif  // _WIN32

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

#ifdef _WIN32
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

        capturing_ = true;

        // Start capture thread
        capture_thread_ = std::thread([this]() { _capture_loop(); });

        std::cout << "[AudioCapture] WASAPI loopback started ("
                  << mix_sample_rate_ << " Hz, "
                  << (int)mix_channels_ << " ch, "
                  << (int)mix_bits_ << " bit)\n";
        return true;
#else
        std::cout << "[AudioCapture] Stub mode (non-Windows): no audio\n";
        capturing_ = true;
        return true;
#endif
    }

    void stop() override {
        if (!capturing_) return;
        capturing_ = false;

#ifdef _WIN32
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
#endif
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

#ifdef _WIN32
    ComPtr<IAudioClient>        audio_client_;
    ComPtr<IAudioCaptureClient> capture_client_;
    uint32_t                    mix_sample_rate_ = 48000;
    uint8_t                     mix_channels_    = 2;
    uint8_t                     mix_bits_        = 16;
    bool                        com_owned_       = false;

    void _capture_loop() {
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
    }

    void _enqueue_samples(const BYTE* raw, UINT32 num_frames, DWORD /*flags*/) {
        // Convert captured frames to PCM-16 stereo 48 kHz
        // We handle float32 (most common WASAPI mix format) and PCM-16 natively.
        std::vector<int16_t> pcm;

        if (mix_bits_ == 32) {
            // Float32 → PCM-16
            const float* fsrc = reinterpret_cast<const float*>(raw);
            for (UINT32 i = 0; i < num_frames * mix_channels_; ++i) {
                float s = fsrc[i];
                if (s >  1.0f) s =  1.0f;
                if (s < -1.0f) s = -1.0f;
                pcm.push_back(static_cast<int16_t>(s * 32767.0f));
            }
        } else if (mix_bits_ == 16) {
            const int16_t* isrc = reinterpret_cast<const int16_t*>(raw);
            pcm.assign(isrc, isrc + num_frames * mix_channels_);
        } else {
            // Unsupported bit depth; skip
            return;
        }

        // Accumulate into internal buffer, emit packets of PACKET_SAMPLES
        accumulator_.insert(accumulator_.end(), pcm.begin(), pcm.end());

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
#endif  // _WIN32
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

std::unique_ptr<IAudioCapture> create_audio_capture() {
    return std::make_unique<WasapiAudioCapture>();
}

}  // namespace immersive
