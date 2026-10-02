/// Linux tray icon: a StatusNotifierItem (KDE, and GNOME through the
/// AppIndicator extension) with a com.canonical.dbusmenu menu, over its own
/// private session-bus connection and thread. Without a
/// StatusNotifierWatcher the icon is not visible (the panel window opens at
/// startup instead); it registers as soon as a watcher appears.

#include "ui/host_ui.h"

#include <dbus/dbus.h>

#include <condition_variable>
#include <cstring>
#include <iostream>
#include <mutex>
#include <thread>
#include <unistd.h>

namespace immersive::ui {

namespace {

constexpr const char* kItemPath = "/StatusNotifierItem";
constexpr const char* kMenuPath = "/MenuBar";
constexpr const char* kItemIface = "org.kde.StatusNotifierItem";
constexpr const char* kMenuIface = "com.canonical.dbusmenu";
constexpr const char* kWatcher = "org.kde.StatusNotifierWatcher";
constexpr const char* kProps = "org.freedesktop.DBus.Properties";
constexpr uint32_t kInk = 0xFFECE6DC;  // bone ink (ui_theme.gd INK), for dark panels

enum ItemId { kRoot = 0, kOpen = 1, kSep1 = 2, kStatus = 3, kPin = 4, kSep2 = 5, kQuit = 6 };

const char* kItemXml =
    "<node><interface name='org.kde.StatusNotifierItem'>"
    "<property name='Category' type='s' access='read'/><property name='Id' type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/><property name='Status' type='s' access='read'/>"
    "<property name='WindowId' type='i' access='read'/><property name='IconName' type='s' access='read'/>"
    "<property name='IconPixmap' type='a(iiay)' access='read'/>"
    "<property name='AttentionIconName' type='s' access='read'/>"
    "<property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "<property name='ItemIsMenu' type='b' access='read'/><property name='Menu' type='o' access='read'/>"
    "<method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='SecondaryActivate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='Scroll'><arg type='i' direction='in'/><arg type='s' direction='in'/></method>"
    "<signal name='NewIcon'/><signal name='NewToolTip'/><signal name='NewStatus'><arg type='s'/></signal>"
    "</interface><interface name='org.freedesktop.DBus.Properties'>"
    "<method name='Get'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='out'/></method>"
    "<method name='GetAll'><arg type='s' direction='in'/><arg type='a{sv}' direction='out'/></method>"
    "</interface></node>";

const char* kMenuXml =
    "<node><interface name='com.canonical.dbusmenu'>"
    "<property name='Version' type='u' access='read'/><property name='TextDirection' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/><property name='IconThemePath' type='as' access='read'/>"
    "<method name='GetLayout'><arg type='i' direction='in'/><arg type='i' direction='in'/>"
    "<arg type='as' direction='in'/><arg type='u' direction='out'/><arg type='(ia{sv}av)' direction='out'/></method>"
    "<method name='GetGroupProperties'><arg type='ai' direction='in'/><arg type='as' direction='in'/>"
    "<arg type='a(ia{sv})' direction='out'/></method>"
    "<method name='GetProperty'><arg type='i' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='out'/></method>"
    "<method name='Event'><arg type='i' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='in'/>"
    "<arg type='u' direction='in'/></method>"
    "<method name='EventGroup'><arg type='a(isvu)' direction='in'/><arg type='ai' direction='out'/></method>"
    "<method name='AboutToShow'><arg type='i' direction='in'/><arg type='b' direction='out'/></method>"
    "<method name='AboutToShowGroup'><arg type='ai' direction='in'/><arg type='ai' direction='out'/>"
    "<arg type='ai' direction='out'/></method>"
    "<signal name='LayoutUpdated'><arg type='u'/><arg type='i'/></signal>"
    "</interface><interface name='org.freedesktop.DBus.Properties'>"
    "<method name='Get'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='out'/></method>"
    "<method name='GetAll'><arg type='s' direction='in'/><arg type='a{sv}' direction='out'/></method>"
    "</interface></node>";

// ---- marshalling helpers ----------------------------------------------------

void put_str(DBusMessageIter* it, const std::string& s) {
    const char* c = s.c_str();
    dbus_message_iter_append_basic(it, DBUS_TYPE_STRING, &c);
}

template <typename F>
void variant(DBusMessageIter* it, const char* sig, F fill) {
    DBusMessageIter v;
    dbus_message_iter_open_container(it, DBUS_TYPE_VARIANT, sig, &v);
    fill(&v);
    dbus_message_iter_close_container(it, &v);
}

template <typename F>
void dict_entry(DBusMessageIter* dict, const std::string& key, const char* sig, F fill) {
    DBusMessageIter e;
    dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, nullptr, &e);
    put_str(&e, key);
    variant(&e, sig, fill);
    dbus_message_iter_close_container(dict, &e);
}

/// dbusmenu labels treat '_' as a mnemonic marker.
std::string menu_label(const std::string& s) {
    std::string o;
    for (char c : s) { if (c == '_') o += '_'; o += c; }
    return o;
}

class LinuxTray : public Tray {
public:
    explicit LinuxTray(TrayModel model) : m_(std::move(model)) {}

    ~LinuxTray() override {
        running_ = false;
        if (thread_.joinable()) thread_.join();
        if (conn_) {
            dbus_connection_close(conn_);
            dbus_connection_unref(conn_);
        }
    }

    bool init() {
        DBusError err;
        dbus_error_init(&err);
        conn_ = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
        if (!conn_) {
            std::cerr << "[UI] No session bus for the tray icon: " << (err.message ? err.message : "") << "\n";
            dbus_error_free(&err);
            return false;
        }
        dbus_connection_set_exit_on_disconnect(conn_, FALSE);  // never take the host down
        name_ = "org.kde.StatusNotifierItem-" + std::to_string(getpid()) + "-1";
        dbus_bus_request_name(conn_, name_.c_str(), DBUS_NAME_FLAG_DO_NOT_QUEUE, &err);
        if (dbus_error_is_set(&err)) dbus_error_free(&err);
        dbus_bus_add_match(conn_, "type='signal',sender='org.freedesktop.DBus',"
                                  "interface='org.freedesktop.DBus',member='NameOwnerChanged',"
                                  "arg0='org.kde.StatusNotifierWatcher'", nullptr);
        static const DBusObjectPathVTable vt = {nullptr, &LinuxTray::on_message, nullptr, nullptr, nullptr, nullptr};
        dbus_connection_register_object_path(conn_, kItemPath, &vt, this);
        dbus_connection_register_object_path(conn_, kMenuPath, &vt, this);
        dbus_connection_add_filter(conn_, &LinuxTray::on_signal, this, nullptr);
        snapshot(status_, pin_, live_);

        thread_ = std::thread([this] { loop(); });
        // Wait for the watcher's answer, dispatched by the loop (the watcher
        // may query us before it replies, so this thread must not block the
        // connection).
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait_for(lock, std::chrono::seconds(3), [this] { return first_answer_; });
        return true;
    }

    bool visible() const override { return visible_; }

    void pump(std::chrono::milliseconds wait) override { std::this_thread::sleep_for(wait); }

private:
    void snapshot(std::string& status, std::string& pin, bool& live) {
        status = m_.status();
        pin = m_.pin_line();
        live = m_.live();
    }

    void register_with_watcher() {
        DBusMessage* m = dbus_message_new_method_call(kWatcher, "/StatusNotifierWatcher", kWatcher,
                                                      "RegisterStatusNotifierItem");
        const char* n = name_.c_str();
        dbus_message_append_args(m, DBUS_TYPE_STRING, &n, DBUS_TYPE_INVALID);
        if (pending_) { dbus_pending_call_cancel(pending_); dbus_pending_call_unref(pending_); }
        pending_ = nullptr;
        dbus_connection_send_with_reply(conn_, m, &pending_, 3000);
        dbus_message_unref(m);
    }

    void loop() {
        register_with_watcher();
        auto next_check = std::chrono::steady_clock::now();
        while (running_ && dbus_connection_get_is_connected(conn_)) {
            dbus_connection_read_write_dispatch(conn_, 200);
            if (pending_ && dbus_pending_call_get_completed(pending_)) {
                DBusMessage* r = dbus_pending_call_steal_reply(pending_);
                const bool ok = r && dbus_message_get_type(r) == DBUS_MESSAGE_TYPE_METHOD_RETURN;
                if (r) dbus_message_unref(r);
                dbus_pending_call_unref(pending_);
                pending_ = nullptr;
                visible_ = ok;
                std::cout << (ok ? "[UI] Tray icon registered\n"
                                 : "[UI] No StatusNotifierWatcher (on GNOME: enable the AppIndicator extension)\n");
                std::lock_guard<std::mutex> lock(mutex_);
                first_answer_ = true;
                cv_.notify_all();
            }
            if (reregister_) {
                reregister_ = false;
                register_with_watcher();
            }
            if (std::chrono::steady_clock::now() >= next_check) {
                next_check = std::chrono::steady_clock::now() + std::chrono::seconds(1);
                std::string status, pin;
                bool live;
                snapshot(status, pin, live);
                if (status != status_ || pin != pin_) {
                    status_ = status;
                    pin_ = pin;
                    ++revision_;
                    DBusMessage* s = dbus_message_new_signal(kMenuPath, kMenuIface, "LayoutUpdated");
                    const dbus_uint32_t rev = revision_;
                    const dbus_int32_t parent = 0;
                    dbus_message_append_args(s, DBUS_TYPE_UINT32, &rev, DBUS_TYPE_INT32, &parent, DBUS_TYPE_INVALID);
                    dbus_connection_send(conn_, s, nullptr);
                    dbus_message_unref(s);
                    emit(kItemIface, "NewToolTip");
                }
                if (live != live_) {
                    live_ = live;
                    emit(kItemIface, "NewIcon");
                }
            }
        }
    }

    void emit(const char* iface, const char* name) {
        DBusMessage* s = dbus_message_new_signal(kItemPath, iface, name);
        dbus_connection_send(conn_, s, nullptr);
        dbus_message_unref(s);
    }

    static DBusHandlerResult on_signal(DBusConnection*, DBusMessage* m, void* self) {
        if (dbus_message_is_signal(m, "org.freedesktop.DBus", "NameOwnerChanged")) {
            const char *name = nullptr, *old_owner = nullptr, *new_owner = nullptr;
            if (dbus_message_get_args(m, nullptr, DBUS_TYPE_STRING, &name, DBUS_TYPE_STRING, &old_owner,
                                      DBUS_TYPE_STRING, &new_owner, DBUS_TYPE_INVALID) &&
                std::strcmp(name, kWatcher) == 0) {
                auto* t = static_cast<LinuxTray*>(self);
                if (new_owner && *new_owner) t->reregister_ = true;  // e.g. the shell restarted
                else t->visible_ = false;
            }
        }
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    static DBusHandlerResult on_message(DBusConnection*, DBusMessage* m, void* self) {
        return static_cast<LinuxTray*>(self)->handle(m);
    }

    // ---- StatusNotifierItem properties ------------------------------------

    void icon_pixmaps(DBusMessageIter* it) {
        DBusMessageIter arr;
        dbus_message_iter_open_container(it, DBUS_TYPE_ARRAY, "(iiay)", &arr);
        for (int size : {16, 22, 24, 32, 48, 64}) {
            const auto px = tray_icon_pixels(size, kInk, live_);
            std::vector<unsigned char> bytes;
            bytes.reserve(px.size() * 4);
            for (uint32_t p : px)  // ARGB32, network byte order
                for (int sh : {24, 16, 8, 0}) bytes.push_back(static_cast<unsigned char>(p >> sh));
            DBusMessageIter st, ay;
            dbus_message_iter_open_container(&arr, DBUS_TYPE_STRUCT, nullptr, &st);
            const dbus_int32_t w = size;
            dbus_message_iter_append_basic(&st, DBUS_TYPE_INT32, &w);
            dbus_message_iter_append_basic(&st, DBUS_TYPE_INT32, &w);
            dbus_message_iter_open_container(&st, DBUS_TYPE_ARRAY, "y", &ay);
            const unsigned char* data = bytes.data();
            dbus_message_iter_append_fixed_array(&ay, DBUS_TYPE_BYTE, &data, static_cast<int>(bytes.size()));
            dbus_message_iter_close_container(&st, &ay);
            dbus_message_iter_close_container(&arr, &st);
        }
        dbus_message_iter_close_container(it, &arr);
    }

    /// Appends property `name` of `iface` as a variant; false if unknown.
    bool item_property(DBusMessageIter* it, const std::string& iface, const std::string& name) {
        auto str = [&](const std::string& v) { variant(it, "s", [&](DBusMessageIter* x) { put_str(x, v); }); };
        if (iface == kItemIface) {
            if (name == "Category") str("ApplicationStatus");
            else if (name == "Id") str("immersive2");
            else if (name == "Title") str("Immersive-2");
            else if (name == "Status") str("Active");
            else if (name == "IconName" || name == "AttentionIconName" || name == "OverlayIconName" ||
                     name == "IconThemePath" || name == "AttentionMovieName") str("");
            else if (name == "WindowId") {
                variant(it, "i", [](DBusMessageIter* x) { const dbus_int32_t z = 0; dbus_message_iter_append_basic(x, DBUS_TYPE_INT32, &z); });
            } else if (name == "ItemIsMenu") {
                variant(it, "b", [](DBusMessageIter* x) { const dbus_bool_t f = FALSE; dbus_message_iter_append_basic(x, DBUS_TYPE_BOOLEAN, &f); });
            } else if (name == "Menu") {
                variant(it, "o", [](DBusMessageIter* x) { const char* p = kMenuPath; dbus_message_iter_append_basic(x, DBUS_TYPE_OBJECT_PATH, &p); });
            } else if (name == "IconPixmap") {
                variant(it, "a(iiay)", [&](DBusMessageIter* x) { icon_pixmaps(x); });
            } else if (name == "AttentionIconPixmap" || name == "OverlayIconPixmap") {
                variant(it, "a(iiay)", [](DBusMessageIter* x) {
                    DBusMessageIter a;
                    dbus_message_iter_open_container(x, DBUS_TYPE_ARRAY, "(iiay)", &a);
                    dbus_message_iter_close_container(x, &a);
                });
            } else if (name == "ToolTip") {
                variant(it, "(sa(iiay)ss)", [&](DBusMessageIter* x) {
                    DBusMessageIter st, a;
                    dbus_message_iter_open_container(x, DBUS_TYPE_STRUCT, nullptr, &st);
                    put_str(&st, "");
                    dbus_message_iter_open_container(&st, DBUS_TYPE_ARRAY, "(iiay)", &a);
                    dbus_message_iter_close_container(&st, &a);
                    put_str(&st, "Immersive-2");
                    put_str(&st, status_ + "\n" + pin_);
                    dbus_message_iter_close_container(x, &st);
                });
            } else return false;
            return true;
        }
        if (iface == kMenuIface) {
            if (name == "Version") {
                variant(it, "u", [](DBusMessageIter* x) { const dbus_uint32_t v = 3; dbus_message_iter_append_basic(x, DBUS_TYPE_UINT32, &v); });
            } else if (name == "TextDirection") str("ltr");
            else if (name == "Status") str("normal");
            else if (name == "IconThemePath") {
                variant(it, "as", [](DBusMessageIter* x) {
                    DBusMessageIter a;
                    dbus_message_iter_open_container(x, DBUS_TYPE_ARRAY, "s", &a);
                    dbus_message_iter_close_container(x, &a);
                });
            } else return false;
            return true;
        }
        return false;
    }

    // ---- dbusmenu ----------------------------------------------------------

    void item_props(DBusMessageIter* it, int id) {
        DBusMessageIter d;
        dbus_message_iter_open_container(it, DBUS_TYPE_ARRAY, "{sv}", &d);
        auto s = [&](const char* k, const std::string& v) { dict_entry(&d, k, "s", [&](DBusMessageIter* x) { put_str(x, v); }); };
        auto b = [&](const char* k, bool v) {
            dict_entry(&d, k, "b", [&](DBusMessageIter* x) { const dbus_bool_t bv = v; dbus_message_iter_append_basic(x, DBUS_TYPE_BOOLEAN, &bv); });
        };
        switch (id) {
        case kRoot: s("children-display", "submenu"); break;
        case kOpen: s("label", "Open Immersive-2"); break;
        case kStatus: s("label", menu_label(status_)); b("enabled", false); break;
        case kPin: s("label", menu_label(pin_)); b("enabled", false); break;
        case kQuit: s("label", "Quit"); break;
        case kSep1: case kSep2: s("type", "separator"); break;
        }
        dbus_message_iter_close_container(it, &d);
    }

    void layout(DBusMessageIter* it, int id, int depth) {
        DBusMessageIter st, children;
        dbus_message_iter_open_container(it, DBUS_TYPE_STRUCT, nullptr, &st);
        const dbus_int32_t i = id;
        dbus_message_iter_append_basic(&st, DBUS_TYPE_INT32, &i);
        item_props(&st, id);
        dbus_message_iter_open_container(&st, DBUS_TYPE_ARRAY, "v", &children);
        if (id == kRoot && depth != 0) {
            for (int c = kOpen; c <= kQuit; ++c) {
                DBusMessageIter v;
                dbus_message_iter_open_container(&children, DBUS_TYPE_VARIANT, "(ia{sv}av)", &v);
                layout(&v, c, depth - 1);
                dbus_message_iter_close_container(&children, &v);
            }
        }
        dbus_message_iter_close_container(&st, &children);
        dbus_message_iter_close_container(it, &st);
    }

    DBusHandlerResult reply(DBusMessage* r) {
        dbus_connection_send(conn_, r, nullptr);
        dbus_message_unref(r);
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    DBusHandlerResult handle(DBusMessage* m) {
        if (dbus_message_get_type(m) != DBUS_MESSAGE_TYPE_METHOD_CALL) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        const std::string path = dbus_message_get_path(m) ? dbus_message_get_path(m) : "";
        const bool is_menu = path == kMenuPath;
        const char* member = dbus_message_get_member(m);
        const std::string call = member ? member : "";
        const std::string own = is_menu ? kMenuIface : kItemIface;
        DBusMessageIter it;

        if (dbus_message_is_method_call(m, "org.freedesktop.DBus.Introspectable", "Introspect")) {
            DBusMessage* r = dbus_message_new_method_return(m);
            const char* xml = is_menu ? kMenuXml : kItemXml;
            dbus_message_append_args(r, DBUS_TYPE_STRING, &xml, DBUS_TYPE_INVALID);
            return reply(r);
        }
        if (dbus_message_is_method_call(m, kProps, "Get")) {
            const char *iface = nullptr, *name = nullptr;
            if (!dbus_message_get_args(m, nullptr, DBUS_TYPE_STRING, &iface, DBUS_TYPE_STRING, &name, DBUS_TYPE_INVALID))
                return reply(dbus_message_new_error(m, DBUS_ERROR_INVALID_ARGS, "bad args"));
            DBusMessage* r = dbus_message_new_method_return(m);
            dbus_message_iter_init_append(r, &it);
            if (iface != own || !item_property(&it, iface, name)) {
                dbus_message_unref(r);
                return reply(dbus_message_new_error(m, DBUS_ERROR_UNKNOWN_PROPERTY, name));
            }
            return reply(r);
        }
        if (dbus_message_is_method_call(m, kProps, "GetAll")) {
            DBusMessage* r = dbus_message_new_method_return(m);
            dbus_message_iter_init_append(r, &it);
            DBusMessageIter d;
            dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "{sv}", &d);
            const char* names_item[] = {"Category", "Id", "Title", "Status", "WindowId", "IconName",
                                        "IconPixmap", "ToolTip", "ItemIsMenu", "Menu"};
            const char* names_menu[] = {"Version", "TextDirection", "Status", "IconThemePath"};
            auto add = [&](const char* n) {
                DBusMessageIter e;
                dbus_message_iter_open_container(&d, DBUS_TYPE_DICT_ENTRY, nullptr, &e);
                put_str(&e, n);
                item_property(&e, own, n);
                dbus_message_iter_close_container(&d, &e);
            };
            if (is_menu) for (auto n : names_menu) add(n);
            else for (auto n : names_item) add(n);
            dbus_message_iter_close_container(&it, &d);
            return reply(r);
        }

        if (!is_menu) {
            if (call == "Activate" || call == "SecondaryActivate") m_.open();
            if (call == "Activate" || call == "SecondaryActivate" || call == "ContextMenu" || call == "Scroll")
                return reply(dbus_message_new_method_return(m));
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        }

        if (call == "GetLayout") {
            dbus_int32_t parent = 0, depth = -1;
            dbus_message_iter_init(m, &it);
            if (dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_INT32) dbus_message_iter_get_basic(&it, &parent);
            if (dbus_message_iter_next(&it) && dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_INT32)
                dbus_message_iter_get_basic(&it, &depth);
            if (parent < kRoot || parent > kQuit) parent = kRoot;
            DBusMessage* r = dbus_message_new_method_return(m);
            dbus_message_iter_init_append(r, &it);
            const dbus_uint32_t rev = revision_;
            dbus_message_iter_append_basic(&it, DBUS_TYPE_UINT32, &rev);
            layout(&it, parent, depth);
            return reply(r);
        }
        if (call == "GetGroupProperties") {
            std::vector<int> ids;
            dbus_message_iter_init(m, &it);
            if (dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_ARRAY) {
                DBusMessageIter a;
                dbus_message_iter_recurse(&it, &a);
                while (dbus_message_iter_get_arg_type(&a) == DBUS_TYPE_INT32) {
                    dbus_int32_t v;
                    dbus_message_iter_get_basic(&a, &v);
                    if (v >= kRoot && v <= kQuit) ids.push_back(v);
                    dbus_message_iter_next(&a);
                }
            }
            if (ids.empty()) for (int i = kRoot; i <= kQuit; ++i) ids.push_back(i);
            DBusMessage* r = dbus_message_new_method_return(m);
            dbus_message_iter_init_append(r, &it);
            DBusMessageIter arr;
            dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "(ia{sv})", &arr);
            for (int id : ids) {
                DBusMessageIter st;
                dbus_message_iter_open_container(&arr, DBUS_TYPE_STRUCT, nullptr, &st);
                const dbus_int32_t i = id;
                dbus_message_iter_append_basic(&st, DBUS_TYPE_INT32, &i);
                item_props(&st, id);
                dbus_message_iter_close_container(&arr, &st);
            }
            dbus_message_iter_close_container(&it, &arr);
            return reply(r);
        }
        if (call == "Event" || call == "EventGroup") {
            // Event(i id, s event, v data, u time); EventGroup(a(isvu)).
            auto fire = [&](dbus_int32_t id, const char* ev) {
                if (std::strcmp(ev, "clicked") != 0) return;
                if (id == kOpen) m_.open();
                else if (id == kQuit) m_.quit();
            };
            dbus_message_iter_init(m, &it);
            if (call == "Event") {
                dbus_int32_t id = -1;
                const char* ev = "";
                if (dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_INT32) dbus_message_iter_get_basic(&it, &id);
                if (dbus_message_iter_next(&it) && dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_STRING)
                    dbus_message_iter_get_basic(&it, &ev);
                fire(id, ev);
                return reply(dbus_message_new_method_return(m));
            }
            if (dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_ARRAY) {
                DBusMessageIter a, st;
                dbus_message_iter_recurse(&it, &a);
                while (dbus_message_iter_get_arg_type(&a) == DBUS_TYPE_STRUCT) {
                    dbus_message_iter_recurse(&a, &st);
                    dbus_int32_t id = -1;
                    const char* ev = "";
                    dbus_message_iter_get_basic(&st, &id);
                    if (dbus_message_iter_next(&st) && dbus_message_iter_get_arg_type(&st) == DBUS_TYPE_STRING)
                        dbus_message_iter_get_basic(&st, &ev);
                    fire(id, ev);
                    dbus_message_iter_next(&a);
                }
            }
            DBusMessage* r = dbus_message_new_method_return(m);
            dbus_message_iter_init_append(r, &it);
            DBusMessageIter errs;
            dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "i", &errs);
            dbus_message_iter_close_container(&it, &errs);
            return reply(r);
        }
        if (call == "AboutToShow") {
            DBusMessage* r = dbus_message_new_method_return(m);
            const dbus_bool_t no = FALSE;
            dbus_message_append_args(r, DBUS_TYPE_BOOLEAN, &no, DBUS_TYPE_INVALID);
            return reply(r);
        }
        if (call == "AboutToShowGroup") {
            DBusMessage* r = dbus_message_new_method_return(m);
            dbus_message_iter_init_append(r, &it);
            for (int k = 0; k < 2; ++k) {
                DBusMessageIter a;
                dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "i", &a);
                dbus_message_iter_close_container(&it, &a);
            }
            return reply(r);
        }
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    TrayModel m_;
    DBusConnection* conn_ = nullptr;
    DBusPendingCall* pending_ = nullptr;
    std::string name_;
    std::thread thread_;
    std::atomic<bool> running_{true};
    std::atomic<bool> visible_{false};
    std::atomic<bool> reregister_{false};
    std::mutex mutex_;
    std::condition_variable cv_;
    bool first_answer_ = false;
    // Menu state, touched only on the tray thread (after init()).
    std::string status_, pin_;
    bool live_ = false;
    uint32_t revision_ = 1;
};

}  // namespace

std::unique_ptr<Tray> create_tray(TrayModel model) {
    auto t = std::make_unique<LinuxTray>(std::move(model));
    if (!t->init()) return nullptr;
    return t;
}

}  // namespace immersive::ui
