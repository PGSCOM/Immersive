#pragma once

/// GNOME virtual screens through Mutter's own D-Bus API
/// (org.gnome.Mutter.ScreenCast RecordVirtual, linked to an
/// org.gnome.Mutter.RemoteDesktop session for pointer input). The portal has
/// no way to add a monitor; this is what gnome-remote-desktop uses. Each
/// screen keeps a PipeWire consumer for its whole life: Mutter keeps the
/// monitor only while someone is streaming it. Thread-safe.

#include "capture/dxgi_capture.h"

#include <cstdint>
#include <memory>
#include <vector>

namespace immersive::mutter {

/// The virtual screens that exist now, ids 100+.
std::vector<DisplayInfo> displays();

bool exists(uint8_t id);

/// Newest frame of screen `id` (waits up to timeout_ms), or nullptr.
std::unique_ptr<CapturedFrame> acquire(uint8_t id, uint32_t timeout_ms);

/// True when at least one screen (hence a remote-desktop session) exists.
bool has_sessions();

// Input through the screens' RemoteDesktop sessions. The pointer position is
// in screen `id`'s pixels; buttons, wheel and keys are seat-wide.
void pointer_motion(uint8_t id, double x, double y);
bool pointer_button(int32_t evdev_button, bool pressed);
void pointer_axis_discrete(uint32_t axis, int32_t steps);
void keyboard_keysym(int32_t keysym, bool pressed);

}  // namespace immersive::mutter
