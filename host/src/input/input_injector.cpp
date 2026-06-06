/// Input injector implementation.
///
/// Injects mouse and keyboard events into the Windows input system
/// using the SendInput API.

#include "input/input_injector.h"
#include <iostream>
#include <algorithm>
#include <limits>
#include <unordered_map>

#ifdef _WIN32
#include <windows.h>
#endif

namespace immersive {

class InputInjectorImpl : public IInputInjector {
public:
    bool initialize() override {
        initialized_ = true;
        std::cout << "[InputInjector] Initialized\n";
        return true;
    }

    void set_displays(const std::vector<DisplayInfo>& displays) override {
#ifdef _WIN32
        monitors_.clear();
        if (displays.empty()) {
            layout_set_ = false;
            update_virtual_bounds_from_system();
            return;
        }

        LONG min_x = std::numeric_limits<LONG>::max();
        LONG min_y = std::numeric_limits<LONG>::max();
        LONG max_x = std::numeric_limits<LONG>::min();
        LONG max_y = std::numeric_limits<LONG>::min();

        for (const auto& d : displays) {
            MonitorArea area;
            area.left   = d.origin_x;
            area.top    = d.origin_y;
            area.width  = d.width;
            area.height = d.height;
            monitors_[d.id] = area;

            min_x = std::min(min_x, static_cast<LONG>(d.origin_x));
            min_y = std::min(min_y, static_cast<LONG>(d.origin_y));
            max_x = std::max(max_x, static_cast<LONG>(d.origin_x + d.width));
            max_y = std::max(max_y, static_cast<LONG>(d.origin_y + d.height));
        }

        virtual_left_   = min_x;
        virtual_top_    = min_y;
        virtual_width_  = std::max<LONG>(1, max_x - min_x);
        virtual_height_ = std::max<LONG>(1, max_y - min_y);
        layout_set_     = true;
#else
        (void)displays;
#endif
    }

    void inject_mouse(const protocol::InputMouse& input) override {
        if (!initialized_) return;

#ifdef _WIN32
        // Move event
        POINT target = translate_to_virtual(input.monitor_id, input.x, input.y);

        INPUT move_input = {};
        move_input.type = INPUT_MOUSE;
        move_input.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE | MOUSEEVENTF_VIRTUALDESK;
        normalize_to_absolute(target, move_input.mi.dx, move_input.mi.dy);
        SendInput(1, &move_input, sizeof(INPUT));

        // Vertical scroll
        if (input.scroll_delta != 0) {
            INPUT scroll_input = {};
            scroll_input.type = INPUT_MOUSE;
            scroll_input.mi.dwFlags = MOUSEEVENTF_WHEEL;
            scroll_input.mi.mouseData = static_cast<DWORD>(input.scroll_delta);
            SendInput(1, &scroll_input, sizeof(INPUT));
        }

        // Horizontal scroll
        if (input.scroll_delta_h != 0) {
            INPUT scroll_input = {};
            scroll_input.type = INPUT_MOUSE;
            scroll_input.mi.dwFlags = MOUSEEVENTF_HWHEEL;
            scroll_input.mi.mouseData = static_cast<DWORD>(input.scroll_delta_h);
            SendInput(1, &scroll_input, sizeof(INPUT));
        }

        // Button transitions
        const uint8_t changed = input.buttons ^ prev_buttons_;
        if (changed & 0x01) {
            INPUT btn = {};
            btn.type = INPUT_MOUSE;
            btn.mi.dwFlags = (input.buttons & 0x01) ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
            SendInput(1, &btn, sizeof(INPUT));
        }
        if (changed & 0x02) {
            INPUT btn = {};
            btn.type = INPUT_MOUSE;
            btn.mi.dwFlags = (input.buttons & 0x02) ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
            SendInput(1, &btn, sizeof(INPUT));
        }
        if (changed & 0x04) {
            INPUT btn = {};
            btn.type = INPUT_MOUSE;
            btn.mi.dwFlags = (input.buttons & 0x04) ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
            SendInput(1, &btn, sizeof(INPUT));
        }
        prev_buttons_ = input.buttons;
#else
        // Non-Windows stub
        std::cout << "[InputInjector] Mouse: monitor=" << (int)input.monitor_id
                  << " x=" << input.x << " y=" << input.y
                  << " buttons=" << (int)input.buttons << "\n";
#endif
    }

    void inject_keyboard(const protocol::InputKeyboard& input) override {
        if (!initialized_) return;

#ifdef _WIN32
        INPUT win_input = {};
        win_input.type = INPUT_KEYBOARD;
        win_input.ki.wVk = static_cast<WORD>(input.scancode);
        win_input.ki.dwFlags = input.pressed ? 0 : KEYEVENTF_KEYUP;

        SendInput(1, &win_input, sizeof(INPUT));
#else
        std::cout << "[InputInjector] Key: scancode=" << input.scancode
                  << " pressed=" << (int)input.pressed
                  << " modifiers=" << (int)input.modifiers << "\n";
#endif
    }

    void move_cursor(uint8_t monitor_id, uint16_t x, uint16_t y) override {
        if (!initialized_) return;

#ifdef _WIN32
        POINT target = translate_to_virtual(monitor_id, x, y);
        SetCursorPos(target.x, target.y);
#else
        std::cout << "[InputInjector] MoveCursor: monitor=" << (int)monitor_id
                  << " x=" << x << " y=" << y << "\n";
#endif
    }

private:
#ifdef _WIN32
    struct MonitorArea {
        LONG left;
        LONG top;
        LONG width;
        LONG height;
    };

    POINT translate_to_virtual(uint8_t monitor_id, uint16_t x, uint16_t y) const {
        POINT p{};
        auto it = monitors_.find(monitor_id);
        if (it != monitors_.end()) {
            const auto& area = it->second;
            LONG clamped_x = std::min<LONG>(area.width - 1, static_cast<LONG>(x));
            LONG clamped_y = std::min<LONG>(area.height - 1, static_cast<LONG>(y));
            clamped_x = std::max<LONG>(0, clamped_x);
            clamped_y = std::max<LONG>(0, clamped_y);
            p.x = area.left + clamped_x;
            p.y = area.top + clamped_y;
            return p;
        }

        // Fallback: assume single display starting at (0,0)
        p.x = static_cast<LONG>(x);
        p.y = static_cast<LONG>(y);
        return p;
    }

    void update_virtual_bounds_from_system() {
        virtual_left_   = GetSystemMetrics(SM_XVIRTUALSCREEN);
        virtual_top_    = GetSystemMetrics(SM_YVIRTUALSCREEN);
        virtual_width_  = std::max<LONG>(1, GetSystemMetrics(SM_CXVIRTUALSCREEN));
        virtual_height_ = std::max<LONG>(1, GetSystemMetrics(SM_CYVIRTUALSCREEN));
    }

    void normalize_to_absolute(const POINT& pt, LONG& abs_x, LONG& abs_y) {
        if (!layout_set_) {
            update_virtual_bounds_from_system();
        }

        // Windows expects 0..65535 absolute coords across the virtual desktop
        LONG width_minus_one  = std::max<LONG>(1, virtual_width_ - 1);
        LONG height_minus_one = std::max<LONG>(1, virtual_height_ - 1);

        abs_x = static_cast<LONG>(
            ((pt.x - virtual_left_) * 65535LL) / width_minus_one);
        abs_y = static_cast<LONG>(
            ((pt.y - virtual_top_) * 65535LL) / height_minus_one);
    }

    uint8_t prev_buttons_ = 0;
    std::unordered_map<uint8_t, MonitorArea> monitors_;
    LONG virtual_left_   = 0;
    LONG virtual_top_    = 0;
    LONG virtual_width_  = 1;
    LONG virtual_height_ = 1;
    bool layout_set_     = false;
#endif
    bool initialized_ = false;
};

std::unique_ptr<IInputInjector> create_input_injector() {
    return std::make_unique<InputInjectorImpl>();
}

}  // namespace immersive
