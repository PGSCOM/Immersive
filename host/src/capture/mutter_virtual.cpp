/// GNOME virtual screens: Mutter's ScreenCast RecordVirtual on a session
/// linked to a RemoteDesktop session (see mutter_virtual.h). One pair of
/// sessions per screen; stopping the RemoteDesktop session removes the
/// monitor. Also the main screen off, through Mutter's DisplayConfig. All
/// D-Bus traffic goes through one private connection under g_mutex.

#include "capture/mutter_virtual.h"
#include "capture/linux_backends.h"
#include "protocol.h"

#include <dbus/dbus.h>

#include <chrono>
#include <cstdarg>
#include <iostream>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace immersive::mutter {

namespace {

constexpr char kScBus[]     = "org.gnome.Mutter.ScreenCast";
constexpr char kScPath[]    = "/org/gnome/Mutter/ScreenCast";
constexpr char kScSession[] = "org.gnome.Mutter.ScreenCast.Session";
constexpr char kScStream[]  = "org.gnome.Mutter.ScreenCast.Stream";
constexpr char kRdBus[]     = "org.gnome.Mutter.RemoteDesktop";
constexpr char kRdPath[]    = "/org/gnome/Mutter/RemoteDesktop";
constexpr char kRdSession[] = "org.gnome.Mutter.RemoteDesktop.Session";
constexpr char kDcBus[]     = "org.gnome.Mutter.DisplayConfig";
constexpr char kDcPath[]    = "/org/gnome/Mutter/DisplayConfig";
constexpr int kCallTimeoutMs = 5000;

struct Screen {
    uint16_t width = 0, height = 0;
    std::string rd_session;  // RemoteDesktop session object path
    std::string stream;      // ScreenCast stream object path
    std::shared_ptr<IScreenCapture> consumer;  // keeps the monitor alive
};

std::mutex g_mutex;  // the connection and g_screens
DBusConnection* g_conn = nullptr;
std::map<uint8_t, Screen> g_screens;

bool connect_locked() {
    if (g_conn && dbus_connection_get_is_connected(g_conn)) return true;
    if (g_conn) {
        dbus_connection_unref(g_conn);
        g_conn = nullptr;
    }
    DBusError err;
    dbus_error_init(&err);
    g_conn = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
    if (!g_conn) {
        std::cerr << "[MutterVirtual] No session bus: " << (err.message ? err.message : "") << "\n";
        dbus_error_free(&err);
        return false;
    }
    dbus_connection_set_exit_on_disconnect(g_conn, false);
    return true;
}

/// Blocking method call; consumes `m`. The reply, or nullptr (logged).
DBusMessage* call(DBusMessage* m) {
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* r = dbus_connection_send_with_reply_and_block(g_conn, m, kCallTimeoutMs, &err);
    if (!r) {
        std::cerr << "[MutterVirtual] " << dbus_message_get_member(m) << " failed: "
                  << (err.message ? err.message : "no reply") << "\n";
        dbus_error_free(&err);
    }
    dbus_message_unref(m);
    return r;
}

/// A call whose reply is one object path ("" on failure); consumes `m`.
std::string call_for_path(DBusMessage* m) {
    DBusMessage* r = call(m);
    if (!r) return "";
    const char* path = nullptr;
    std::string out;
    if (dbus_message_get_args(r, nullptr, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_INVALID) && path)
        out = path;
    dbus_message_unref(r);
    return out;
}

/// Appends an a{sv} with at most one string and one uint32 entry.
void append_options(DBusMessage* m, const char* str_key, const char* str_val,
                    const char* u32_key, dbus_uint32_t u32_val) {
    DBusMessageIter args, dict, entry, var;
    dbus_message_iter_init_append(m, &args);
    dbus_message_iter_open_container(&args, DBUS_TYPE_ARRAY, "{sv}", &dict);
    if (str_key) {
        dbus_message_iter_open_container(&dict, DBUS_TYPE_DICT_ENTRY, nullptr, &entry);
        dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &str_key);
        dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &var);
        dbus_message_iter_append_basic(&var, DBUS_TYPE_STRING, &str_val);
        dbus_message_iter_close_container(&entry, &var);
        dbus_message_iter_close_container(&dict, &entry);
    }
    if (u32_key) {
        dbus_message_iter_open_container(&dict, DBUS_TYPE_DICT_ENTRY, nullptr, &entry);
        dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &u32_key);
        dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "u", &var);
        dbus_message_iter_append_basic(&var, DBUS_TYPE_UINT32, &u32_val);
        dbus_message_iter_close_container(&entry, &var);
        dbus_message_iter_close_container(&dict, &entry);
    }
    dbus_message_iter_close_container(&args, &dict);
}

std::string get_string_property(const std::string& path, const char* iface, const char* prop) {
    DBusMessage* m = dbus_message_new_method_call(kRdBus, path.c_str(),
                                                  "org.freedesktop.DBus.Properties", "Get");
    dbus_message_append_args(m, DBUS_TYPE_STRING, &iface, DBUS_TYPE_STRING, &prop,
                             DBUS_TYPE_INVALID);
    DBusMessage* r = call(m);
    if (!r) return "";
    std::string out;
    DBusMessageIter it, var;
    if (dbus_message_iter_init(r, &it) && dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_VARIANT) {
        dbus_message_iter_recurse(&it, &var);
        if (dbus_message_iter_get_arg_type(&var) == DBUS_TYPE_STRING) {
            const char* s = nullptr;
            dbus_message_iter_get_basic(&var, &s);
            if (s) out = s;
        }
    }
    dbus_message_unref(r);
    return out;
}

/// Fire-and-forget call on a RemoteDesktop session.
void notify(const std::string& rd_session, const char* method, int first_type, ...) {
    DBusMessage* m = dbus_message_new_method_call(kRdBus, rd_session.c_str(), kRdSession, method);
    va_list ap;
    va_start(ap, first_type);
    dbus_message_append_args_valist(m, first_type, ap);
    va_end(ap);
    dbus_message_set_no_reply(m, TRUE);
    dbus_connection_send(g_conn, m, nullptr);
    dbus_message_unref(m);
    dbus_connection_flush(g_conn);
}

/// Drops queued messages, noting sessions Mutter closed on its own (a
/// compositor restart, the monitor turned off in Settings).
void pump_locked() {
    if (!g_conn) return;
    dbus_connection_read_write(g_conn, 0);
    while (DBusMessage* msg = dbus_connection_pop_message(g_conn)) {
        if (dbus_message_is_signal(msg, kRdSession, "Closed")) {
            const char* path = dbus_message_get_path(msg);
            for (auto it = g_screens.begin(); it != g_screens.end(); ++it) {
                if (path && it->second.rd_session == path) {
                    std::cerr << "[MutterVirtual] Virtual screen "
                              << it->first - protocol::VIRTUAL_MONITOR_ID_BASE + 1
                              << " was closed by the compositor\n";
                    g_screens.erase(it);
                    break;
                }
            }
        }
        dbus_message_unref(msg);
    }
}

void stop_session(const std::string& rd_session) {
    if (rd_session.empty()) return;
    DBusMessage* r = call(dbus_message_new_method_call(kRdBus, rd_session.c_str(),
                                                       kRdSession, "Stop"));
    if (r) dbus_message_unref(r);
}

/// Waits for the stream's PipeWireStreamAdded(node) after Start. 0 on timeout.
uint32_t wait_for_node(const std::string& stream) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(kCallTimeoutMs);
    while (std::chrono::steady_clock::now() < end) {
        dbus_connection_read_write(g_conn, 100);
        while (DBusMessage* msg = dbus_connection_pop_message(g_conn)) {
            dbus_uint32_t node = 0;
            const char* path = dbus_message_get_path(msg);
            const bool ours = dbus_message_is_signal(msg, kScStream, "PipeWireStreamAdded") &&
                              path && stream == path &&
                              dbus_message_get_args(msg, nullptr, DBUS_TYPE_UINT32, &node,
                                                    DBUS_TYPE_INVALID);
            dbus_message_unref(msg);
            if (ours) return node;
        }
    }
    return 0;
}

// --- Main screen off (org.gnome.Mutter.DisplayConfig) ---

/// The primary monitor as GetResources describes it.
struct PrimaryOutput {
    dbus_uint32_t serial = 0;
    int32_t crtc = -1;       // -1: none lit
    std::string connector;   // "eDP-1"
};

using Ramp = std::vector<dbus_uint16_t>;
struct Gamma { Ramp red, green, blue; };

/// The primary output (else the first lit one) from GetResources.
PrimaryOutput primary_output_locked() {
    PrimaryOutput out;
    DBusMessage* r = call(dbus_message_new_method_call(kDcBus, kDcPath, kDcBus, "GetResources"));
    if (!r) return out;
    DBusMessageIter it, outputs, o, props;
    if (dbus_message_iter_init(r, &it) && dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_UINT32) {
        dbus_message_iter_get_basic(&it, &out.serial);
        dbus_message_iter_next(&it);  // crtcs
        dbus_message_iter_next(&it);  // outputs: a(uxiausauaua{sv})
        if (dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_ARRAY)
            dbus_message_iter_recurse(&it, &outputs);
        while (dbus_message_iter_get_arg_type(&outputs) == DBUS_TYPE_STRUCT) {
            dbus_message_iter_recurse(&outputs, &o);
            dbus_message_iter_next(&o);  // id
            dbus_message_iter_next(&o);  // winsys id
            dbus_int32_t crtc = -1;
            dbus_message_iter_get_basic(&o, &crtc);
            dbus_message_iter_next(&o);  // current crtc
            dbus_message_iter_next(&o);  // possible crtcs
            const char* name = "";
            dbus_message_iter_get_basic(&o, &name);
            for (int i = 0; i < 3; ++i) dbus_message_iter_next(&o);  // name, modes, clones
            bool primary = false;
            dbus_message_iter_recurse(&o, &props);
            while (dbus_message_iter_get_arg_type(&props) == DBUS_TYPE_DICT_ENTRY) {
                DBusMessageIter entry, var;
                dbus_message_iter_recurse(&props, &entry);
                const char* key = "";
                dbus_message_iter_get_basic(&entry, &key);
                dbus_message_iter_next(&entry);
                dbus_message_iter_recurse(&entry, &var);
                const std::string k = key;
                if (k == "primary" && dbus_message_iter_get_arg_type(&var) == DBUS_TYPE_BOOLEAN) {
                    dbus_bool_t b = FALSE;
                    dbus_message_iter_get_basic(&var, &b);
                    primary = b;
                }
                dbus_message_iter_next(&props);
            }
            if (crtc >= 0 && (out.crtc < 0 || primary)) {
                out.crtc = crtc;
                out.connector = name;
            }
            if (crtc >= 0 && primary) break;
            dbus_message_iter_next(&outputs);
        }
    }
    dbus_message_unref(r);
    return out;
}

bool get_gamma_locked(dbus_uint32_t serial, dbus_uint32_t crtc, Gamma& g) {
    DBusMessage* m = dbus_message_new_method_call(kDcBus, kDcPath, kDcBus, "GetCrtcGamma");
    dbus_message_append_args(m, DBUS_TYPE_UINT32, &serial, DBUS_TYPE_UINT32, &crtc, DBUS_TYPE_INVALID);
    DBusMessage* r = call(m);
    if (!r) return false;
    dbus_uint16_t *red = nullptr, *green = nullptr, *blue = nullptr;
    int nr = 0, ng = 0, nb = 0;
    const bool ok = dbus_message_get_args(r, nullptr,
        DBUS_TYPE_ARRAY, DBUS_TYPE_UINT16, &red, &nr, DBUS_TYPE_ARRAY, DBUS_TYPE_UINT16, &green, &ng,
        DBUS_TYPE_ARRAY, DBUS_TYPE_UINT16, &blue, &nb, DBUS_TYPE_INVALID) && nr > 1 && nr == ng && nr == nb;
    if (ok) g = {Ramp(red, red + nr), Ramp(green, green + ng), Ramp(blue, blue + nb)};
    dbus_message_unref(r);
    return ok;
}

bool set_gamma_locked(dbus_uint32_t serial, dbus_uint32_t crtc, const Gamma& g) {
    DBusMessage* m = dbus_message_new_method_call(kDcBus, kDcPath, kDcBus, "SetCrtcGamma");
    const dbus_uint16_t *red = g.red.data(), *green = g.green.data(), *blue = g.blue.data();
    const int n = static_cast<int>(g.red.size());
    dbus_message_append_args(m, DBUS_TYPE_UINT32, &serial, DBUS_TYPE_UINT32, &crtc,
        DBUS_TYPE_ARRAY, DBUS_TYPE_UINT16, &red, n, DBUS_TYPE_ARRAY, DBUS_TYPE_UINT16, &green, n,
        DBUS_TYPE_ARRAY, DBUS_TYPE_UINT16, &blue, n, DBUS_TYPE_INVALID);
    DBusMessage* r = call(m);
    if (r) dbus_message_unref(r);
    return r != nullptr;
}

/// A panel's backlight from the Backlight property, (u serial, aa{sv}),
/// in raw units between min and max (GNOME 47+; older ones: none).
struct Backlight {
    dbus_uint32_t serial = 0;
    int32_t min = 0, max = 0, value = -1;  // value -1: this output has none
};

Backlight backlight_locked(const std::string& connector) {
    Backlight out;
    const char* iface = kDcBus;
    const char* prop = "Backlight";
    DBusMessage* m = dbus_message_new_method_call(kDcBus, kDcPath, "org.freedesktop.DBus.Properties", "Get");
    dbus_message_append_args(m, DBUS_TYPE_STRING, &iface, DBUS_TYPE_STRING, &prop, DBUS_TYPE_INVALID);
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* r = dbus_connection_send_with_reply_and_block(g_conn, m, kCallTimeoutMs, &err);
    dbus_error_free(&err);  // no such property: an older GNOME, the gamma alone darkens it
    dbus_message_unref(m);
    if (!r) return out;
    DBusMessageIter it, var, st, list, dict;
    if (dbus_message_iter_init(r, &it) && dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_VARIANT) {
        dbus_message_iter_recurse(&it, &var);
        dbus_message_iter_recurse(&var, &st);
        if (dbus_message_iter_get_arg_type(&st) == DBUS_TYPE_UINT32) {
            dbus_message_iter_get_basic(&st, &out.serial);
            dbus_message_iter_next(&st);
            dbus_message_iter_recurse(&st, &list);
        }
        while (dbus_message_iter_get_arg_type(&list) == DBUS_TYPE_ARRAY) {
            std::string name;
            int32_t min = 0, max = 0, value = -1;
            dbus_message_iter_recurse(&list, &dict);
            while (dbus_message_iter_get_arg_type(&dict) == DBUS_TYPE_DICT_ENTRY) {
                DBusMessageIter entry, v;
                dbus_message_iter_recurse(&dict, &entry);
                const char* key = "";
                dbus_message_iter_get_basic(&entry, &key);
                dbus_message_iter_next(&entry);
                dbus_message_iter_recurse(&entry, &v);
                const std::string k = key;
                const int type = dbus_message_iter_get_arg_type(&v);
                if (k == "connector" && type == DBUS_TYPE_STRING) {
                    const char* c = "";
                    dbus_message_iter_get_basic(&v, &c);
                    name = c;
                } else if (type == DBUS_TYPE_INT32) {
                    dbus_int32_t n = 0;
                    dbus_message_iter_get_basic(&v, &n);
                    if (k == "min") min = n; else if (k == "max") max = n; else if (k == "value") value = n;
                }
                dbus_message_iter_next(&dict);
            }
            if (name == connector && max > min) {
                out.min = min;
                out.max = max;
                out.value = value;
            }
            dbus_message_iter_next(&list);
        }
    }
    dbus_message_unref(r);
    return out;
}

void set_backlight_locked(const std::string& connector, dbus_int32_t value) {
    const Backlight b = backlight_locked(connector);
    if (b.value < 0) return;
    DBusMessage* m = dbus_message_new_method_call(kDcBus, kDcPath, kDcBus, "SetBacklight");
    const char* c = connector.c_str();
    dbus_message_append_args(m, DBUS_TYPE_UINT32, &b.serial, DBUS_TYPE_STRING, &c,
                             DBUS_TYPE_INT32, &value, DBUS_TYPE_INVALID);
    DBusMessage* r = call(m);
    if (r) dbus_message_unref(r);
}

class MutterVirtualDisplayManager : public IVirtualDisplayManager {
public:
    MutterVirtualDisplayManager() {
        // A host killed while the screen was off leaves Mutter with an
        // all-zero ramp (and the backlight at its minimum): nobody sets that
        // on purpose.
        std::lock_guard<std::mutex> lock(g_mutex);
        const PrimaryOutput p = primary_output_locked();
        Gamma g;
        if (p.crtc < 0 || !get_gamma_locked(p.serial, p.crtc, g)) return;
        for (size_t i = 0; i < g.red.size(); ++i)
            if (g.red[i] || g.green[i] || g.blue[i]) return;
        for (size_t i = 0; i < g.red.size(); ++i)
            g.red[i] = g.green[i] = g.blue[i] = static_cast<dbus_uint16_t>(i * 65535 / (g.red.size() - 1));
        set_gamma_locked(p.serial, p.crtc, g);
        const Backlight b = backlight_locked(p.connector);
        if (b.value >= 0 && b.value <= b.min) set_backlight_locked(p.connector, (b.min + b.max) / 4);
        std::cout << "[MutterVirtual] The main screen, left dark by an earlier run, is lit again\n";
    }

    ~MutterVirtualDisplayManager() override { set_primary_off(false); }

    bool can_create_displays() const override { return true; }

    /// Dark: a zero gamma ramp (applied at scanout, after the screencast
    /// reads the picture) and, on a laptop panel, the backlight at its
    /// minimum (GNOME keeps it above 0). Asked
    /// again on every lease renewal: Mutter puts its own ramp back when the
    /// monitors change (a virtual screen added, say).
    bool can_turn_off_primary() const override {
        std::lock_guard<std::mutex> lock(g_mutex);
        return primary_output_locked().crtc >= 0;
    }

    bool set_primary_off(bool off) override {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!off && !dark_) return true;
        if (!connect_locked()) return false;
        const PrimaryOutput p = primary_output_locked();
        if (!off) {
            dark_ = false;
            for (const auto& [crtc, g] : saved_gamma_) set_gamma_locked(p.serial, crtc, g);
            saved_gamma_.clear();
            if (saved_backlight_ >= 0) set_backlight_locked(backlight_connector_, saved_backlight_);
            saved_backlight_ = -1;
            return true;
        }
        if (p.crtc < 0) return dark_;
        if (!saved_gamma_.count(p.crtc)) {
            Gamma g;
            if (!get_gamma_locked(p.serial, p.crtc, g)) return dark_;
            saved_gamma_[p.crtc] = std::move(g);
        }
        const Gamma& saved = saved_gamma_[p.crtc];
        const Ramp zero(saved.red.size(), 0);
        if (!set_gamma_locked(p.serial, p.crtc, {zero, zero, zero})) return dark_;
        const Backlight b = backlight_locked(p.connector);
        if (b.value > b.min) {
            if (saved_backlight_ < 0) {
                saved_backlight_ = b.value;
                backlight_connector_ = p.connector;
            }
            set_backlight_locked(p.connector, b.min);
        }
        dark_ = true;
        return true;
    }

    uint8_t create_display(const VirtualDisplayConfig& config) override {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!connect_locked()) return 0;
        pump_locked();
        uint8_t id = 0;
        for (uint8_t n = 0; n < protocol::MAX_VIRTUAL_DISPLAYS && !id; ++n) {
            if (!g_screens.count(protocol::VIRTUAL_MONITOR_ID_BASE + n))
                id = protocol::VIRTUAL_MONITOR_ID_BASE + n;
        }
        if (!id) return 0;

        Screen sc;
        sc.width = config.width;
        sc.height = config.height;
        sc.rd_session = call_for_path(dbus_message_new_method_call(
            kRdBus, kRdPath, kRdBus, "CreateSession"));
        const std::string session_id = sc.rd_session.empty() ? "" :
            get_string_property(sc.rd_session, kRdSession, "SessionId");
        std::string sc_session;
        if (!session_id.empty()) {
            DBusMessage* m = dbus_message_new_method_call(kScBus, kScPath, kScBus, "CreateSession");
            append_options(m, "remote-desktop-session-id", session_id.c_str(), nullptr, 0);
            sc_session = call_for_path(m);
        }
        if (!sc_session.empty()) {
            DBusMessage* m = dbus_message_new_method_call(kScBus, sc_session.c_str(), kScSession,
                                                          "RecordVirtual");
            // Metadata: pipewire_capture.cpp draws it. Embedded, Mutter sent
            // nothing for a cursor-only move on an idle virtual screen.
            append_options(m, nullptr, nullptr, "cursor-mode", 2);
            sc.stream = call_for_path(m);
        }
        uint32_t node = 0;
        if (!sc.stream.empty()) {
            const std::string rule = std::string("type='signal',interface='") + kScStream +
                                     "',member='PipeWireStreamAdded',path='" + sc.stream + "'";
            dbus_bus_add_match(g_conn, rule.c_str(), nullptr);
            const std::string closed = std::string("type='signal',interface='") + kRdSession +
                                       "',member='Closed',path='" + sc.rd_session + "'";
            dbus_bus_add_match(g_conn, closed.c_str(), nullptr);
            DBusMessage* r = call(dbus_message_new_method_call(kRdBus, sc.rd_session.c_str(),
                                                               kRdSession, "Start"));
            if (r) {
                dbus_message_unref(r);
                node = wait_for_node(sc.stream);
            }
        }
        // Mutter makes the monitor as big as the consumer asks, once the
        // format is negotiated; the consumer then lives as long as it does.
        if (node) sc.consumer = create_pipewire_node_capture(node, config.width, config.height);
        if (!sc.consumer) {
            std::cerr << "[MutterVirtual] Could not create a " << config.width << "x"
                      << config.height << " virtual screen\n";
            stop_session(sc.rd_session);
            return 0;
        }
        std::cout << "[MutterVirtual] Virtual screen "
                  << id - protocol::VIRTUAL_MONITOR_ID_BASE + 1 << ": " << config.width << "x"
                  << config.height << " (PipeWire node " << node << ")\n";
        g_screens[id] = std::move(sc);
        return id;
    }

    bool remove_display(uint8_t id) override {
        std::shared_ptr<IScreenCapture> consumer;
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_screens.find(id);
        if (it == g_screens.end()) return false;
        consumer = std::move(it->second.consumer);
        const std::string session = it->second.rd_session;
        g_screens.erase(it);
        consumer.reset();  // a capture still reading it holds its own reference
        stop_session(session);
        std::cout << "[MutterVirtual] Removed virtual screen "
                  << id - protocol::VIRTUAL_MONITOR_ID_BASE + 1 << "\n";
        return true;
    }

    void remove_all_displays() override {
        for (uint8_t id : get_active_displays()) remove_display(id);
    }

    std::vector<uint8_t> get_active_displays() const override {
        std::lock_guard<std::mutex> lock(g_mutex);
        std::vector<uint8_t> ids;
        for (const auto& [id, sc] : g_screens) ids.push_back(id);
        return ids;
    }

private:
    bool dark_ = false;
    std::map<dbus_uint32_t, Gamma> saved_gamma_;  // by CRTC, while dark
    int32_t saved_backlight_ = -1;
    std::string backlight_connector_;
};

}  // namespace

std::vector<DisplayInfo> displays() {
    std::lock_guard<std::mutex> lock(g_mutex);
    pump_locked();
    std::vector<DisplayInfo> out;
    for (const auto& [id, sc] : g_screens) {
        DisplayInfo d{};
        d.id = id;
        d.width = sc.width;
        d.height = sc.height;
        d.refresh_rate = 60;
        d.name = "Virtual screen " + std::to_string(id - protocol::VIRTUAL_MONITOR_ID_BASE + 1);
        out.push_back(d);
    }
    return out;
}

bool exists(uint8_t id) {
    std::lock_guard<std::mutex> lock(g_mutex);
    pump_locked();
    auto it = g_screens.find(id);
    return it != g_screens.end() && it->second.consumer && it->second.consumer->is_capturing();
}

std::unique_ptr<CapturedFrame> acquire(uint8_t id, uint32_t timeout_ms) {
    std::shared_ptr<IScreenCapture> consumer;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_screens.find(id);
        if (it != g_screens.end()) consumer = it->second.consumer;
    }
    if (!consumer) return nullptr;
    auto frame = consumer->acquire_frame(timeout_ms);
    if (frame) frame->monitor_id = id;
    return frame;
}

bool has_sessions() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return !g_screens.empty();
}

void pointer_motion(uint8_t id, double x, double y) {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_screens.find(id);
    if (it == g_screens.end() || !g_conn) return;
    const char* stream = it->second.stream.c_str();
    notify(it->second.rd_session, "NotifyPointerMotionAbsolute", DBUS_TYPE_STRING, &stream,
           DBUS_TYPE_DOUBLE, &x, DBUS_TYPE_DOUBLE, &y, DBUS_TYPE_INVALID);
}

bool pointer_button(int32_t evdev_button, bool pressed) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_screens.empty() || !g_conn) return false;
    const dbus_int32_t b = evdev_button;
    const dbus_bool_t state = pressed;
    notify(g_screens.begin()->second.rd_session, "NotifyPointerButton", DBUS_TYPE_INT32, &b,
           DBUS_TYPE_BOOLEAN, &state, DBUS_TYPE_INVALID);
    return true;
}

void pointer_axis_discrete(uint32_t axis, int32_t steps) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_screens.empty() || !g_conn) return;
    const dbus_uint32_t a = axis;
    const dbus_int32_t n = steps;
    notify(g_screens.begin()->second.rd_session, "NotifyPointerAxisDiscrete", DBUS_TYPE_UINT32, &a,
           DBUS_TYPE_INT32, &n, DBUS_TYPE_INVALID);
}

void keyboard_keysym(int32_t keysym, bool pressed) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_screens.empty() || !g_conn) return;
    const dbus_uint32_t k = static_cast<dbus_uint32_t>(keysym);
    const dbus_bool_t state = pressed;
    notify(g_screens.begin()->second.rd_session, "NotifyKeyboardKeysym", DBUS_TYPE_UINT32, &k,
           DBUS_TYPE_BOOLEAN, &state, DBUS_TYPE_INVALID);
}

}  // namespace immersive::mutter

namespace immersive {

std::unique_ptr<IVirtualDisplayManager> create_mutter_virtual_display_manager() {
    // Only asks whether GNOME's compositor API is on the bus; nothing is
    // created until a headset asks for a screen.
    bool present = false;
    {
        std::lock_guard<std::mutex> lock(mutter::g_mutex);  // the constructor takes it too
        DBusError err;
        dbus_error_init(&err);
        present = mutter::connect_locked() &&
                  dbus_bus_name_has_owner(mutter::g_conn, mutter::kScBus, &err) &&
                  dbus_bus_name_has_owner(mutter::g_conn, mutter::kRdBus, &err);
        dbus_error_free(&err);
    }
    if (!present) {
        std::cout << "[MutterVirtual] Not GNOME (no org.gnome.Mutter.ScreenCast): "
                     "no virtual screens on this desktop\n";
        return std::make_unique<IVirtualDisplayManager>();
    }
    return std::make_unique<mutter::MutterVirtualDisplayManager>();
}

}  // namespace immersive
