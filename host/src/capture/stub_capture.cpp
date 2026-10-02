/// Fake capture + input + virtual-display backends selected with `--stub`.
///
/// Three displays of different resolutions, each a solid grey of its own
/// shade, an input injector that only logs, and virtual displays (ids 100+)
/// that are solid grey 208 at the size asked for. Used by
/// host/tools/smoke_client.py and host/tools/e2e_test.py to exercise the
/// protocol, multi-monitor and reconnect paths without touching the real
/// desktop, and by CI on machines with no display server.

#include "capture/dxgi_capture.h"
#include "driver/idd_manager.h"
#include "input/input_injector.h"
#include "protocol.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <iostream>
#include <map>
#include <mutex>
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
constexpr uint8_t kVirtualShade = 208;  // 64 + 48*3: "the fourth grey"

// Virtual displays made by the stub manager, by id; read by every capture.
std::mutex g_virtual_mutex;
std::map<uint8_t, StubDisplay> g_virtual;

bool find_display(uint8_t id, StubDisplay& out) {
    if (id < kStubDisplayCount) { out = kStubDisplays[id]; return true; }
    std::lock_guard<std::mutex> lock(g_virtual_mutex);
    auto it = g_virtual.find(id);
    if (it == g_virtual.end()) return false;
    out = it->second;
    return true;
}

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
        std::lock_guard<std::mutex> lock(g_virtual_mutex);
        for (const auto& [id, m] : g_virtual) {
            DisplayInfo d;
            d.id = id;
            d.width = m.width;
            d.height = m.height;
            d.refresh_rate = 60;
            d.origin_x = m.origin_x;
            d.origin_y = 0;
            d.name = "Stub Virtual " + std::to_string(id - protocol::VIRTUAL_MONITOR_ID_BASE + 1);
            d.is_primary = false;
            displays.push_back(d);
        }
        return displays;
    }

    bool start_capture(uint8_t display_id) override {
        if (!find_display(display_id, geometry_)) {
            std::cerr << "[StubCapture] Display " << (int)display_id << " not found\n";
            return false;
        }
        display_ = display_id;
        capturing_ = true;
        delivered_ = false;
        std::cout << "[StubCapture] Started capture on display " << (int)display_id << "\n";
        return true;
    }

    void stop_capture() override { capturing_ = false; }

    std::unique_ptr<CapturedFrame> acquire_frame(uint32_t timeout_ms) override {
        if (!capturing_) return nullptr;
        if (display_ >= kStubDisplayCount && !find_display(display_, geometry_)) {
            capturing_ = false;  // its virtual display was removed
            return nullptr;
        }
        // Displays 0 and 1 behave like the real event-driven backends (WGC,
        // ScreenCaptureKit, PipeWire) on a static desktop: one frame, then
        // nothing, which keeps main.cpp's idle path (resend on keyframe
        // request, 1 s refresh) under test. Display 2 animates, so inter-frame
        // codecs also get a continuous run of P-frames. Sleep out the timeout
        // (or ~30 fps) either way: returning at once would spin.
        const bool animated = (display_ == 2);
        if (delivered_) {
            std::this_thread::sleep_for(std::chrono::milliseconds(
                std::max(1u, animated ? std::min(timeout_ms, 33u) : timeout_ms)));
            if (!animated) return nullptr;
        }
        delivered_ = true;

        auto frame = std::make_unique<CapturedFrame>();
        frame->monitor_id = display_;
        frame->width  = geometry_.width;
        frame->height = geometry_.height;
        frame->pitch  = frame->width * 4;
        // A distinct shade per display, so a decoded test frame identifies
        // which monitor it came from (e2e_test.py checks 64 + 48*i, and
        // kVirtualShade for virtual displays).
        const uint8_t shade = display_ < kStubDisplayCount
            ? static_cast<uint8_t>(64 + display_ * 48) : kVirtualShade;
        frame->pixels.resize(static_cast<size_t>(frame->pitch) * frame->height, shade);
        if (animated) {
            // A white bar sweeping the left quarter: the centre and the
            // right half, where the tests sample, stay grey.
            const uint32_t x0 = (tick_++ * 8) % (frame->width / 4 - 16);
            for (uint32_t y = 0; y < frame->height; ++y) {
                std::memset(&frame->pixels[static_cast<size_t>(y) * frame->pitch + x0 * 4],
                            255, 16 * 4);
            }
        }
        frame->timestamp_us = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
        return frame;
    }

    bool is_capturing() const override { return capturing_; }

private:
    bool    capturing_ = false;
    bool    delivered_ = false;
    uint32_t tick_     = 0;
    uint8_t display_   = 0;
    StubDisplay geometry_{};
};

/// Makes and removes entries of g_virtual; always "succeeds".
class StubVirtualDisplayManager : public IVirtualDisplayManager {
public:
    bool can_create_displays() const override { return true; }

    uint8_t create_display(const VirtualDisplayConfig& config) override {
        std::lock_guard<std::mutex> lock(g_virtual_mutex);
        for (uint8_t n = 0; n < protocol::MAX_VIRTUAL_DISPLAYS; ++n) {
            const uint8_t id = protocol::VIRTUAL_MONITOR_ID_BASE + n;
            if (g_virtual.count(id)) continue;
            g_virtual[id] = {config.width, config.height, 5120 + 4096 * n};
            std::cout << "[StubVirtual] Created display " << (int)id << " ("
                      << config.width << "x" << config.height << ")\n";
            return id;
        }
        return 0;
    }

    bool remove_display(uint8_t id) override {
        std::lock_guard<std::mutex> lock(g_virtual_mutex);
        const bool removed = g_virtual.erase(id) > 0;
        if (removed) std::cout << "[StubVirtual] Removed display " << (int)id << "\n";
        return removed;
    }

    void remove_all_displays() override {
        std::lock_guard<std::mutex> lock(g_virtual_mutex);
        g_virtual.clear();
    }

    std::vector<uint8_t> get_active_displays() const override {
        std::lock_guard<std::mutex> lock(g_virtual_mutex);
        std::vector<uint8_t> ids;
        for (const auto& [id, m] : g_virtual) ids.push_back(id);
        return ids;
    }

    bool can_turn_off_primary() const override { return true; }

    bool set_primary_off(bool off) override {
        std::cout << "[StubVirtual] Main screen " << (off ? "off" : "on") << "\n";
        return true;
    }
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

std::unique_ptr<IVirtualDisplayManager> create_stub_virtual_display_manager() {
    return std::make_unique<StubVirtualDisplayManager>();
}

}  // namespace immersive
