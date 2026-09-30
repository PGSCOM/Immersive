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
    /// Backend handle for the display: CGDirectDisplayID on macOS, the
    /// PipeWire node id on Wayland, the RandR monitor index on X11. Unused
    /// on Windows.
    uint32_t    native_id = 0;
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

    /// Hint, set before start_capture(): the stream is encoded at this size.
    /// Backends that can scale for free (ScreenCaptureKit on the GPU) deliver
    /// frames at it; the others ignore it and deliver native size.
    virtual void set_output_size(uint32_t /*width*/, uint32_t /*height*/) {}
};

/// Create a DXGI Desktop Duplication capture instance (exclusive, may fail
/// with E_ACCESSDENIED if another process holds the Desktop Duplication handle).
std::unique_ptr<IScreenCapture> create_dxgi_capture();

/// Create a Windows Graphics Capture instance (Win10 1803+, non-exclusive —
/// works alongside screen-sharing and remote-desktop tools).
/// Returns a WgcCapture; call start_capture() which falls back to
/// create_dxgi_capture() at runtime if WGC is not supported.
std::unique_ptr<IScreenCapture> create_wgc_capture();

/// Create the native capture backend for this OS: WGC (with DXGI fallback)
/// on Windows, ScreenCaptureKit on macOS, the xdg-desktop-portal ScreenCast
/// + PipeWire on a Wayland session or XShm on X11 on Linux. May return
/// nullptr when no backend is usable (e.g. Linux with no display server).
std::unique_ptr<IScreenCapture> create_screen_capture();

/// Three fake solid-grey displays, for protocol tests (`--stub`).
std::unique_ptr<IScreenCapture> create_stub_capture();

}  // namespace immersive
