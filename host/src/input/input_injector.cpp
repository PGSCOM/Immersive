/// Input injector implementation.
///
/// Injects mouse and keyboard events into the Windows input system
/// using the SendInput API.

#include "input/input_injector.h"
#include <iostream>

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

    void inject_mouse(const protocol::InputMouse& input) override {
        if (!initialized_) return;

#ifdef _WIN32
        INPUT win_input = {};
        win_input.type = INPUT_MOUSE;
        win_input.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE;

        // Convert to absolute coordinates (0..65535)
        // This requires knowing the monitor dimensions; for now use primary
        win_input.mi.dx = static_cast<LONG>(input.x * 65535 / GetSystemMetrics(SM_CXSCREEN));
        win_input.mi.dy = static_cast<LONG>(input.y * 65535 / GetSystemMetrics(SM_CYSCREEN));

        // Handle button presses
        if (input.buttons & 0x01) win_input.mi.dwFlags |= MOUSEEVENTF_LEFTDOWN;
        if (input.buttons & 0x02) win_input.mi.dwFlags |= MOUSEEVENTF_RIGHTDOWN;
        if (input.buttons & 0x04) win_input.mi.dwFlags |= MOUSEEVENTF_MIDDLEDOWN;

        // Handle scroll
        if (input.scroll_delta != 0) {
            win_input.mi.dwFlags |= MOUSEEVENTF_WHEEL;
            win_input.mi.mouseData = static_cast<DWORD>(input.scroll_delta);
        }

        SendInput(1, &win_input, sizeof(INPUT));
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
        // TODO: Translate coordinates to the correct monitor's coordinate space
        SetCursorPos(static_cast<int>(x), static_cast<int>(y));
#else
        std::cout << "[InputInjector] MoveCursor: monitor=" << (int)monitor_id
                  << " x=" << x << " y=" << y << "\n";
#endif
    }

private:
    bool initialized_ = false;
};

std::unique_ptr<IInputInjector> create_input_injector() {
    return std::make_unique<InputInjectorImpl>();
}

}  // namespace immersive
