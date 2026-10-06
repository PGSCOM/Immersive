#pragma once

/// The host's persistent UI: a tray / menu-bar icon and a settings panel
/// served on 127.0.0.1 and opened as an app window in the browser.
/// main.cpp owns the streaming state; it lends the UI the few hooks below.
/// Nothing here runs on a streaming thread.

#include "network/server.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace immersive::ui {

/// Settings the panel changes live. main.cpp reads them where it used to read
/// its CLI variables. Loaded from host.conf, then overridden by CLI flags.
struct Settings {
    std::atomic<bool>     pin_enabled{true};
    std::atomic<uint32_t> pin{0};          ///< 100000-999999
    std::atomic<bool>     view_only{false};
    std::atomic<uint8_t>  codec{2};        ///< protocol VideoCodec: 0 H.264, 1 HEVC, 2 MJPEG, 3 AV1
    std::atomic<uint32_t> jpeg_quality{35};
    std::atomic<bool>     audio{true};
    std::atomic<bool>     usb{true};       ///< keep `adb reverse` running
    /// This PC's TLS identity, as the headset shows it when pairing (set
    /// once before the panel starts; empty without TLS).
    std::string           fingerprint;
};

/// host.conf in `dir` into `s`: `key = value` lines; missing keys keep the
/// defaults. Keys: pin (on/off), view_only, codec (mjpeg/h264/h265/av1),
/// jpeg_quality, audio, usb.
void load_host_conf(const std::filesystem::path& dir, Settings& s);

/// Write one key, keeping the rest of the file, so a CLI override of this run
/// is never saved unless the user changes that setting in the panel.
bool save_host_conf_key(const std::filesystem::path& dir, const std::string& key,
                        const std::string& value);

/// A new random PIN, stored in <dir>/pairing-pin (the PIN kept across runs).
uint32_t new_pairing_pin(const std::filesystem::path& dir);

struct MonitorRow {
    uint8_t     id;
    std::string name;
    uint16_t    width, height;
    bool        is_virtual;
};

struct StreamRow {
    uint8_t  monitor_id;
    uint8_t  codec;          ///< as announced in STREAM_START
    uint16_t width, height;
    uint32_t fps_cap;
    uint64_t frames, bytes;  ///< sent so far; the panel turns them into rates
};

/// What only main.cpp knows. Called from the panel's thread: each must be
/// thread-safe and must not hold a lock the streaming threads wait on.
struct Hooks {
    std::function<std::vector<MonitorRow>()> monitors;
    /// The streams and the client they go to (0 = none).
    std::function<std::vector<StreamRow>(uint32_t& client_id)> streams;
    /// Remove a virtual screen this host made. May block a few seconds.
    std::function<bool(uint8_t id)> remove_virtual;
    /// Why the USB switch is not doing its job yet ("" when it is).
    std::function<std::string()> usb_note;
    std::function<void()> quit;
};

struct Options {
    std::filesystem::path config_dir;
    uint16_t panel_port = 19803;  ///< 0 or busy: any free port
    uint16_t tcp_port = 0;
    uint16_t audio_port = 0;
    bool     audio_available = false;  ///< false with --no-audio / --stub
    bool     virtual_supported = false;
    bool     screen_off_supported = false;  ///< HOST_FLAG_SCREEN_OFF
    bool     stub = false;             ///< never touch the desktop portal
};

class HostUi {
public:
    virtual ~HostUi() = default;
    /// Call from the main thread instead of sleeping: runs the macOS menu
    /// bar; elsewhere it just waits (the tray has its own thread).
    virtual void pump(std::chrono::milliseconds wait) = 0;
    virtual std::string url() const = 0;
};

/// Serves the panel and shows the tray icon. Opens the panel window at once
/// when this desktop has no tray to click. nullptr if the panel cannot listen.
std::unique_ptr<HostUi> start(Settings& settings, INetworkServer& server, Hooks hooks,
                              Options options);

/// A host is already running for this user: open its panel and return true
/// (a second launch from the desktop shows the window instead of failing).
bool open_running_instance(const std::filesystem::path& config_dir);

// ---- per-OS pieces (ui_platform_*.cpp) -----------------------------------

/// Open `url` as an app window (Edge / Chrome --app) or in the default browser.
void open_app_window(const std::string& url);
bool autostart_enabled();
bool set_autostart(bool on);

/// A tray / status icon. `pump` runs it where it must live on the main thread.
struct TrayModel {
    std::function<std::string()> status;    ///< "Waiting for a headset", ...
    std::function<std::string()> pin_line;  ///< "PIN 123 456" or "PIN off"
    std::function<bool()>        live;      ///< a headset is streaming
    std::function<void()>        open;
    std::function<void()>        quit;
};
class Tray {
public:
    virtual ~Tray() = default;
    /// Whether an icon is actually visible (Linux: a StatusNotifierWatcher
    /// took it). Without one the panel window opens at startup.
    virtual bool visible() const = 0;
    virtual void pump(std::chrono::milliseconds wait) = 0;
};
std::unique_ptr<Tray> create_tray(TrayModel model);

/// The tray mark (a screen seen through a headset lens) as `size`x`size`
/// ARGB32 pixels (0xAARRGGBB), in `ink`; `tally` adds the red "live" dot.
std::vector<uint32_t> tray_icon_pixels(int size, uint32_t ink, bool tally);

}  // namespace immersive::ui
