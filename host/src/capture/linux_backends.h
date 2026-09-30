#pragma once

/// Linux backend factories, picked by linux_backends.cpp. Each one is only
/// compiled when CMake found its libraries (IMMERSIVE_HAVE_*).

#include "capture/dxgi_capture.h"
#include "driver/idd_manager.h"
#include "input/input_injector.h"
#include "audio/audio_capture.h"

namespace immersive {

// X11: XShm capture, XTest input. nullptr when no X server is reachable.
std::unique_ptr<IScreenCapture> create_x11_capture();
std::unique_ptr<IInputInjector> create_x11_input_injector();
/// XInitThreads + a non-fatal X error handler; call before any Xlib use.
void init_xlib_once();
/// RandR 1.5 virtual monitors (the base "unsupported" manager without 1.5).
std::unique_ptr<IVirtualDisplayManager> create_x11_virtual_display_manager();

// Wayland: xdg-desktop-portal ScreenCast (+ RemoteDesktop for input) with
// PipeWire streams. nullptr when the portal session cannot be set up.
std::unique_ptr<IScreenCapture> create_portal_capture();
std::unique_ptr<IInputInjector> create_portal_input_injector();
/// A capture already streaming PipeWire `node` from the default daemon at a
/// fixed size (the consumer of a GNOME virtual screen); nullptr on failure.
std::unique_ptr<IScreenCapture> create_pipewire_node_capture(uint32_t node, uint32_t width,
                                                             uint32_t height);
/// GNOME virtual screens through Mutter's own D-Bus API (mutter_virtual.cpp);
/// the base "unsupported" manager on other compositors.
std::unique_ptr<IVirtualDisplayManager> create_mutter_virtual_display_manager();

// PulseAudio / pipewire-pulse monitor of the default sink.
std::unique_ptr<IAudioCapture> create_pulse_audio_capture();

}  // namespace immersive
