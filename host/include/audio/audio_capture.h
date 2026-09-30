#pragma once

/// Audio capture interface for Immersive-2 host.
///
/// Captures system audio (loopback): WASAPI on Windows, ScreenCaptureKit on
/// macOS, PulseAudio/PipeWire on Linux.
/// Output format: PCM 16-bit, 48 kHz, stereo, interleaved.

#include <cstdint>
#include <memory>
#include <vector>

namespace immersive {

/// A captured audio frame — a batch of interleaved PCM-16 samples.
struct AudioFrame {
    std::vector<int16_t> samples;   ///< Interleaved L/R samples
    uint32_t             sample_rate = 48000;
    uint8_t              channels    = 2;
    uint32_t             seq         = 0;  ///< Sequence number
};

/// Interface for audio capture implementations.
class IAudioCapture {
public:
    virtual ~IAudioCapture() = default;

    /// Start capturing system audio.
    virtual bool start() = 0;

    /// Stop capturing.
    virtual void stop() = 0;

    /// Retrieve the next available audio frame.
    /// Returns nullptr if no data is available yet.
    virtual std::unique_ptr<AudioFrame> get_frame() = 0;

    /// Whether capture is currently active.
    virtual bool is_capturing() const = 0;
};

/// Create the system-audio loopback capture for this OS: WASAPI on Windows,
/// ScreenCaptureKit on macOS, the PulseAudio/PipeWire default monitor
/// source on Linux. May return nullptr when the host has no audio backend.
std::unique_ptr<IAudioCapture> create_audio_capture();

}  // namespace immersive
