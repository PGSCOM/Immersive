#pragma once

/// Linux backend factories, picked by linux_backends.cpp. Each one is only
/// compiled when CMake found its libraries (IMMERSIVE_HAVE_*).

#include "capture/dxgi_capture.h"
#include "input/input_injector.h"
#include "audio/audio_capture.h"

namespace immersive {

// X11: XShm capture, XTest input. nullptr when no X server is reachable.
std::unique_ptr<IScreenCapture> create_x11_capture();
std::unique_ptr<IInputInjector> create_x11_input_injector();
/// XInitThreads + a non-fatal X error handler; call before any Xlib use.
void init_xlib_once();

// Wayland: xdg-desktop-portal ScreenCast (+ RemoteDesktop for input) with
// PipeWire streams. nullptr when the portal session cannot be set up.
std::unique_ptr<IScreenCapture> create_portal_capture();
std::unique_ptr<IInputInjector> create_portal_input_injector();

// PulseAudio / pipewire-pulse monitor of the default sink.
std::unique_ptr<IAudioCapture> create_pulse_audio_capture();

}  // namespace immersive
