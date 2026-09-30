#pragma once

/// Process-wide xdg-desktop-portal session shared by the Wayland capture
/// (ScreenCast + PipeWire, pipewire_capture.cpp) and input (RemoteDesktop,
/// portal_input.cpp) backends. All functions are thread-safe and bounded.

#include <cstdint>
#include <vector>

namespace immersive::portal {

struct Stream {
    uint32_t node_id;
    int32_t  x = 0, y = 0;           // position, compositor (logical) space
    int32_t  width = 0, height = 0;  // size, compositor (logical) space; 0 = unknown
};

struct Snapshot {
    uint64_t generation = 0;      // changes with every new session; 0 = none
    bool     remote_desktop = false;  // pointer/keyboard granted
    std::vector<Stream> streams;  // one per shared monitor, portal order
};

/// The live session, or a new one if there is none: that can show the portal
/// dialog and wait minutes for the user (silent with a stored restore token).
/// Retries after a failure are throttled; returns generation 0 on failure.
Snapshot ensure_session();

/// Generation of the live session, 0 if it closed. Lock-free.
uint64_t live_generation();

/// A fresh PipeWire remote fd for session `gen` (caller owns it), or -1.
int open_pipewire_remote(uint64_t gen);

/// Closes session `gen` if it is still current, so the next
/// ensure_session() starts over (used when its streams keep failing).
void invalidate(uint64_t gen);

/// Called by the capture once the buffer size of a node is known: pointer
/// coordinates are sent in that space (see portal_input.cpp).
void set_frame_size(uint32_t node_id, uint32_t w, uint32_t h);

// RemoteDesktop input: fire-and-forget, dropped when there is no session
// with input or the connection is busy (e.g. while the dialog is open).
// `fx`/`fy` are the position within stream `index` as a 0..1 fraction.
void pointer_motion(uint8_t index, double fx, double fy);
bool pointer_button(int32_t evdev_button, bool pressed);  ///< false: not sent
void pointer_axis_discrete(uint32_t axis, int32_t steps);
void keyboard_keysym(int32_t keysym, bool pressed);

}  // namespace immersive::portal
