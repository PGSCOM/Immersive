#pragma once

/// Input injection module.
/// Receives input events from VR clients and injects them into the Windows input system.

#include <cstdint>
#include <memory>

#include "protocol.h"

namespace immersive {

/// Interface for injecting input events into the host OS
class IInputInjector {
public:
    virtual ~IInputInjector() = default;

    /// Initialize the input injector
    virtual bool initialize() = 0;

    /// Inject a mouse event
    virtual void inject_mouse(const protocol::InputMouse& input) = 0;

    /// Inject a keyboard event
    virtual void inject_keyboard(const protocol::InputKeyboard& input) = 0;

    /// Move the cursor to absolute screen coordinates for a specific monitor
    virtual void move_cursor(uint8_t monitor_id, uint16_t x, uint16_t y) = 0;
};

/// Create a Windows input injector (uses SendInput API)
std::unique_ptr<IInputInjector> create_input_injector();

}  // namespace immersive
