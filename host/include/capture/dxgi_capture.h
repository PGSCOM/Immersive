#pragma once

/// DXGI Desktop Duplication capture interface.
/// Captures the contents of a monitor using the Windows Desktop Duplication API.

#include <cstdint>
#include <string>
#include <vector>
#include <memory>

namespace immersive {

/// Information about a physical or virtual display
struct DisplayInfo {
    uint8_t     id;
    uint16_t    width;
    uint16_t    height;
    uint8_t     refresh_rate;
    int32_t     origin_x;
    int32_t     origin_y;
    std::string name;
    bool        is_primary;
};

/// A captured frame from a display
struct CapturedFrame {
    uint8_t              monitor_id;
    uint32_t             width;
    uint32_t             height;
    uint32_t             pitch;         // row stride in bytes
    std::vector<uint8_t> pixels;        // BGRA pixel data
    uint64_t             timestamp_us;  // capture timestamp in microseconds
};

/// Interface for screen capture backends
class IScreenCapture {
public:
    virtual ~IScreenCapture() = default;

    /// Enumerate available displays
    virtual std::vector<DisplayInfo> enumerate_displays() = 0;

    /// Start capturing a specific display
    virtual bool start_capture(uint8_t display_id) = 0;

    /// Stop capture
    virtual void stop_capture() = 0;

    /// Acquire the next frame (blocks until available or timeout)
    /// Returns nullptr if no frame is available within timeout_ms
    virtual std::unique_ptr<CapturedFrame> acquire_frame(uint32_t timeout_ms = 100) = 0;

    /// Check if capture is currently active
    virtual bool is_capturing() const = 0;
};

/// Create a DXGI Desktop Duplication capture instance
std::unique_ptr<IScreenCapture> create_dxgi_capture();

}  // namespace immersive
