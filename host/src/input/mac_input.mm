/// macOS input injection through CGEvent.
///
/// Mouse coordinates arrive in the pixel space enumerate_displays() reported
/// and are mapped to global points (Retina) via CGDisplayBounds. Keys arrive
/// as Windows VK codes and are posted as US-ANSI positional kVK codes; the
/// modifier state is tracked here and stamped on every event, so Shift+A is
/// an 'A' no matter what the physical keyboard is doing.
/// CGEventPost silently drops everything unless the host process (or the
/// terminal running it) has the Accessibility permission.

#include "input/input_injector.h"

#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>
#include <iterator>
#include <mutex>
#include <unordered_map>

namespace immersive {

namespace {

// ponytail: positional US-ANSI mapping; on AZERTY/QWERTZ layouts letters land
// where the US key would be. Unicode injection is the upgrade if needed.
// Returns the kVK_* code (Carbon HIToolbox Events.h) or -1.
constexpr int vk_to_kvk(uint16_t vk) {
    constexpr uint8_t letters[26] = {  // A..Z
        0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
        0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06};
    constexpr uint8_t digits[10] = {  // 0..9
        0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19};
    constexpr uint8_t keypad[10] = {  // Keypad0..Keypad9
        0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C};
    constexpr uint8_t fkeys[20] = {  // F1..F20
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A};
    if (vk >= 0x41 && vk <= 0x5A) return letters[vk - 0x41];
    if (vk >= 0x30 && vk <= 0x39) return digits[vk - 0x30];
    if (vk >= 0x60 && vk <= 0x69) return keypad[vk - 0x60];
    if (vk >= 0x70 && vk <= 0x83) return fkeys[vk - 0x70];
    switch (vk) {
    case 0x08: return 0x33;  // VK_BACK      -> kVK_Delete
    case 0x09: return 0x30;  // VK_TAB       -> kVK_Tab
    case 0x0D: return 0x24;  // VK_RETURN    -> kVK_Return
    case 0x10: return 0x38;  // VK_SHIFT     -> kVK_Shift
    case 0x11: return 0x3B;  // VK_CONTROL   -> kVK_Control
    case 0x12: return 0x3A;  // VK_MENU      -> kVK_Option
    case 0x1B: return 0x35;  // VK_ESCAPE    -> kVK_Escape
    case 0x20: return 0x31;  // VK_SPACE     -> kVK_Space
    case 0x21: return 0x74;  // VK_PRIOR     -> kVK_PageUp
    case 0x22: return 0x79;  // VK_NEXT      -> kVK_PageDown
    case 0x23: return 0x77;  // VK_END       -> kVK_End
    case 0x24: return 0x73;  // VK_HOME      -> kVK_Home
    case 0x25: return 0x7B;  // VK_LEFT      -> kVK_LeftArrow
    case 0x26: return 0x7E;  // VK_UP        -> kVK_UpArrow
    case 0x27: return 0x7C;  // VK_RIGHT     -> kVK_RightArrow
    case 0x28: return 0x7D;  // VK_DOWN      -> kVK_DownArrow
    case 0x2D: return 0x72;  // VK_INSERT    -> kVK_Help
    case 0x2E: return 0x75;  // VK_DELETE    -> kVK_ForwardDelete
    case 0x5B: return 0x37;  // VK_LWIN      -> kVK_Command
    case 0x5C: return 0x36;  // VK_RWIN      -> kVK_RightCommand
    case 0x6A: return 0x43;  // VK_MULTIPLY  -> kVK_ANSI_KeypadMultiply
    case 0x6B: return 0x45;  // VK_ADD       -> kVK_ANSI_KeypadPlus
    case 0x6D: return 0x4E;  // VK_SUBTRACT  -> kVK_ANSI_KeypadMinus
    case 0x6E: return 0x41;  // VK_DECIMAL   -> kVK_ANSI_KeypadDecimal
    case 0x6F: return 0x4B;  // VK_DIVIDE    -> kVK_ANSI_KeypadDivide
    case 0x90: return 0x47;  // VK_NUMLOCK   -> kVK_ANSI_KeypadClear
    case 0xA0: return 0x38;  // VK_LSHIFT    -> kVK_Shift
    case 0xA1: return 0x3C;  // VK_RSHIFT    -> kVK_RightShift
    case 0xA2: return 0x3B;  // VK_LCONTROL  -> kVK_Control
    case 0xA3: return 0x3E;  // VK_RCONTROL  -> kVK_RightControl
    case 0xA4: return 0x3A;  // VK_LMENU     -> kVK_Option
    case 0xA5: return 0x3D;  // VK_RMENU     -> kVK_RightOption
    case 0xBA: return 0x29;  // VK_OEM_1 ;   -> kVK_ANSI_Semicolon
    case 0xBB: return 0x18;  // VK_OEM_PLUS  -> kVK_ANSI_Equal
    case 0xBC: return 0x2B;  // VK_OEM_COMMA -> kVK_ANSI_Comma
    case 0xBD: return 0x1B;  // VK_OEM_MINUS -> kVK_ANSI_Minus
    case 0xBE: return 0x2F;  // VK_OEM_PERIOD-> kVK_ANSI_Period
    case 0xBF: return 0x2C;  // VK_OEM_2 /   -> kVK_ANSI_Slash
    case 0xC0: return 0x32;  // VK_OEM_3 `   -> kVK_ANSI_Grave
    case 0xDB: return 0x21;  // VK_OEM_4 [   -> kVK_ANSI_LeftBracket
    case 0xDC: return 0x2A;  // VK_OEM_5 \   -> kVK_ANSI_Backslash
    case 0xDD: return 0x1E;  // VK_OEM_6 ]   -> kVK_ANSI_RightBracket
    case 0xDE: return 0x27;  // VK_OEM_7 '   -> kVK_ANSI_Quote
    case 0xE2: return 0x0A;  // VK_OEM_102   -> kVK_ISO_Section
    default:   return -1;
    }
}

static_assert(vk_to_kvk(0x41) == 0x00 && vk_to_kvk(0x5A) == 0x06);  // A, Z
static_assert(vk_to_kvk(0x70) == 0x7A && vk_to_kvk(0x83) == 0x5A);  // F1, F20
static_assert(vk_to_kvk(0x14) == -1);

/// Modifier keys: kVK code and the flags a real press of it sets (generic
/// mask plus the left/right device bit apps use to tell the sides apart).
struct Modifier { CGKeyCode key; CGEventFlags flags; };
constexpr Modifier kModifiers[] = {
    {0x38, kCGEventFlagMaskShift     | NX_DEVICELSHIFTKEYMASK},
    {0x3C, kCGEventFlagMaskShift     | NX_DEVICERSHIFTKEYMASK},
    {0x3B, kCGEventFlagMaskControl   | NX_DEVICELCTLKEYMASK},
    {0x3E, kCGEventFlagMaskControl   | NX_DEVICERCTLKEYMASK},
    {0x3A, kCGEventFlagMaskAlternate | NX_DEVICELALTKEYMASK},
    {0x3D, kCGEventFlagMaskAlternate | NX_DEVICERALTKEYMASK},
    {0x37, kCGEventFlagMaskCommand   | NX_DEVICELCMDKEYMASK},
    {0x36, kCGEventFlagMaskCommand   | NX_DEVICERCMDKEYMASK},
};

/// Flags a hardware keyboard adds to non-modifier keys: arrows and the
/// keypad are "numeric pad" keys, arrows/F-keys/navigation are "fn" keys.
CGEventFlags key_flags(CGKeyCode key) {
    if (key >= 0x7B && key <= 0x7E) {
        return kCGEventFlagMaskNumericPad | kCGEventFlagMaskSecondaryFn;
    }
    switch (key) {
    case 0x41: case 0x43: case 0x45: case 0x47: case 0x4B: case 0x4C: case 0x4E:
    case 0x51: case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: case 0x57:
    case 0x58: case 0x59: case 0x5B: case 0x5C:
        return kCGEventFlagMaskNumericPad;
    case 0x72: case 0x73: case 0x74: case 0x75: case 0x77: case 0x79:
    case 0x7A: case 0x78: case 0x63: case 0x76: case 0x60: case 0x61: case 0x62:
    case 0x64: case 0x65: case 0x6D: case 0x67: case 0x6F: case 0x69: case 0x6B:
    case 0x71: case 0x6A: case 0x40: case 0x4F: case 0x50: case 0x5A:
        return kCGEventFlagMaskSecondaryFn;
    default:
        return 0;
    }
}

// One Windows wheel notch (120) scrolls this many points. Calibration knob:
// a Windows notch is ~3 lines, a macOS line is ~10-15 points.
constexpr double kPixelsPerNotch = 40.0;
// Two presses closer than this (points) can form a double click; VR pointers
// jitter a little between clicks.
constexpr double kClickSlop = 6.0;

struct ButtonInfo {
    uint8_t       bit;
    CGMouseButton button;
    CGEventType   down, up, dragged;
};
constexpr ButtonInfo kButtons[] = {
    {0x01, kCGMouseButtonLeft,   kCGEventLeftMouseDown,  kCGEventLeftMouseUp,  kCGEventLeftMouseDragged},
    {0x02, kCGMouseButtonRight,  kCGEventRightMouseDown, kCGEventRightMouseUp, kCGEventRightMouseDragged},
    {0x04, kCGMouseButtonCenter, kCGEventOtherMouseDown, kCGEventOtherMouseUp, kCGEventOtherMouseDragged},
};

}  // namespace

class MacInputInjector : public IInputInjector {
public:
    ~MacInputInjector() override {
        if (source_) CFRelease(source_);
    }

    bool initialize() override {
        @autoreleasepool {
            std::lock_guard<std::mutex> lock(mutex_);
            NSDictionary* options = @{(__bridge NSString*)kAXTrustedCheckOptionPrompt: @YES};
            if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
                std::cerr << "[MacInput] Accessibility permission is not granted: mouse and\n"
                          << "[MacInput] keyboard from the headset will be ignored. Open System\n"
                          << "[MacInput] Settings > Privacy & Security > Accessibility, enable the\n"
                          << "[MacInput] app running this host (your terminal, or immersive2_host),\n"
                          << "[MacInput] then restart the host.\n";
            }
            if (!source_) source_ = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);

            const double interval = [[NSUserDefaults standardUserDefaults]
                doubleForKey:@"com.apple.mouse.doubleClickThreshold"];
            double_click_s_ = (interval > 0.05 && interval < 5.0) ? interval : 0.5;
            std::cout << "[MacInput] Initialized (CGEvent)\n";
        }  // @autoreleasepool
        return true;
    }

    void set_displays(const std::vector<DisplayInfo>& displays) override {
        std::lock_guard<std::mutex> lock(mutex_);
        displays_.clear();
        for (const auto& d : displays) displays_[d.id] = d;
    }

    void inject_mouse(const protocol::InputMouse& in) override {
        std::lock_guard<std::mutex> lock(mutex_);
        const CGPoint p = to_global(in.monitor_id, in.x, in.y);

        if (!has_pos_ || p.x != pos_.x || p.y != pos_.y) {
            post_move(p);
        }

        scroll_v_ += in.scroll_delta   * kPixelsPerNotch / 120.0;
        scroll_h_ += in.scroll_delta_h * kPixelsPerNotch / 120.0;
        const auto v = static_cast<int32_t>(std::trunc(scroll_v_));
        const auto h = static_cast<int32_t>(std::trunc(scroll_h_));
        if (v != 0 || h != 0) {
            scroll_v_ -= v;
            scroll_h_ -= h;
            // Windows: +vertical = away/up, +horizontal = right. CGEvent:
            // +wheel1 = up, +wheel2 = left.
            post(CGEventCreateScrollWheelEvent2(source_, kCGScrollEventUnitPixel,
                                                2, v, -h, 0));
        }

        for (const auto& b : kButtons) {
            if (!((in.buttons ^ buttons_) & b.bit)) continue;
            const bool down = in.buttons & b.bit;
            if (down) {
                const auto now = std::chrono::steady_clock::now();
                const bool chained =
                    click_button_ == b.button && click_count_ > 0 &&
                    std::chrono::duration<double>(now - click_time_).count() <= double_click_s_ &&
                    std::hypot(p.x - click_pos_.x, p.y - click_pos_.y) <= kClickSlop;
                click_count_  = chained ? click_count_ + 1 : 1;
                click_button_ = b.button;
                click_time_   = now;
                click_pos_    = p;
            }
            CGEventRef ev = CGEventCreateMouseEvent(source_, down ? b.down : b.up, p, b.button);
            // Only the clicked button carries the chain; another button's
            // release is a plain single click.
            CGEventSetIntegerValueField(ev, kCGMouseEventClickState,
                                        click_button_ == b.button ? click_count_ : 1);
            post(ev);
            buttons_ = static_cast<uint8_t>(buttons_ ^ b.bit);
        }
    }

    void inject_keyboard(const protocol::InputKeyboard& in) override {
        const int kvk = vk_to_kvk(in.scancode);
        if (kvk < 0) return;
        const auto key = static_cast<CGKeyCode>(kvk);

        std::lock_guard<std::mutex> lock(mutex_);
        CGEventFlags extra = key_flags(key);
        for (size_t i = 0; i < std::size(kModifiers); ++i) {
            if (kModifiers[i].key != key) continue;
            held_mods_ = in.pressed ? (held_mods_ | (1u << i)) : (held_mods_ & ~(1u << i));
            extra = 0;
        }
        // For a modifier this yields a flags-changed event carrying the new state.
        CGEventRef ev = CGEventCreateKeyboardEvent(source_, key, in.pressed != 0);
        post(ev, extra);
    }

    void move_cursor(uint8_t monitor_id, uint16_t x, uint16_t y) override {
        std::lock_guard<std::mutex> lock(mutex_);
        post_move(to_global(monitor_id, x, y));
    }

private:
    CGEventFlags modifier_flags() const {
        CGEventFlags flags = kCGEventFlagMaskNonCoalesced;
        for (size_t i = 0; i < std::size(kModifiers); ++i) {
            if (held_mods_ & (1u << i)) flags |= kModifiers[i].flags;
        }
        return flags;
    }

    void post(CGEventRef ev, CGEventFlags extra = 0) {
        if (!ev) return;
        CGEventSetFlags(ev, modifier_flags() | extra);
        CGEventPost(kCGHIDEventTap, ev);
        CFRelease(ev);
    }

    /// A drag while a button is held (what apps expect for selection and
    /// window moves), a plain move otherwise.
    void post_move(CGPoint p) {
        CGEventType type = kCGEventMouseMoved;
        CGMouseButton button = kCGMouseButtonLeft;
        for (const auto& b : kButtons) {
            if (buttons_ & b.bit) { type = b.dragged; button = b.button; break; }
        }
        post(CGEventCreateMouseEvent(source_, type, p, button));
        pos_ = p;
        has_pos_ = true;
    }

    CGPoint to_global(uint8_t monitor_id, uint16_t x, uint16_t y) const {
        auto it = displays_.find(monitor_id);
        if (it == displays_.end() || it->second.width == 0 || it->second.height == 0) {
            return CGPointMake(x, y);
        }
        const DisplayInfo& d = it->second;
        // Live bounds: the reported size is pixels, the event space is points.
        const CGRect b = CGDisplayBounds(d.native_id);
        const double px = std::min<double>(x, d.width - 1);
        const double py = std::min<double>(y, d.height - 1);
        return CGPointMake(b.origin.x + px * b.size.width / d.width,
                           b.origin.y + py * b.size.height / d.height);
    }

    std::mutex                               mutex_;
    CGEventSourceRef                         source_ = nullptr;
    std::unordered_map<uint8_t, DisplayInfo> displays_;
    double                                   double_click_s_ = 0.5;

    CGPoint  pos_     = CGPointZero;
    bool     has_pos_ = false;
    uint8_t  buttons_ = 0;
    uint32_t held_mods_ = 0;
    double   scroll_v_ = 0.0;
    double   scroll_h_ = 0.0;

    CGMouseButton                         click_button_ = kCGMouseButtonLeft;
    int64_t                               click_count_  = 0;
    std::chrono::steady_clock::time_point click_time_;
    CGPoint                               click_pos_    = CGPointZero;
};

std::unique_ptr<IInputInjector> create_input_injector() {
    return std::make_unique<MacInputInjector>();
}

}  // namespace immersive
