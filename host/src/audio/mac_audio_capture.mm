/// macOS system-audio loopback through ScreenCaptureKit (macOS 13+).
///
/// An SCStream on the main display with capturesAudio set. SCK delivers
/// float32 planar buffers at the configured 48 kHz stereo; anything else
/// (int16/int32, interleaved, other rates or channel counts) is converted
/// too, to the fixed wire format: PCM-16 interleaved stereo 48 kHz in
/// 480-frame (10 ms) packets. If the system ends the stream (sleep, display
/// reconfiguration) get_frame() restarts it every few seconds.

#include "audio/audio_capture.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <deque>
#include <iostream>
#include <mutex>
#include <string>
#include <vector>

namespace {

using immersive::AudioFrame;

constexpr uint32_t kTargetRate     = 48000;
constexpr uint32_t kPacketFrames   = 480;  // 10 ms
constexpr size_t   kMaxQueuedFrames = 32;
constexpr int64_t  kTimeoutSec     = 5;
constexpr int64_t  kStopTimeoutSec = 2;
constexpr auto     kRestartInterval = std::chrono::seconds(3);

/// Converts any-rate, any-channel float samples to 48 kHz stereo int16 and
/// cuts them into AudioFrames. Linear interpolation, continuous across input
/// buffers (index -1 is the previous buffer's last frame).
struct PcmConverter {
    std::vector<int16_t> acc;
    double               pos = 0.0;
    float                prev[2] = {0.0f, 0.0f};
    uint32_t             seq = 0;

    /// `sample(frame, ch)` returns a float in [-1, 1] for ch < channels.
    template <class Sample>
    void push(Sample sample, size_t frames, uint32_t channels, double rate,
              std::deque<std::unique_ptr<AudioFrame>>& out) {
        if (frames == 0 || channels == 0 || rate <= 0) return;
        const double step = rate / kTargetRate;
        auto at = [&](long f, uint32_t ch) -> float {
            const uint32_t src = ch < channels ? ch : 0;  // mono -> both sides
            return f < 0 ? prev[ch] : sample(static_cast<size_t>(f), src);
        };
        const double last = static_cast<double>(frames) - 1.0;
        while (pos < last) {
            const long   i0 = static_cast<long>(std::floor(pos));
            const float  t  = static_cast<float>(pos - i0);
            for (uint32_t ch = 0; ch < 2; ++ch) {
                const float v = at(i0, ch) * (1.0f - t) + at(i0 + 1, ch) * t;
                acc.push_back(static_cast<int16_t>(
                    std::lrint(std::clamp(v * 32768.0f, -32768.0f, 32767.0f))));
            }
            pos += step;
        }
        pos -= static_cast<double>(frames);
        for (uint32_t ch = 0; ch < 2; ++ch) prev[ch] = at(static_cast<long>(frames) - 1, ch);

        const size_t packet = kPacketFrames * 2;
        size_t used = 0;
        for (; acc.size() - used >= packet; used += packet) {
            auto frame         = std::make_unique<AudioFrame>();
            frame->sample_rate = kTargetRate;
            frame->channels    = 2;
            frame->seq         = seq++;
            frame->samples.assign(acc.begin() + used, acc.begin() + used + packet);
            out.push_back(std::move(frame));
        }
        acc.erase(acc.begin(), acc.begin() + used);
    }
};

struct AudioState {
    std::mutex                              mutex;   // guards `frames`
    std::deque<std::unique_ptr<AudioFrame>> frames;
    PcmConverter                            converter;  // SCK queue only
    std::atomic<bool>                       stopped{false};
};

bool wait_signal(dispatch_semaphore_t sem, int64_t seconds) {
    return dispatch_semaphore_wait(
               sem, dispatch_time(DISPATCH_TIME_NOW,
                                  static_cast<int64_t>(seconds * NSEC_PER_SEC))) == 0;
}

std::string describe(NSError* error) {
    const char* text = error ? error.localizedDescription.UTF8String : nullptr;
    return text ? text : "timed out";
}

}  // namespace

@interface Im2AudioSink : NSObject <SCStreamOutput, SCStreamDelegate>
- (instancetype)initWithState:(std::shared_ptr<AudioState>)state;
@end

@implementation Im2AudioSink {
    std::shared_ptr<AudioState> _state;
}

- (instancetype)initWithState:(std::shared_ptr<AudioState>)state {
    if ((self = [super init])) _state = std::move(state);
    return self;
}

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sample
                   ofType:(SCStreamOutputType)type {
    @autoreleasepool {
        // Screen samples come from the dummy video output and are dropped.
        if (type != SCStreamOutputTypeAudio || !CMSampleBufferIsValid(sample)) return;

        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
        const AudioStreamBasicDescription* asbd =
            format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : nullptr;
        if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM || asbd->mChannelsPerFrame == 0) return;

        const bool     is_float = asbd->mFormatFlags & kAudioFormatFlagIsFloat;
        const bool     planar   = asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved;
        const uint32_t bits     = asbd->mBitsPerChannel;
        if (is_float ? bits != 32
                     : (!(asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) ||
                        (bits != 16 && bits != 32))) {
            return;
        }

        // Room for 16 planar channels without a heap allocation.
        alignas(AudioBufferList) uint8_t storage[sizeof(AudioBufferList) + 15 * sizeof(AudioBuffer)];
        auto* abl = reinterpret_cast<AudioBufferList*>(storage);
        CMBlockBufferRef block = nullptr;
        if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample, nullptr, abl, sizeof(storage), nullptr, nullptr,
                kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block) != noErr) {
            if (block) CFRelease(block);
            return;
        }

        const uint32_t bytes    = bits / 8;
        const uint32_t channels = planar ? std::min(asbd->mChannelsPerFrame, abl->mNumberBuffers)
                                         : asbd->mChannelsPerFrame;
        size_t frames = SIZE_MAX;
        for (uint32_t b = 0; b < (planar ? channels : std::min(1u, abl->mNumberBuffers)); ++b) {
            const size_t stride = static_cast<size_t>(bytes) * (planar ? 1 : channels);
            frames = std::min<size_t>(frames, abl->mBuffers[b].mDataByteSize / stride);
            if (!abl->mBuffers[b].mData) frames = 0;
        }
        if (frames == SIZE_MAX) frames = 0;

        auto sample_at = [&](size_t f, uint32_t ch) -> float {
            const AudioBuffer& buf = abl->mBuffers[planar ? ch : 0];
            const size_t idx = planar ? f : f * channels + ch;
            if (is_float) return static_cast<const float*>(buf.mData)[idx];
            if (bits == 16) return static_cast<const int16_t*>(buf.mData)[idx] / 32768.0f;
            return static_cast<float>(static_cast<const int32_t*>(buf.mData)[idx] / 2147483648.0);
        };

        std::deque<std::unique_ptr<AudioFrame>> ready;
        _state->converter.push(sample_at, frames, channels, asbd->mSampleRate, ready);
        CFRelease(block);

        if (ready.empty()) return;
        std::lock_guard<std::mutex> lock(_state->mutex);
        for (auto& f : ready) _state->frames.push_back(std::move(f));
        // Drop the oldest: after a stall, fresh audio beats a backlog of latency.
        while (_state->frames.size() > kMaxQueuedFrames) _state->frames.pop_front();
    }  // @autoreleasepool
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    std::cerr << "[MacAudio] Stream stopped: " << describe(error) << "\n";
    _state->stopped = true;
}
@end

namespace immersive {

class MacAudioCapture : public IAudioCapture {
public:
    ~MacAudioCapture() override { stop(); }

    bool start() override {
        std::lock_guard<std::mutex> lock(lifecycle_);
        if (stream_) return true;
        wanted_ = open();
        return wanted_;
    }

    void stop() override {
        std::lock_guard<std::mutex> lock(lifecycle_);
        const bool was_running = stream_ != nil;
        wanted_ = false;
        close();
        if (was_running) std::cout << "[MacAudio] Stopped\n";
    }

    std::unique_ptr<AudioFrame> get_frame() override {
        std::shared_ptr<AudioState> state;
        {
            std::lock_guard<std::mutex> lock(lifecycle_);
            const auto now = std::chrono::steady_clock::now();
            if (wanted_ && (!state_ || state_->stopped) && now - last_attempt_ >= kRestartInterval) {
                std::cerr << "[MacAudio] Restarting system audio capture\n";
                close();
                open();
            }
            state = state_;
        }
        if (!state) return nullptr;
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->frames.empty()) return nullptr;
        auto frame = std::move(state->frames.front());
        state->frames.pop_front();
        return frame;
    }

    bool is_capturing() const override {
        std::lock_guard<std::mutex> lock(lifecycle_);
        return state_ && !state_->stopped;
    }

private:
    /// Caller holds lifecycle_.
    bool open() {
        @autoreleasepool {
            last_attempt_ = std::chrono::steady_clock::now();
            CGMainDisplayID();  // ScreenCaptureKit needs the CoreGraphics connection up
            if (!CGPreflightScreenCaptureAccess()) {
                std::cerr << "[MacAudio] System audio needs the Screen Recording permission\n";
                return false;
            }

            __block SCShareableContent* content = nil;
            __block NSError* content_error = nil;
            dispatch_semaphore_t got = dispatch_semaphore_create(0);
            [SCShareableContent getShareableContentWithCompletionHandler:
                ^(SCShareableContent* c, NSError* e) {
                    content = c;
                    content_error = e;
                    dispatch_semaphore_signal(got);
                }];
            if (!wait_signal(got, kTimeoutSec) || !content) {
                std::cerr << "[MacAudio] Shareable content unavailable: "
                          << describe(content_error) << "\n";
                return false;
            }
            SCDisplay* display = content.displays.firstObject;
            for (SCDisplay* d in content.displays) {
                if (d.displayID == CGMainDisplayID()) { display = d; break; }
            }
            if (!display) {
                std::cerr << "[MacAudio] No display to attach the audio stream to\n";
                return false;
            }

            // SCK has no audio-only stream: a display is required, and without a
            // screen output it logs every dropped video frame. Keep that video
            // side tiny and slow.
            SCContentFilter* filter =
                [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
            SCStreamConfiguration* config = [[SCStreamConfiguration alloc] init];
            config.width                       = 64;
            config.height                      = 64;
            config.minimumFrameInterval        = CMTimeMake(1, 1);
            config.showsCursor                 = NO;
            config.capturesAudio               = YES;
            config.sampleRate                  = kTargetRate;
            config.channelCount                = 2;
            config.excludesCurrentProcessAudio = YES;

            auto state = std::make_shared<AudioState>();
            if (state_) state->converter.seq = state_->converter.seq;  // keep seq monotonic
            Im2AudioSink* sink = [[Im2AudioSink alloc] initWithState:state];
            dispatch_queue_t queue =
                dispatch_queue_create("immersive2.audio", DISPATCH_QUEUE_SERIAL);
            SCStream* stream = [[SCStream alloc] initWithFilter:filter
                                                  configuration:config
                                                       delegate:sink];

            NSError* add_error = nil;
            if (![stream addStreamOutput:sink type:SCStreamOutputTypeAudio
                      sampleHandlerQueue:queue error:&add_error] ||
                ![stream addStreamOutput:sink type:SCStreamOutputTypeScreen
                      sampleHandlerQueue:queue error:&add_error]) {
                std::cerr << "[MacAudio] addStreamOutput failed: " << describe(add_error) << "\n";
                return false;
            }

            stream_ = stream;
            sink_   = sink;
            state_  = state;

            __block NSError* start_error = nil;
            dispatch_semaphore_t started = dispatch_semaphore_create(0);
            [stream startCaptureWithCompletionHandler:^(NSError* e) {
                start_error = e;
                dispatch_semaphore_signal(started);
            }];
            if (!wait_signal(started, kTimeoutSec) || start_error) {
                std::cerr << "[MacAudio] Could not start audio capture: "
                          << describe(start_error) << "\n";
                close();  // marks state_ stopped; it keeps seq for the next attempt
                return false;
            }

            std::cout << "[MacAudio] ScreenCaptureKit system audio started (48000 Hz, 2 ch)\n";
        }  // @autoreleasepool
        return true;
    }

    /// Caller holds lifecycle_. Idempotent.
    void close() {
        if (!stream_) return;
        SCStream* stream = stream_;
        stream_ = nil;

        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        [stream stopCaptureWithCompletionHandler:^(NSError* ignored) {
            dispatch_semaphore_signal(stopped);
        }];
        if (!wait_signal(stopped, kStopTimeoutSec)) {
            std::cerr << "[MacAudio] stopCapture timed out\n";
        }
        [stream removeStreamOutput:sink_ type:SCStreamOutputTypeAudio error:nil];
        [stream removeStreamOutput:sink_ type:SCStreamOutputTypeScreen error:nil];
        sink_ = nil;
        if (state_) state_->stopped = true;
    }

    mutable std::mutex                    lifecycle_;
    SCStream*                             stream_ = nil;
    Im2AudioSink*                         sink_   = nil;
    std::shared_ptr<AudioState>           state_;
    bool                                  wanted_ = false;
    std::chrono::steady_clock::time_point last_attempt_;
};

std::unique_ptr<IAudioCapture> create_audio_capture() {
    return std::make_unique<MacAudioCapture>();
}

}  // namespace immersive
