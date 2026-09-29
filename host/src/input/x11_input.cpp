/// X11 input injection through the XTEST extension.

#include "capture/linux_backends.h"
#include "input/vk_keysym.h"

#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>

#include <algorithm>
#include <iostream>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

namespace immersive {

namespace {

class X11InputInjector : public IInputInjector {
public:
    explicit X11InputInjector(Display* dpy) : dpy_(dpy) {}
    ~X11InputInjector() override { XCloseDisplay(dpy_); }

    bool initialize() override { return true; }

    void set_displays(const std::vector<DisplayInfo>& displays) override {
        std::lock_guard<std::mutex> lock(mutex_);
        monitors_.clear();
        for (const auto& d : displays) monitors_[d.id] = d;
    }

    void inject_mouse(const protocol::InputMouse& in) override {
        std::lock_guard<std::mutex> lock(mutex_);
        move_locked(in.monitor_id, in.x, in.y);

        // Wheel: X11 has no deltas, only clicks of buttons 4/5 (vertical)
        // and 6/7 (horizontal). The client streams fractions of a 120-unit
        // notch from the thumbstick, so carry the remainder.
        scroll_v_ += in.scroll_delta;
        scroll_h_ += in.scroll_delta_h;
        for (; scroll_v_ >= 120; scroll_v_ -= 120) click(4);   // up
        for (; scroll_v_ <= -120; scroll_v_ += 120) click(5);  // down
        for (; scroll_h_ >= 120; scroll_h_ -= 120) click(7);   // right
        for (; scroll_h_ <= -120; scroll_h_ += 120) click(6);  // left

        // Protocol bit0/1/2 = left/right/middle; X buttons 1/3/2.
        static constexpr unsigned kXButton[3] = {1, 3, 2};
        const uint8_t changed = in.buttons ^ buttons_;
        for (int b = 0; b < 3; ++b) {
            if (changed & (1u << b)) {
                XTestFakeButtonEvent(dpy_, kXButton[b], (in.buttons >> b) & 1, CurrentTime);
            }
        }
        buttons_ = in.buttons;
        XFlush(dpy_);
    }

    void inject_keyboard(const protocol::InputKeyboard& in) override {
        std::lock_guard<std::mutex> lock(mutex_);
        const uint32_t sym = vk_to_keysym(in.scancode);
        const KeyCode code = sym ? XKeysymToKeycode(dpy_, sym) : 0;
        if (code == 0) {
            if (unmapped_.insert(in.scancode).second) {
                std::cerr << "[X11Input] No key for VK 0x" << std::hex << in.scancode
                          << std::dec << " in this keymap, ignored\n";
            }
            return;
        }
        XTestFakeKeyEvent(dpy_, code, in.pressed ? True : False, CurrentTime);
        XFlush(dpy_);
    }

    void move_cursor(uint8_t monitor_id, uint16_t x, uint16_t y) override {
        std::lock_guard<std::mutex> lock(mutex_);
        move_locked(monitor_id, x, y);
        XFlush(dpy_);
    }

private:
    void move_locked(uint8_t monitor_id, uint16_t x, uint16_t y) {
        int gx = x, gy = y;
        auto it = monitors_.find(monitor_id);
        if (it != monitors_.end()) {
            const auto& d = it->second;
            gx = d.origin_x + std::min<int>(x, d.width - 1);
            gy = d.origin_y + std::min<int>(y, d.height - 1);
        }
        // Screen -1 = the current screen; coordinates are root-relative.
        XTestFakeMotionEvent(dpy_, -1, gx, gy, CurrentTime);
    }

    void click(unsigned button) {
        XTestFakeButtonEvent(dpy_, button, True, CurrentTime);
        XTestFakeButtonEvent(dpy_, button, False, CurrentTime);
    }

    Display*    dpy_;
    std::mutex  mutex_;  // one connection, called from several network threads
    std::unordered_map<uint8_t, DisplayInfo> monitors_;
    std::unordered_set<uint16_t> unmapped_;
    uint8_t     buttons_  = 0;
    int         scroll_v_ = 0;
    int         scroll_h_ = 0;
};

}  // namespace

std::unique_ptr<IInputInjector> create_x11_input_injector() {
    init_xlib_once();
    Display* dpy = XOpenDisplay(nullptr);
    if (!dpy) return nullptr;
    int ev = 0, err = 0, major = 0, minor = 0;
    if (!XTestQueryExtension(dpy, &ev, &err, &major, &minor)) {
        std::cerr << "[X11Input] The X server has no XTEST extension\n";
        XCloseDisplay(dpy);
        return nullptr;
    }
    std::cout << "[X11Input] Using XTEST " << major << "." << minor << "\n";
    return std::make_unique<X11InputInjector>(dpy);
}

}  // namespace immersive
