/// System-audio capture on Linux: records the monitor of the default sink
/// through libpulse-simple. Works on PulseAudio and on PipeWire (via
/// pipewire-pulse). The server converts to the wire format (PCM-16 stereo
/// 48 kHz), so no resampling happens here.

#include "capture/linux_backends.h"

#include <pulse/error.h>
#include <pulse/simple.h>

#include <atomic>
#include <chrono>
#include <iostream>
#include <mutex>
#include <queue>
#include <thread>

namespace immersive {

namespace {

constexpr uint32_t kSampleRate    = 48000;
constexpr uint8_t  kChannels      = 2;
constexpr uint32_t kPacketFrames  = 480;  // 10 ms, same as the WASAPI path
constexpr size_t   kMaxQueued     = 32;

class PulseAudioCapture : public IAudioCapture {
public:
    ~PulseAudioCapture() override { stop(); }

    bool start() override {
        if (capturing_) return true;
        pa_simple* pa = open();
        if (!pa) return false;
        capturing_ = true;
        thread_ = std::thread([this, pa] { run(pa); });
        std::cout << "[AudioCapture] PulseAudio monitor capture started (48000 Hz, 2 ch)\n";
        return true;
    }

    void stop() override {
        if (!capturing_) return;
        capturing_ = false;
        // pa_simple_read returns within one 10 ms fragment.
        if (thread_.joinable()) thread_.join();
        std::cout << "[AudioCapture] Stopped\n";
    }

    std::unique_ptr<AudioFrame> get_frame() override {
        std::lock_guard<std::mutex> lock(mutex_);
        if (queue_.empty()) return nullptr;
        auto frame = std::move(queue_.front());
        queue_.pop();
        return frame;
    }

    bool is_capturing() const override { return capturing_; }

private:
    static pa_simple* open() {
        const pa_sample_spec spec = {PA_SAMPLE_S16LE, kSampleRate, kChannels};
        // Small fragments keep latency at ~10 ms instead of the default ~2 s.
        pa_buffer_attr attr;
        attr.maxlength = static_cast<uint32_t>(-1);
        attr.tlength   = static_cast<uint32_t>(-1);
        attr.prebuf    = static_cast<uint32_t>(-1);
        attr.minreq    = static_cast<uint32_t>(-1);
        attr.fragsize  = kPacketFrames * kChannels * sizeof(int16_t);
        int err = 0;
        pa_simple* pa = pa_simple_new(nullptr, "Immersive-2 Host", PA_STREAM_RECORD,
                                      "@DEFAULT_MONITOR@", "VR audio", &spec,
                                      nullptr, &attr, &err);
        if (!pa) {
            std::cerr << "[AudioCapture] PulseAudio unavailable: " << pa_strerror(err) << "\n";
        }
        return pa;
    }

    void run(pa_simple* pa) {
        uint32_t seq = 0;
        while (capturing_) {
            auto frame = std::make_unique<AudioFrame>();
            frame->samples.resize(kPacketFrames * kChannels);
            int err = 0;
            if (pa_simple_read(pa, frame->samples.data(),
                               frame->samples.size() * sizeof(int16_t), &err) < 0) {
                // Sound server restarted (common with PipeWire updates, or a
                // user switching output device): reconnect instead of going
                // silent until the host is restarted.
                std::cerr << "[AudioCapture] Read failed (" << pa_strerror(err)
                          << "), reconnecting\n";
                pa_simple_free(pa);
                pa = nullptr;
                while (capturing_ && !(pa = open())) {
                    for (int i = 0; i < 20 && capturing_; ++i)
                        std::this_thread::sleep_for(std::chrono::milliseconds(100));
                }
                if (!pa) return;
                continue;
            }
            frame->sample_rate = kSampleRate;
            frame->channels    = kChannels;
            frame->seq         = seq++;

            std::lock_guard<std::mutex> lock(mutex_);
            if (queue_.size() >= kMaxQueued) queue_.pop();  // drop oldest, keep latency bounded
            queue_.push(std::move(frame));
        }
        pa_simple_free(pa);
    }

    std::atomic<bool> capturing_{false};
    std::thread       thread_;
    std::mutex        mutex_;
    std::queue<std::unique_ptr<AudioFrame>> queue_;
};

}  // namespace

std::unique_ptr<IAudioCapture> create_pulse_audio_capture() {
    return std::make_unique<PulseAudioCapture>();
}

}  // namespace immersive
