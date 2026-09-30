/// Wayland input through the xdg-desktop-portal RemoteDesktop session that
/// the capture opened (portal_session.cpp). Every call is fire-and-forget.

#include "capture/linux_backends.h"
#include "capture/portal_session.h"
#include "input/vk_keysym.h"

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
        for (const auto& [bit, code] : kButtons) {
            if ((in.buttons ^ buttons_) & bit) portal::pointer_button(code, in.buttons & bit);
        }
        buttons_ = in.buttons;

        // Windows wheel units (120 = one notch, +vertical = up, +horizontal =
        // right), sent in fractions from a thumbstick. The portal takes
        // whole steps with +vertical = down (libinput convention).
        scroll_v_ += in.scroll_delta;
        scroll_h_ += in.scroll_delta_h;
        if (const int notches = scroll_v_ / 120) {
            scroll_v_ -= notches * 120;
            portal::pointer_axis_discrete(0, -notches);
        }
        if (const int notches = scroll_h_ / 120) {
            scroll_h_ -= notches * 120;
            portal::pointer_axis_discrete(1, notches);
        }
    }

    void inject_keyboard(const protocol::InputKeyboard& in) override {
        if (const uint32_t keysym = vk_to_keysym(in.scancode))
            portal::keyboard_keysym(static_cast<int32_t>(keysym), in.pressed != 0);
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
        portal::pointer_motion(monitor_id, x / w, y / h);
    }

private:
    std::mutex mutex_;
    std::map<uint8_t, std::pair<uint16_t, uint16_t>> sizes_;  // DisplayInfo size per id
    uint8_t buttons_ = 0;
    int scroll_v_ = 0, scroll_h_ = 0;
};

}  // namespace

std::unique_ptr<IInputInjector> create_portal_input_injector() {
    // Called after enumerate_displays(), so this returns the live session.
    if (!portal::ensure_session().remote_desktop) return nullptr;
    return std::make_unique<PortalInputInjector>();
}

}  // namespace immersive
