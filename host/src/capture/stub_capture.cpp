/// Fake capture + input backends selected with `--stub`.
///
/// Three displays of different resolutions, each a solid grey of its own
/// shade, and an input injector that only logs. Used by
/// host/tools/smoke_client.py and host/tools/e2e_test.py to exercise the
/// protocol, multi-monitor and reconnect paths without touching the real
/// desktop, and by CI on machines with no display server.

#include "capture/dxgi_capture.h"
#include "input/input_injector.h"

#include <algorithm>
#include <chrono>
#include <iostream>
#include <string>
#include <thread>

namespace immersive {

namespace {
struct StubDisplay { uint16_t width; uint16_t height; int32_t origin_x; };
constexpr StubDisplay kStubDisplays[] = {
    {1920, 1080,    0},
    {1920, 1200, 1920},
    {1280,  720, 3840},
};
constexpr uint8_t kStubDisplayCount =
    static_cast<uint8_t>(sizeof(kStubDisplays) / sizeof(kStubDisplays[0]));

class StubCapture : public IScreenCapture {
public:
    std::vector<DisplayInfo> enumerate_displays() override {
        std::vector<DisplayInfo> displays;
        for (uint8_t i = 0; i < kStubDisplayCount; ++i) {
            const auto& m = kStubDisplays[i];
            DisplayInfo d;
            d.id           = i;
            d.width        = m.width;
            d.height       = m.height;
            d.refresh_rate = 60;
            d.origin_x     = m.origin_x;
            d.origin_y     = 0;
            d.name         = std::string("Stub Display ") + char('0' + i);
            d.is_primary   = (i == 0);
            displays.push_back(d);
        }
        return displays;
    }

    bool start_capture(uint8_t display_id) override {
        display_ = (display_id < kStubDisplayCount) ? display_id : 0;
        capturing_ = true;
        delivered_ = false;
        std::cout << "[StubCapture] Started capture on display " << (int)display_id << "\n";
        return true;
    }

    void stop_capture() override { capturing_ = false; }

    std::unique_ptr<CapturedFrame> acquire_frame(uint32_t timeout_ms) override {
        if (!capturing_) return nullptr;
        // Like the real event-driven backends (WGC, ScreenCaptureKit,
        // PipeWire) on a static desktop: one frame, then nothing until the
        // content changes — which for a solid fill is never. This keeps the
        // tests on main.cpp's idle path (resend on keyframe request, 1 s
        // refresh). Sleep out the timeout: returning at once would spin.
        if (delivered_) {
            std::this_thread::sleep_for(std::chrono::milliseconds(std::max(1u, timeout_ms)));
            return nullptr;
        }
        delivered_ = true;

        auto frame = std::make_unique<CapturedFrame>();
        frame->monitor_id = display_;
        frame->width  = kStubDisplays[display_].width;
        frame->height = kStubDisplays[display_].height;
        frame->pitch  = frame->width * 4;
        // A distinct shade per display, so a decoded test frame identifies
        // which monitor it came from (e2e_test.py checks 64 + 48*i).
        frame->pixels.resize(static_cast<size_t>(frame->pitch) * frame->height,
                             static_cast<uint8_t>(64 + display_ * 48));
        frame->timestamp_us = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
        return frame;
    }

    bool is_capturing() const override { return capturing_; }

private:
    bool    capturing_ = false;
    bool    delivered_ = false;
    uint8_t display_   = 0;
};

class StubInputInjector : public IInputInjector {
public:
    bool initialize() override { return true; }
    void set_displays(const std::vector<DisplayInfo>&) override {}

    void inject_mouse(const protocol::InputMouse& in) override {
        std::cout << "[StubInput] Mouse: monitor=" << (int)in.monitor_id
                  << " x=" << in.x << " y=" << in.y
                  << " buttons=" << (int)in.buttons << "\n";
    }

    void inject_keyboard(const protocol::InputKeyboard& in) override {
        std::cout << "[StubInput] Key: vk=" << in.scancode
                  << " pressed=" << (int)in.pressed << "\n";
    }

    void move_cursor(uint8_t monitor_id, uint16_t x, uint16_t y) override {
        std::cout << "[StubInput] MoveCursor: monitor=" << (int)monitor_id
                  << " x=" << x << " y=" << y << "\n";
    }
};
}  // namespace

std::unique_ptr<IScreenCapture> create_stub_capture() {
    return std::make_unique<StubCapture>();
}

std::unique_ptr<IInputInjector> create_stub_input_injector() {
    return std::make_unique<StubInputInjector>();
}

}  // namespace immersive
