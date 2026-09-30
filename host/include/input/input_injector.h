#pragma once

/// Input injection module.
/// Receives input events from VR clients and injects them into the host OS.

#include <cstdint>
#include <memory>
#include <vector>

#include "protocol.h"
#include "capture/dxgi_capture.h"

namespace immersive {

/// Interface for injecting input events into the host OS
class IInputInjector {
public:
    virtual ~IInputInjector() = default;

    /// Initialize the input injector
    virtual bool initialize() = 0;

    /// Provide display layout for coordinate translation
    virtual void set_displays(const std::vector<DisplayInfo>& displays) = 0;

    /// Inject a mouse event
    virtual void inject_mouse(const protocol::InputMouse& input) = 0;

    /// Inject a keyboard event. `scancode` is a Windows virtual-key code
    /// (the client's keyboard sends VK_*); other platforms translate it.
    virtual void inject_keyboard(const protocol::InputKeyboard& input) = 0;

    /// Move the cursor to absolute screen coordinates for a specific monitor
    virtual void move_cursor(uint8_t monitor_id, uint16_t x, uint16_t y) = 0;
};

/// Create the native input injector for this OS: SendInput on Windows,
/// CGEvent on macOS, the RemoteDesktop portal on Wayland or XTest on X11.
/// Call after IScreenCapture::enumerate_displays(): on Wayland both share
/// one portal session. Never returns nullptr (falls back to a no-op).
std::unique_ptr<IInputInjector> create_input_injector();

/// Injector that only logs events, for protocol tests (`--stub`).
std::unique_ptr<IInputInjector> create_stub_input_injector();

}  // namespace immersive
