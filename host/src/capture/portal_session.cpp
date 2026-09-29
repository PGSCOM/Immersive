/// xdg-desktop-portal session over libdbus-1, shared by the Wayland capture
/// and input backends (see portal_session.h).
///
/// One private session-bus connection, used only under g_mutex and never
/// from a main loop: signals are read on demand by pump(). The session is a
/// combined RemoteDesktop + ScreenCast one when the RemoteDesktop portal
/// exists (ScreenCast-only otherwise), persisted with a restore token so
/// only the very first run shows the dialog.

#include "capture/portal_session.h"

#include <dbus/dbus.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <mutex>
#include <string>

namespace immersive::portal {

namespace {

using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

constexpr const char* kBus           = "org.freedesktop.portal.Desktop";
constexpr const char* kPath          = "/org/freedesktop/portal/desktop";
constexpr const char* kScreenCast    = "org.freedesktop.portal.ScreenCast";
constexpr const char* kRemoteDesktop = "org.freedesktop.portal.RemoteDesktop";
constexpr const char* kRequest       = "org.freedesktop.portal.Request";
constexpr const char* kSession       = "org.freedesktop.portal.Session";

constexpr int  kCallTimeoutMs = 30000;          // one method call
constexpr auto kRequestTimeout = 30s;           // a Response without dialog
constexpr auto kDialogTimeout  = std::chrono::minutes(3);  // Start (dialog)

enum class Result { kOk, kCancelled, kFailed };

// Connection and session state, all guarded by g_mutex. It is a timed mutex
// because Start holds it while the user looks at the dialog: callers that
// must not stall (input, the PipeWire thread) give up after a short wait.
std::timed_mutex  g_mutex;
DBusConnection*   g_conn = nullptr;
std::string       g_sender;       // unique bus name as it appears in request paths
uint64_t          g_counter = 0;  // handle_token / session_handle_token suffix
std::string       g_session;      // session object path, empty = none
Snapshot          g_state;
uint64_t          g_generations = 0;
Clock::time_point g_next_attempt{};
std::atomic<uint64_t> g_live{0};

// Buffer size per node, set from the PipeWire thread: own lock, see header.
std::mutex g_frame_mutex;
std::map<uint32_t, std::pair<uint32_t, uint32_t>> g_frame_sizes;

// ---- small libdbus helpers -------------------------------------------------

DBusMessage* new_call(const char* iface, const char* method) {
    return dbus_message_new_method_call(kBus, kPath, iface, method);
}

void add_opt(DBusMessageIter* dict, const char* key, int type, const void* value) {
    const char sig[2] = {static_cast<char>(type), '\0'};
    DBusMessageIter entry, var;
    dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, nullptr, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, sig, &var);
    dbus_message_iter_append_basic(&var, type, value);
    dbus_message_iter_close_container(&entry, &var);
    dbus_message_iter_close_container(dict, &entry);
}
void add_u32(DBusMessageIter* d, const char* key, dbus_uint32_t v) { add_opt(d, key, DBUS_TYPE_UINT32, &v); }
void add_bool(DBusMessageIter* d, const char* key, bool v) {
    dbus_bool_t b = v ? TRUE : FALSE;
    add_opt(d, key, DBUS_TYPE_BOOLEAN, &b);
}
void add_str(DBusMessageIter* d, const char* key, const std::string& v) {
    const char* s = v.c_str();
    add_opt(d, key, DBUS_TYPE_STRING, &s);
}

/// Appends the session handle (when `with_session`), then an a{sv} filled
/// by `fill`.
void append_args(DBusMessage* m, bool with_session,
                 const std::function<void(DBusMessageIter*)>& fill) {
    DBusMessageIter args, dict;
    dbus_message_iter_init_append(m, &args);
    if (with_session) {
        const char* s = g_session.c_str();
        dbus_message_iter_append_basic(&args, DBUS_TYPE_OBJECT_PATH, &s);
    }
    dbus_message_iter_open_container(&args, DBUS_TYPE_ARRAY, "{sv}", &dict);
    if (fill) fill(&dict);
    dbus_message_iter_close_container(&args, &dict);
}

/// Blocking call; consumes `m`. Returns the reply (caller unrefs) or nullptr.
DBusMessage* call(DBusMessage* m, bool quiet = false) {
    const std::string method = dbus_message_get_member(m);
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply =
        dbus_connection_send_with_reply_and_block(g_conn, m, kCallTimeoutMs, &err);
    dbus_message_unref(m);
    if (!reply && !quiet)
        std::cerr << "[Portal] " << method << " failed: " << err.message << "\n";
    dbus_error_free(&err);
    return reply;
}

/// Queues `m` (consumed) without waiting for any reply.
void send_no_reply(DBusMessage* m) {
    dbus_message_set_no_reply(m, TRUE);
    dbus_connection_send(g_conn, m, nullptr);
    dbus_message_unref(m);
}

/// Positions `value` on the contents of `key` in the a{sv} at `dict`.
bool dict_find(DBusMessageIter* dict, const char* key, DBusMessageIter* value) {
    if (dbus_message_iter_get_arg_type(dict) != DBUS_TYPE_ARRAY) return false;
    DBusMessageIter arr, entry;
    dbus_message_iter_recurse(dict, &arr);
    for (; dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_DICT_ENTRY;
         dbus_message_iter_next(&arr)) {
        dbus_message_iter_recurse(&arr, &entry);
        const char* k = nullptr;
        dbus_message_iter_get_basic(&entry, &k);
        if (k && std::strcmp(k, key) == 0 && dbus_message_iter_next(&entry) &&
            dbus_message_iter_get_arg_type(&entry) == DBUS_TYPE_VARIANT) {
            dbus_message_iter_recurse(&entry, value);
            return true;
        }
    }
    return false;
}

/// `key` in the results a{sv} of a Response (u response, a{sv} results).
bool result_find(DBusMessage* response, const char* key, DBusMessageIter* value) {
    DBusMessageIter it;
    return dbus_message_iter_init(response, &it) && dbus_message_iter_next(&it) &&
           dict_find(&it, key, value);
}

uint32_t get_u32(DBusMessageIter* v) {
    dbus_uint32_t u = 0;
    if (dbus_message_iter_get_arg_type(v) == DBUS_TYPE_UINT32) dbus_message_iter_get_basic(v, &u);
    return u;
}

std::string get_str(DBusMessageIter* v) {
    const int t = dbus_message_iter_get_arg_type(v);
    if (t != DBUS_TYPE_STRING && t != DBUS_TYPE_OBJECT_PATH) return {};
    const char* s = nullptr;
    dbus_message_iter_get_basic(v, &s);
    return s ? s : "";
}

/// (ii) → a, b
void get_pair(DBusMessageIter* v, int32_t* a, int32_t* b) {
    if (dbus_message_iter_get_arg_type(v) != DBUS_TYPE_STRUCT) return;
    DBusMessageIter st;
    dbus_message_iter_recurse(v, &st);
    if (dbus_message_iter_get_arg_type(&st) != DBUS_TYPE_INT32) return;
    dbus_message_iter_get_basic(&st, a);
    if (dbus_message_iter_next(&st) && dbus_message_iter_get_arg_type(&st) == DBUS_TYPE_INT32)
        dbus_message_iter_get_basic(&st, b);
}

uint32_t get_u32_property(const char* iface, const char* prop) {
    DBusMessage* m = dbus_message_new_method_call(kBus, kPath, DBUS_INTERFACE_PROPERTIES, "Get");
    dbus_message_append_args(m, DBUS_TYPE_STRING, &iface, DBUS_TYPE_STRING, &prop,
                             DBUS_TYPE_INVALID);
    DBusMessage* r = call(m, /*quiet=*/true);  // missing interface = 0
    if (!r) return 0;
    uint32_t value = 0;
    DBusMessageIter it, var;
    if (dbus_message_iter_init(r, &it) &&
        dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_VARIANT) {
        dbus_message_iter_recurse(&it, &var);
        value = get_u32(&var);
    }
    dbus_message_unref(r);
    return value;
}

// ---- session state ----------------------------------------------------------

void drop_session(const char* why) {
    if (!g_session.empty() && why)
        std::cerr << "[Portal] Screen-sharing session ended: " << why << "\n";
    g_session.clear();
    g_state = {};
    g_live = 0;
}

/// Asks the portal to close our session (if any) and forgets it.
void close_session() {
    if (!g_session.empty() && g_conn && dbus_connection_get_is_connected(g_conn)) {
        DBusMessage* m = dbus_message_new_method_call(kBus, g_session.c_str(), kSession, "Close");
        send_no_reply(m);
        dbus_connection_flush(g_conn);
    }
    drop_session(nullptr);
}

void handle_message(DBusMessage* m) {
    // Only a started session can end: while one is being created its calls
    // simply fail, and g_session must stay a valid path until they return.
    if (!g_live) return;
    if (dbus_message_is_signal(m, kSession, "Closed")) {
        const char* path = dbus_message_get_path(m);
        if (path && g_session == path) drop_session("closed by the desktop (sharing stopped?)");
    } else if (dbus_message_is_signal(m, DBUS_INTERFACE_DBUS, "NameOwnerChanged")) {
        drop_session("the portal service restarted");  // match rule filters arg0
    } else if (dbus_message_is_signal(m, DBUS_INTERFACE_LOCAL, "Disconnected")) {
        drop_session("lost the D-Bus session bus");
    }
}

/// Handles queued/incoming messages, waiting up to `timeout_ms` for input.
/// Returns (without handling) the first message `want` accepts, if any.
DBusMessage* pump(int timeout_ms, const std::function<bool(DBusMessage*)>& want = nullptr) {
    for (int pass = 0; pass < 2; ++pass) {
        while (DBusMessage* m = dbus_connection_pop_message(g_conn)) {
            if (want && want(m)) return m;
            handle_message(m);
            dbus_message_unref(m);
        }
        if (pass == 0 && !dbus_connection_read_write(g_conn, timeout_ms)) break;
    }
    return nullptr;
}

bool connect_bus() {
    if (g_conn && dbus_connection_get_is_connected(g_conn)) return true;
    if (g_conn) {
        drop_session("lost the D-Bus session bus");
        dbus_connection_close(g_conn);
        dbus_connection_unref(g_conn);
        g_conn = nullptr;
    }
    static std::once_flag threads_once;
    std::call_once(threads_once, [] { dbus_threads_init_default(); });

    DBusError err;
    dbus_error_init(&err);
    DBusConnection* c = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
    if (!c) {
        std::cerr << "[Portal] Cannot connect to the D-Bus session bus: " << err.message << "\n";
        dbus_error_free(&err);
        return false;
    }
    dbus_connection_set_exit_on_disconnect(c, FALSE);

    // Request paths use the unique name without ':' and with '.' → '_'.
    g_sender = dbus_bus_get_unique_name(c) + 1;
    for (char& ch : g_sender) if (ch == '.') ch = '_';

    // Subscribed once, before any call: a Response can never be missed.
    const std::string rules[] = {
        "type='signal',interface='" + std::string(kRequest) + "',member='Response',"
        "path_namespace='/org/freedesktop/portal/desktop/request/" + g_sender + "'",
        "type='signal',interface='" + std::string(kSession) + "',member='Closed'",
        "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',"
        "member='NameOwnerChanged',arg0='" + std::string(kBus) + "'",
    };
    for (const auto& rule : rules) {
        dbus_bus_add_match(c, rule.c_str(), &err);
        if (dbus_error_is_set(&err)) {
            std::cerr << "[Portal] D-Bus match rule failed: " << err.message << "\n";
            dbus_error_free(&err);
            dbus_connection_close(c);
            dbus_connection_unref(c);
            return false;
        }
    }
    g_conn = c;
    return true;
}

/// Calls a portal method that answers through a Request object and waits
/// for its Response. Returns it (caller unrefs) when the response code is 0;
/// otherwise nullptr with `*result` = kCancelled (user said no / timeout) or
/// kFailed.
DBusMessage* request(const char* iface, const char* method, bool with_session,
                     bool with_parent_window,
                     const std::function<void(DBusMessageIter*)>& fill,
                     Clock::duration timeout, Result* result) {
    *result = Result::kFailed;
    const std::string token = "immersive2_" + std::to_string(++g_counter);
    const std::string predicted =
        "/org/freedesktop/portal/desktop/request/" + g_sender + "/" + token;

    DBusMessage* m = new_call(iface, method);
    DBusMessageIter args;
    dbus_message_iter_init_append(m, &args);
    if (with_session) {
        const char* s = g_session.c_str();
        dbus_message_iter_append_basic(&args, DBUS_TYPE_OBJECT_PATH, &s);
    }
    if (with_parent_window) {
        const char* parent = "";
        dbus_message_iter_append_basic(&args, DBUS_TYPE_STRING, &parent);
    }
    DBusMessageIter dict;
    dbus_message_iter_open_container(&args, DBUS_TYPE_ARRAY, "{sv}", &dict);
    add_str(&dict, "handle_token", token);
    if (fill) fill(&dict);
    dbus_message_iter_close_container(&args, &dict);

    DBusMessage* reply = call(m);
    if (!reply) return nullptr;
    std::string handle;  // older portals may not use the predicted path
    const char* h = nullptr;
    if (dbus_message_get_args(reply, nullptr, DBUS_TYPE_OBJECT_PATH, &h, DBUS_TYPE_INVALID))
        handle = h;
    dbus_message_unref(reply);

    auto is_response = [&](DBusMessage* msg) {
        const char* p = dbus_message_get_path(msg);
        return dbus_message_is_signal(msg, kRequest, "Response") && p &&
               (predicted == p || handle == p);
    };
    const auto deadline = Clock::now() + timeout;
    while (dbus_connection_get_is_connected(g_conn) && Clock::now() < deadline) {
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - Clock::now()).count();
        DBusMessage* r = pump(static_cast<int>(std::clamp<long long>(left, 1, 500)), is_response);
        if (!r) continue;
        DBusMessageIter it;
        dbus_uint32_t code = 2;
        if (dbus_message_iter_init(r, &it)) code = get_u32(&it);
        if (code == 0) {
            *result = Result::kOk;
            return r;
        }
        dbus_message_unref(r);
        if (code == 1) {
            *result = Result::kCancelled;
            std::cerr << "[Portal] " << method << ": the request was cancelled on the desktop\n";
        } else {
            std::cerr << "[Portal] " << method << " failed (response " << code << ")\n";
        }
        return nullptr;
    }
    std::cerr << "[Portal] " << method << ": no answer in time, giving up\n";
    if (!handle.empty() && dbus_connection_get_is_connected(g_conn)) {
        // Close the request so a dialog nobody answered goes away.
        send_no_reply(dbus_message_new_method_call(kBus, handle.c_str(), kRequest, "Close"));
        dbus_connection_flush(g_conn);
    }
    *result = Result::kCancelled;
    return nullptr;
}

std::filesystem::path token_path() {
    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    const char* home = std::getenv("HOME");
    std::filesystem::path base = (xdg && *xdg) ? std::filesystem::path(xdg)
                                               : std::filesystem::path(home ? home : ".") / ".config";
    return base / "immersive2" / "portal-restore-token";
}

std::string load_token() {
    std::ifstream f(token_path());
    std::string token;
    std::getline(f, token);
    return token;
}

void save_token(const std::string& token) {
    const auto path = token_path();
    std::error_code ec;
    std::filesystem::create_directories(path.parent_path(), ec);
    {
        std::ofstream f(path, std::ios::trunc);
        f << token << "\n";
        if (!f) {
            std::cerr << "[Portal] Cannot save the restore token to " << path
                      << ": the dialog will show again next time\n";
            return;
        }
    }
    std::filesystem::permissions(path, std::filesystem::perms::owner_read |
                                       std::filesystem::perms::owner_write,
                                 std::filesystem::perm_options::replace, ec);
}

/// One attempt at CreateSession → Select* → Start. `rd` = combined
/// RemoteDesktop + ScreenCast session, else ScreenCast only.
Result try_session(bool rd, const std::string& token, uint32_t rd_version,
                   uint32_t sc_version, uint32_t cursor_modes) {
    const char* iface = rd ? kRemoteDesktop : kScreenCast;
    Result result;

    const std::string session_token = "immersive2_s" + std::to_string(++g_counter);
    DBusMessage* r = request(iface, "CreateSession", false, false, [&](DBusMessageIter* d) {
        add_str(d, "session_handle_token", session_token);
    }, kRequestTimeout, &result);
    if (!r) return result;
    DBusMessageIter v;
    g_session = result_find(r, "session_handle", &v) ? get_str(&v) : "";
    dbus_message_unref(r);
    if (g_session.empty()) {
        std::cerr << "[Portal] CreateSession returned no session handle\n";
        return Result::kFailed;
    }

    // Persistence: for a RemoteDesktop session it belongs on SelectDevices
    // (RemoteDesktop v2+) and SelectSources must not carry it, the portal
    // rejects that ("Remote desktop sessions cannot persist"). A plain
    // ScreenCast session persists on SelectSources (ScreenCast v4+).
    auto add_persist = [&](DBusMessageIter* d) {
        add_u32(d, "persist_mode", 2);  // until explicitly revoked
        if (!token.empty()) add_str(d, "restore_token", token);
    };
    if (rd) {
        r = request(kRemoteDesktop, "SelectDevices", true, false, [&](DBusMessageIter* d) {
            add_u32(d, "types", 1 | 2);  // KEYBOARD | POINTER
            if (rd_version >= 2) add_persist(d);
        }, kRequestTimeout, &result);
        if (!r) { close_session(); return result; }
        dbus_message_unref(r);
    }
    r = request(kScreenCast, "SelectSources", true, false, [&](DBusMessageIter* d) {
        add_u32(d, "types", 1);  // MONITOR
        add_bool(d, "multiple", true);
        if (cursor_modes & 2) add_u32(d, "cursor_mode", 2);  // EMBEDDED in the frames
        if (!rd && sc_version >= 4) add_persist(d);
    }, kRequestTimeout, &result);
    if (!r) { close_session(); return result; }
    dbus_message_unref(r);

    if (token.empty()) {
        std::cout << "[Portal] >>> Accept the screen-sharing dialog on this desktop: select the\n"
                  << "[Portal] >>> monitor(s) to show in VR" << (rd ? " and allow remote control" : "")
                  << ". Waiting up to 3 min...\n";
    } else {
        std::cout << "[Portal] Restoring the previous screen-sharing session "
                  << "(a dialog shows only if it cannot be restored)...\n";
    }
    std::cout.flush();
    r = request(iface, "Start", true, true, nullptr, kDialogTimeout, &result);
    if (!r) { close_session(); return result; }

    Snapshot state;
    if (result_find(r, "streams", &v) && dbus_message_iter_get_arg_type(&v) == DBUS_TYPE_ARRAY) {
        DBusMessageIter arr, st, prop;
        dbus_message_iter_recurse(&v, &arr);
        for (; dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_STRUCT;
             dbus_message_iter_next(&arr)) {
            dbus_message_iter_recurse(&arr, &st);  // (u node_id, a{sv} properties)
            Stream s{};
            s.node_id = get_u32(&st);
            if (!dbus_message_iter_next(&st)) continue;
            if (dict_find(&st, "position", &prop)) get_pair(&prop, &s.x, &s.y);
            if (dict_find(&st, "size", &prop)) get_pair(&prop, &s.width, &s.height);
            state.streams.push_back(s);
        }
    }
    const uint32_t devices = (rd && result_find(r, "devices", &v)) ? get_u32(&v) : 0;
    const std::string new_token = result_find(r, "restore_token", &v) ? get_str(&v) : "";
    dbus_message_unref(r);

    if (state.streams.empty()) {
        std::cerr << "[Portal] No monitor was shared\n";
        close_session();
        return Result::kFailed;
    }
    // Tokens are single-use: always keep the newest one.
    if (!new_token.empty()) save_token(new_token);

    state.generation     = ++g_generations;
    state.remote_desktop = (devices & 3) != 0;
    g_state = state;
    g_live  = state.generation;
    {
        std::lock_guard<std::mutex> lock(g_frame_mutex);
        g_frame_sizes.clear();  // node ids of the old session mean nothing now
    }
    std::cout << "[Portal] Sharing " << state.streams.size() << " monitor(s)"
              << (state.remote_desktop ? " with remote input" : ", VR input disabled")
              << (new_token.empty() ? " (not persisted: the dialog will show again)" : "")
              << "\n";
    return Result::kOk;
}

/// Sends a RemoteDesktop Notify* call built by `append` (which returns false
/// to drop the event). Never waits for a reply; bounded by short waits.
void notify(const char* method, const std::function<bool(DBusMessageIter*)>& append) {
    std::unique_lock<std::timed_mutex> lock(g_mutex, 50ms);
    if (!lock || !g_conn || !g_live || !g_state.remote_desktop) return;
    DBusMessage* m = new_call(kRemoteDesktop, method);
    append_args(m, true, nullptr);  // session, empty options
    DBusMessageIter args;
    dbus_message_iter_init_append(m, &args);
    if (!append(&args)) {
        dbus_message_unref(m);
        return;
    }
    send_no_reply(m);
    pump(0);  // writes what the socket takes, handles e.g. a Closed signal
    for (int i = 0; i < 4 && g_conn && dbus_connection_has_messages_to_send(g_conn); ++i)
        dbus_connection_read_write(g_conn, 5);
}

}  // namespace

Snapshot ensure_session() {
    std::unique_lock<std::timed_mutex> lock(g_mutex, 1s);
    if (!lock) return {};  // another thread is creating it (dialog open)
    if (g_conn && dbus_connection_get_is_connected(g_conn)) pump(0);
    if (g_live) return g_state;
    if (Clock::now() < g_next_attempt) return {};
    g_next_attempt = Clock::now() + 5s;
    if (!connect_bus()) return {};

    const uint32_t rd_version   = get_u32_property(kRemoteDesktop, "version");
    const uint32_t sc_version   = get_u32_property(kScreenCast, "version");
    const uint32_t cursor_modes = get_u32_property(kScreenCast, "AvailableCursorModes");
    if (sc_version == 0) {
        std::cerr << "[Portal] No ScreenCast portal (install xdg-desktop-portal and the\n"
                  << "         backend for your desktop, e.g. xdg-desktop-portal-gnome/-kde/-wlr)\n";
        return {};
    }
    const bool rd = rd_version > 0;
    if (!rd) std::cerr << "[Portal] No RemoteDesktop portal: capture only, VR input disabled\n";
    else if (rd_version < 2)
        std::cerr << "[Portal] RemoteDesktop portal v1 cannot persist: the dialog shows every run\n";

    const std::string token = load_token();
    Result r = try_session(rd, token, rd_version, sc_version, cursor_modes);
    if (r == Result::kFailed && !token.empty()) {
        std::cerr << "[Portal] Stored restore token not accepted, asking again\n";
        r = try_session(rd, "", rd_version, sc_version, cursor_modes);
    }
    if (r == Result::kFailed && rd) {
        std::cerr << "[Portal] RemoteDesktop session failed: falling back to capture only, "
                     "VR input disabled\n";
        r = try_session(false, "", rd_version, sc_version, cursor_modes);
    }
    if (r != Result::kOk) {
        // Do not pester the user with the dialog again right away.
        g_next_attempt = Clock::now() + (r == Result::kCancelled ? 30s : 5s);
        return {};
    }
    return g_state;
}

uint64_t live_generation() { return g_live.load(); }

int open_pipewire_remote(uint64_t gen) {
    std::unique_lock<std::timed_mutex> lock(g_mutex, 1s);
    if (!lock || !g_conn) return -1;
    pump(0);
    if (!g_live || g_state.generation != gen) return -1;
    DBusMessage* m = new_call(kScreenCast, "OpenPipeWireRemote");
    append_args(m, true, nullptr);
    DBusMessage* r = call(m);
    int fd = -1;  // libdbus hands us our own dup
    if (r) {
        if (!dbus_message_get_args(r, nullptr, DBUS_TYPE_UNIX_FD, &fd, DBUS_TYPE_INVALID)) fd = -1;
        dbus_message_unref(r);
    }
    return fd;
}

void invalidate(uint64_t gen) {
    std::unique_lock<std::timed_mutex> lock(g_mutex, 1s);
    if (!lock || !g_live || g_state.generation != gen) return;
    std::cerr << "[Portal] Session streams keep failing, starting a new session\n";
    close_session();
}

void set_frame_size(uint32_t node_id, uint32_t w, uint32_t h) {
    std::lock_guard<std::mutex> lock(g_frame_mutex);
    g_frame_sizes[node_id] = {w, h};
}

// Mutter maps the absolute position through the stream's *buffer* pixels
// (meta_screen_cast_monitor_stream_transform_position divides by the
// monitor scale), which differ from the logical `size` on a scaled monitor.
// So the fraction is applied to the negotiated buffer size, falling back to
// the logical size before the stream has been captured.
void pointer_motion(uint8_t index, double fx, double fy) {
    notify("NotifyPointerMotionAbsolute", [&](DBusMessageIter* args) {
        if (index >= g_state.streams.size()) return false;
        const Stream& s = g_state.streams[index];
        double w = s.width, h = s.height;
        {
            std::lock_guard<std::mutex> lock(g_frame_mutex);
            auto it = g_frame_sizes.find(s.node_id);
            if (it != g_frame_sizes.end()) { w = it->second.first; h = it->second.second; }
        }
        if (w <= 0 || h <= 0) return false;
        const dbus_uint32_t node = s.node_id;
        const double x = fx * w, y = fy * h;
        dbus_message_iter_append_basic(args, DBUS_TYPE_UINT32, &node);
        dbus_message_iter_append_basic(args, DBUS_TYPE_DOUBLE, &x);
        dbus_message_iter_append_basic(args, DBUS_TYPE_DOUBLE, &y);
        return true;
    });
}

void pointer_button(int32_t evdev_button, bool pressed) {
    notify("NotifyPointerButton", [&](DBusMessageIter* args) {
        const dbus_int32_t b = evdev_button;
        const dbus_uint32_t state = pressed ? 1 : 0;
        dbus_message_iter_append_basic(args, DBUS_TYPE_INT32, &b);
        dbus_message_iter_append_basic(args, DBUS_TYPE_UINT32, &state);
        return true;
    });
}

void pointer_axis_discrete(uint32_t axis, int32_t steps) {
    notify("NotifyPointerAxisDiscrete", [&](DBusMessageIter* args) {
        const dbus_uint32_t a = axis;
        const dbus_int32_t n = steps;
        dbus_message_iter_append_basic(args, DBUS_TYPE_UINT32, &a);
        dbus_message_iter_append_basic(args, DBUS_TYPE_INT32, &n);
        return true;
    });
}

void keyboard_keysym(int32_t keysym, bool pressed) {
    notify("NotifyKeyboardKeysym", [&](DBusMessageIter* args) {
        const dbus_int32_t k = keysym;
        const dbus_uint32_t state = pressed ? 1 : 0;
        dbus_message_iter_append_basic(args, DBUS_TYPE_INT32, &k);
        dbus_message_iter_append_basic(args, DBUS_TYPE_UINT32, &state);
        return true;
    });
}

}  // namespace immersive::portal
