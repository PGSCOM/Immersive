/// Picks the Linux capture/input/audio backend for the running session.
///
/// A Wayland session goes through xdg-desktop-portal: X11 capture there only
/// sees XWayland windows (the rest is black), so it is never used as a silent
/// fallback. Anything else with DISPLAY set uses X11.

#include "capture/linux_backends.h"
#include "encoder/encoder.h"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>

namespace immersive {

namespace {
bool is_wayland_session() {
    const char* type = std::getenv("XDG_SESSION_TYPE");
    if (type && std::strcmp(type, "wayland") == 0) return true;
    if (type && std::strcmp(type, "x11") == 0) return false;
    return std::getenv("WAYLAND_DISPLAY") != nullptr;
}

/// No-op injector for when no input backend is usable: streaming still works.
class NullInputInjector : public IInputInjector {
public:
    bool initialize() override { return true; }
    void set_displays(const std::vector<DisplayInfo>&) override {}
    void inject_mouse(const protocol::InputMouse&) override {}
    void inject_keyboard(const protocol::InputKeyboard&) override {}
    void move_cursor(uint8_t, uint16_t, uint16_t) override {}
};
}  // namespace

std::unique_ptr<IScreenCapture> create_screen_capture() {
    // Called once per stream (re)start: say which backend only the first time.
    static std::once_flag logged;
    if (is_wayland_session()) {
#ifdef IMMERSIVE_HAVE_PORTAL
        std::call_once(logged, [] {
            std::cout << "[Capture] Wayland session: using the xdg-desktop-portal\n";
        });
        return create_portal_capture();
#else
        std::cerr << "[Capture] Wayland session, but this host was built without\n"
                  << "          libdbus-1/libpipewire-0.3 (see host/CMakeLists.txt)\n";
        return nullptr;
#endif
    }
#ifdef IMMERSIVE_HAVE_X11
    if (std::getenv("DISPLAY")) {
        std::call_once(logged, [] { std::cout << "[Capture] X11 session: using XShm capture\n"; });
        return create_x11_capture();
    }
    std::cerr << "[Capture] No graphical session (DISPLAY/WAYLAND_DISPLAY unset)\n";
#else
    std::cerr << "[Capture] This host was built without X11 libraries\n";
#endif
    return nullptr;
}

std::unique_ptr<IInputInjector> create_input_injector() {
    std::unique_ptr<IInputInjector> injector;
    if (is_wayland_session()) {
#ifdef IMMERSIVE_HAVE_PORTAL
        injector = create_portal_input_injector();
#endif
    } else {
#ifdef IMMERSIVE_HAVE_X11
        injector = create_x11_input_injector();
#endif
    }
    if (!injector) {
        std::cerr << "[Input] No input backend available: VR input is ignored\n";
        injector = std::make_unique<NullInputInjector>();
    }
    return injector;
}

#ifndef IMMERSIVE_HAVE_FFMPEG
// Built without FFmpeg: no H.264/HEVC/AV1, main.cpp falls back to MJPEG.
std::unique_ptr<IVideoEncoder> create_hw_encoder() { return nullptr; }
bool hw_encoder_available(VideoCodec) { return false; }
#endif

std::unique_ptr<IAudioCapture> create_audio_capture() {
#ifdef IMMERSIVE_HAVE_PULSE
    return create_pulse_audio_capture();
#else
    std::cerr << "[Audio] Built without libpulse: no audio\n";
    return nullptr;
#endif
}

}  // namespace immersive
