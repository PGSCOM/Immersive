/// Wayland input through the xdg-desktop-portal RemoteDesktop session that
/// the capture opened (portal_session.cpp). Every call is fire-and-forget.
/// The pointer on a GNOME virtual screen (id 100+) goes through that
/// screen's own Mutter RemoteDesktop session instead (mutter_virtual.cpp),
/// and so do buttons, wheel and keys when there is no portal session.

#include "capture/linux_backends.h"
#include "capture/mutter_virtual.h"
#include "capture/portal_session.h"
#include "input/vk_keysym.h"
#include "protocol.h"

#include <iostream>
#include <map>
#include <mutex>

namespace immersive {

namespace {

// evdev codes (linux/input-event-codes.h)
constexpr int32_t kBtnLeft = 0x110, kBtnRight = 0x111, kBtnMiddle = 0x112;

class PortalInputInjector final : public IInputInjector {
public:
    bool initialize() override { return true; }

    void set_displays(const std::vector<DisplayInfo>& displays) override {
        std::lock_guard<std::mutex> lock(mutex_);
        sizes_.clear();
        for (const auto& d : displays) sizes_[d.id] = {d.width, d.height};
    }

    void inject_mouse(const protocol::InputMouse& in) override {
        move_cursor(in.monitor_id, in.x, in.y);

        std::lock_guard<std::mutex> lock(mutex_);
        static constexpr std::pair<uint8_t, int32_t> kButtons[] = {
            {0x01, kBtnLeft}, {0x02, kBtnRight}, {0x04, kBtnMiddle}};
        // Only record a change that was actually sent: a release dropped on
        // a busy session is then retried by the next event instead of
        // leaving the button held forever.
        for (const auto& [bit, code] : kButtons) {
            if (((in.buttons ^ buttons_) & bit) && button(code, in.buttons & bit))
                buttons_ ^= bit;
        }

        // Windows wheel units (120 = one notch, +vertical = up, +horizontal =
        // right), sent in fractions from a thumbstick. The portal takes
        // whole steps with +vertical = down (libinput convention).
        scroll_v_ += in.scroll_delta;
        scroll_h_ += in.scroll_delta_h;
        if (const int notches = scroll_v_ / 120) {
            scroll_v_ -= notches * 120;
            axis(0, -notches);
        }
        if (const int notches = scroll_h_ / 120) {
            scroll_h_ -= notches * 120;
            axis(1, notches);
        }
    }

    void inject_keyboard(const protocol::InputKeyboard& in) override {
        const uint32_t keysym = vk_to_keysym(in.scancode);
        if (!keysym) return;
        if (portal::live_generation() || !mutter::has_sessions())
            portal::keyboard_keysym(static_cast<int32_t>(keysym), in.pressed != 0);
        else
            mutter::keyboard_keysym(static_cast<int32_t>(keysym), in.pressed != 0);
    }

    void move_cursor(uint8_t monitor_id, uint16_t x, uint16_t y) override {
        double w, h;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = sizes_.find(monitor_id);
            if (it == sizes_.end() || it->second.first == 0 || it->second.second == 0) return;
            w = it->second.first;
            h = it->second.second;
        }
        if (monitor_id >= protocol::VIRTUAL_MONITOR_ID_BASE)
            mutter::pointer_motion(monitor_id, x, y);  // its own pixels = its logical size
        else
            portal::pointer_motion(monitor_id, x / w, y / h);
    }

private:
    static bool button(int32_t code, bool pressed) {
        return portal::pointer_button(code, pressed) || mutter::pointer_button(code, pressed);
    }

    static void axis(uint32_t a, int32_t steps) {
        if (portal::live_generation() || !mutter::has_sessions())
            portal::pointer_axis_discrete(a, steps);
        else
            mutter::pointer_axis_discrete(a, steps);
    }

    std::mutex mutex_;
    std::map<uint8_t, std::pair<uint16_t, uint16_t>> sizes_;  // DisplayInfo size per id
    uint8_t buttons_ = 0;
    int scroll_v_ = 0, scroll_h_ = 0;
};

}  // namespace

std::unique_ptr<IInputInjector> create_portal_input_injector() {
    // Called after enumerate_displays(), so this returns the live session.
    // Without portal input it is still needed for GNOME virtual screens.
    if (!portal::ensure_session().remote_desktop)
        std::cerr << "[Input] No portal input: only GNOME virtual screens take VR input\n";
    return std::make_unique<PortalInputInjector>();
}

}  // namespace immersive
