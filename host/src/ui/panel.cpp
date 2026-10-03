/// The settings panel: a tiny HTTP server on 127.0.0.1 serving one page
/// (panel.html, compiled in) and a JSON API, plus the tray that opens it.
///
/// Security. Every web page the user opens can send requests to 127.0.0.1,
/// so, like web/bridge/bridge.js:
///  - it listens on the loopback interface only;
///  - a random token is made per run; the host opens /?token=..., which sets
///    an HttpOnly SameSite=Strict cookie (named per port: cookies are not
///    port-isolated) and redirects to /; every request needs that cookie;
///  - the Host header must name this panel (DNS rebinding), a present Origin
///    must be this panel, and POSTs need both Origin and an X-Im2-Panel
///    header (a cross-site form cannot send one; fetch would need a CORS
///    preflight this server never grants);
///  - no-store, frame-ancestors 'none', nosniff.

#include "ui/host_ui.h"
#include "panel_assets.h"  // generated: kPanelHtml, kPanelFont (see CMakeLists.txt)

#if defined(IMMERSIVE_HAVE_PORTAL)
#include "capture/portal_session.h"
#endif

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <mutex>
#include <random>
#include <sstream>
#include <thread>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
using Sock = SOCKET;
constexpr Sock kBadSock = INVALID_SOCKET;
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
using Sock = int;
constexpr Sock kBadSock = -1;
#endif

namespace immersive::ui {

namespace {

#ifndef _WIN32
void closesocket(int s) { close(s); }
#endif

/// Keep panel sockets out of child processes (adb's daemon, the browser):
/// an inherited listener would keep the panel port bound after we exit.
void no_inherit(Sock s) {
#ifdef _WIN32
    SetHandleInformation(reinterpret_cast<HANDLE>(s), HANDLE_FLAG_INHERIT, 0);
#else
    fcntl(s, F_SETFD, FD_CLOEXEC);
#endif
}

constexpr const char* kCodecNames[] = {"h264", "h265", "mjpeg", "av1"};

std::string json_str(const std::string& s) {
    std::string o = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') { o += '\\'; o += static_cast<char>(c); }
        else if (c < 0x20) { char b[8]; std::snprintf(b, sizeof(b), "\\u%04x", c); o += b; }
        else o += static_cast<char>(c);
    }
    return o + "\"";
}

std::string lower(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

std::string url_decode(const std::string& s) {
    std::string o;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '+') o += ' ';
        else if (s[i] == '%' && i + 2 < s.size() && std::isxdigit(static_cast<unsigned char>(s[i + 1])) &&
                 std::isxdigit(static_cast<unsigned char>(s[i + 2]))) {
            o += static_cast<char>(std::stoi(s.substr(i + 1, 2), nullptr, 16));
            i += 2;
        } else o += s[i];
    }
    return o;
}

std::map<std::string, std::string> parse_form(const std::string& s) {
    std::map<std::string, std::string> out;
    std::istringstream in(s);
    std::string pair;
    while (std::getline(in, pair, '&')) {
        const auto eq = pair.find('=');
        out[url_decode(pair.substr(0, eq))] = eq == std::string::npos ? "" : url_decode(pair.substr(eq + 1));
    }
    return out;
}

bool same_secret(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) return false;
    unsigned char diff = 0;
    for (size_t i = 0; i < a.size(); ++i) diff |= static_cast<unsigned char>(a[i] ^ b[i]);
    return diff == 0;
}

std::string random_token() {
    std::random_device rd;
    std::string t;
    const char* hex = "0123456789abcdef";
    for (int i = 0; i < 32; ++i) t += hex[rd() & 15];
    return t;
}

struct Request {
    std::string method, path, query, body;
    std::map<std::string, std::string> headers;  // lower-case names
};

struct Response {
    int status = 200;
    std::string type = "application/json";
    std::string body;
    std::vector<std::string> extra;  // "Name: value"
};

bool recv_request(Sock s, Request& r) {
    std::string buf;
    char chunk[2048];
    size_t head_end;
    while ((head_end = buf.find("\r\n\r\n")) == std::string::npos) {
        if (buf.size() > 16384) return false;
        const int n = recv(s, chunk, sizeof(chunk), 0);
        if (n <= 0) return false;
        buf.append(chunk, static_cast<size_t>(n));
    }
    std::istringstream head(buf.substr(0, head_end));
    std::string line, target, version;
    std::getline(head, line);
    std::istringstream(line) >> r.method >> target >> version;
    const auto q = target.find('?');
    r.path = target.substr(0, q);
    r.query = q == std::string::npos ? "" : target.substr(q + 1);
    while (std::getline(head, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const auto colon = line.find(':');
        if (colon == std::string::npos) continue;
        std::string v = line.substr(colon + 1);
        v.erase(0, v.find_first_not_of(" \t"));
        r.headers[lower(line.substr(0, colon))] = v;
    }
    const size_t len = std::strtoul(r.headers.count("content-length")
                                        ? r.headers["content-length"].c_str() : "0", nullptr, 10);
    if (len > 4096) return false;
    r.body = buf.substr(head_end + 4);
    while (r.body.size() < len) {
        const int n = recv(s, chunk, sizeof(chunk), 0);
        if (n <= 0) return false;
        r.body.append(chunk, static_cast<size_t>(n));
    }
    r.body.resize(len);
    return true;
}

void send_all(Sock s, const std::string& data) {
    size_t off = 0;
    while (off < data.size()) {
        const int n = send(s, data.data() + off, static_cast<int>(data.size() - off), 0);
        if (n <= 0) return;
        off += static_cast<size_t>(n);
    }
}

const char* reason(int status) {
    switch (status) {
    case 200: return "OK";
    case 303: return "See Other";
    case 400: return "Bad Request";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    default:  return "Error";
    }
}

class Panel : public HostUi {
public:
    Panel(Settings& settings, INetworkServer& server, Hooks hooks, Options options)
        : s_(settings), server_(server), hooks_(std::move(hooks)), opt_(std::move(options)),
          token_(random_token()) {}

    ~Panel() override {
        running_ = false;
        tray_.reset();
        if (thread_.joinable()) thread_.join();
        if (listen_ != kBadSock) closesocket(listen_);
        std::error_code ec;
        std::filesystem::remove(opt_.config_dir / "panel-url", ec);
#ifdef _WIN32
        WSACleanup();
#endif
    }

    bool listen() {
#ifdef _WIN32
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;
#endif
        for (uint16_t port : {opt_.panel_port, static_cast<uint16_t>(0)}) {
            listen_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            if (listen_ == kBadSock) return false;
            no_inherit(listen_);
            sockaddr_in a{};
            a.sin_family = AF_INET;
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // never any other interface
            a.sin_port = htons(port);
            if (bind(listen_, reinterpret_cast<sockaddr*>(&a), sizeof(a)) == 0 &&
                ::listen(listen_, 8) == 0) {
                socklen_t len = sizeof(a);
                getsockname(listen_, reinterpret_cast<sockaddr*>(&a), &len);
                port_ = ntohs(a.sin_port);
                break;
            }
            closesocket(listen_);
            listen_ = kBadSock;
        }
        if (listen_ == kBadSock) return false;
        origin_ = "http://127.0.0.1:" + std::to_string(port_);
        cookie_name_ = "im2panel_" + std::to_string(port_);

        // For a second launch of the host (open_running_instance). Private:
        // the token in it is the key to this panel.
        std::error_code ec;
        std::filesystem::create_directories(opt_.config_dir, ec);
        const auto file = opt_.config_dir / "panel-url";
        std::ofstream(file, std::ios::trunc) << url() << "\n";
        std::filesystem::permissions(file, std::filesystem::perms::owner_read |
                                           std::filesystem::perms::owner_write,
                                     std::filesystem::perm_options::replace, ec);
        thread_ = std::thread([this] { serve(); });
        return true;
    }

    void start_tray() {
        TrayModel m;
        m.status = [this] { return status_line(); };
        m.pin_line = [this] {
            if (!s_.pin_enabled) return std::string("PIN off");
            const std::string p = std::to_string(s_.pin.load());
            return "PIN " + p.substr(0, 3) + " " + p.substr(3);
        };
        m.live = [this] { uint32_t c = 0; return !hooks_.streams(c).empty(); };
        m.open = [this] { open_app_window(url()); };
        m.quit = hooks_.quit;
        tray_ = create_tray(std::move(m));
        if (!tray_ || !tray_->visible()) {
            std::cout << "[UI] No tray on this desktop: opening the settings window\n";
            open_app_window(url());
        }
    }

    void pump(std::chrono::milliseconds wait) override {
        if (tray_) tray_->pump(wait);
        else std::this_thread::sleep_for(wait);
    }

    std::string url() const override { return origin_ + "/?token=" + token_; }

private:
    std::string status_line() {
        uint32_t streaming = 0;
        hooks_.streams(streaming);
        const auto list = server_.clients();
        for (const auto& c : list)
            if (c.id == streaming) return "Streaming to " + (c.name.empty() ? c.address : c.name);
        if (list.size() == 1) return "1 headset connected";
        if (!list.empty()) return std::to_string(list.size()) + " headsets connected";
        return "Waiting for a headset";
    }

    void serve() {
        while (running_) {
            fd_set rd;
            FD_ZERO(&rd);
            FD_SET(listen_, &rd);
            timeval tv{0, 200000};
            if (select(static_cast<int>(listen_) + 1, &rd, nullptr, nullptr, &tv) <= 0) continue;
            Sock c = accept(listen_, nullptr, nullptr);
            if (c == kBadSock) continue;
            no_inherit(c);
#ifdef _WIN32
            DWORD ms = 2000;
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&ms), sizeof(ms));
#else
            timeval to{2, 0};
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &to, sizeof(to));
#endif
            Request req;
            if (recv_request(c, req)) {
                Response res = handle(req);
                std::ostringstream out;
                out << "HTTP/1.1 " << res.status << " " << reason(res.status) << "\r\n"
                    << "Content-Type: " << res.type << "\r\n"
                    << "Content-Length: " << res.body.size() << "\r\n"
                    << "Cache-Control: no-store\r\n"
                    << "X-Content-Type-Options: nosniff\r\n"
                    << "X-Frame-Options: DENY\r\n"
                    << "Referrer-Policy: no-referrer\r\n"
                    << "Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; "
                       "style-src 'unsafe-inline'; font-src 'self'; img-src 'self' data:; "
                       "frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n"
                    << "Connection: close\r\n";
                for (const auto& h : res.extra) out << h << "\r\n";
                out << "\r\n";
                if (req.method != "HEAD") out << res.body;
                send_all(c, out.str());
            }
            closesocket(c);
        }
    }

    static Response text(int status, const std::string& msg) {
        Response r;
        r.status = status;
        r.type = "text/plain; charset=utf-8";
        r.body = msg + "\n";
        return r;
    }

    Response handle(const Request& req) {
        auto header = [&](const char* name) {
            auto it = req.headers.find(name);
            return it == req.headers.end() ? std::string() : it->second;
        };
        // DNS rebinding: a hostile name resolving to 127.0.0.1 still says so.
        const std::string host = header("host");
        const std::string port = ":" + std::to_string(port_);
        if (host != "127.0.0.1" + port && host != "localhost" + port)
            return text(403, "Immersive-2: wrong Host");
        const std::string origin = header("origin");
        const bool origin_ok = origin == origin_ || origin == "http://localhost" + port;
        if (!origin.empty() && !origin_ok) return text(403, "Immersive-2: cross-site request refused");
        if (req.method == "POST" && (!origin_ok || header("x-im2-panel") != "1"))
            return text(403, "Immersive-2: cross-site request refused");
        if (req.method != "GET" && req.method != "HEAD" && req.method != "POST")
            return text(405, "Immersive-2: method not allowed");

        const auto query = parse_form(req.query);
        if (req.path == "/" && query.count("token")) {
            if (!same_secret(query.at("token"), token_))
                return text(403, "Immersive-2: this link is from an earlier run. Open the panel "
                                 "from the Immersive-2 icon.");
            Response r = text(303, "");
            r.extra.push_back("Set-Cookie: " + cookie_name_ + "=" + token_ +
                              "; Path=/; HttpOnly; SameSite=Strict");
            r.extra.push_back("Location: /");
            return r;
        }
        if (!authorized(header("cookie")))
            return text(403, "Immersive-2: open the settings from the Immersive-2 icon on this PC.");

        if (req.method != "POST") {
            if (req.path == "/") {
                Response r;
                r.type = "text/html; charset=utf-8";
                r.body.assign(reinterpret_cast<const char*>(kPanelHtml), sizeof(kPanelHtml));
                return r;
            }
            if (req.path == "/grotesk.woff2") {
                Response r;
                r.type = "font/woff2";
                r.body.assign(reinterpret_cast<const char*>(kPanelFont), sizeof(kPanelFont));
                return r;
            }
            if (req.path == "/api/state") {
                Response r;
                r.body = state_json();
                return r;
            }
            return text(404, "Immersive-2: not found");
        }
        const auto form = parse_form(req.body);
        auto arg = [&](const char* k) {
            auto it = form.find(k);
            return it == form.end() ? std::string() : it->second;
        };
        std::string error = act(req.path, arg);
        Response r;
        if (!error.empty()) {
            r.status = 400;
            r.body = "{\"error\":" + json_str(error) + "}";
        } else {
            r.body = state_json();
        }
        return r;
    }

    bool authorized(const std::string& cookies) const {
        std::istringstream in(cookies);
        std::string part;
        while (std::getline(in, part, ';')) {
            part.erase(0, part.find_first_not_of(' '));
            const auto eq = part.find('=');
            if (eq != std::string::npos && part.substr(0, eq) == cookie_name_ &&
                same_secret(part.substr(eq + 1), token_))
                return true;
        }
        return false;
    }

    uint8_t host_flags() const {
        return (s_.view_only ? protocol::HOST_FLAG_VIEW_ONLY : 0) |
               (opt_.virtual_supported ? protocol::HOST_FLAG_VIRTUAL_DISPLAYS : 0) |
               (opt_.screen_off_supported ? protocol::HOST_FLAG_SCREEN_OFF : 0);
    }

    template <typename Arg>
    std::string act(const std::string& path, Arg arg) {
        const std::string& dir_key = arg("key");
        const bool on = arg("value") == "1" || arg("value") == "on" || arg("value") == "true";
        const auto& dir = opt_.config_dir;
        if (path == "/api/set") {
            const std::string& key = dir_key;
            if (key == "view_only") {
                s_.view_only = on;
                server_.set_host_flags(host_flags());
                save_host_conf_key(dir, key, on ? "on" : "off");
            } else if (key == "pin") {
                if (on && s_.pin < 100000) s_.pin = new_pairing_pin(dir);
                s_.pin_enabled = on;
                server_.set_pin(on ? s_.pin.load() : 0);
                save_host_conf_key(dir, key, on ? "on" : "off");
            } else if (key == "codec") {
                const std::string v = arg("value");
                const auto* it = std::find_if(std::begin(kCodecNames), std::end(kCodecNames),
                                              [&](const char* n) { return v == n; });
                if (it == std::end(kCodecNames)) return "unknown codec";
                s_.codec = static_cast<uint8_t>(it - std::begin(kCodecNames));
                save_host_conf_key(dir, key, v);
            } else if (key == "jpeg_quality") {
                const int q = std::atoi(arg("value").c_str());
                if (q < 10 || q > 95) return "quality must be 10-95";
                s_.jpeg_quality = static_cast<uint32_t>(q);
                save_host_conf_key(dir, key, std::to_string(q));
            } else if (key == "audio") {
                if (!opt_.audio_available) return "sound is off for this run";
                if (s_.audio.exchange(on) != on) announce_audio(on);
                save_host_conf_key(dir, key, on ? "on" : "off");
            } else if (key == "usb") {
                s_.usb = on;
                save_host_conf_key(dir, key, on ? "on" : "off");
            } else if (key == "autostart") {
                if (!set_autostart(on)) return "could not change the login item";
            } else {
                return "unknown setting";
            }
            return "";
        }
        if (path == "/api/new-pin") {
            s_.pin = new_pairing_pin(dir);
            if (s_.pin_enabled) server_.set_pin(s_.pin);
            std::cout << "[UI] New pairing PIN made in the settings panel\n";
            return "";
        }
        if (path == "/api/disconnect") {
            server_.disconnect_client(static_cast<uint32_t>(std::strtoul(arg("id").c_str(), nullptr, 10)));
            return "";
        }
        if (path == "/api/remove-virtual") {
            const int id = std::atoi(arg("id").c_str());
            if (id < protocol::VIRTUAL_MONITOR_ID_BASE || id > 255 || !hooks_.remove_virtual(static_cast<uint8_t>(id)))
                return "no such virtual screen";
            return "";
        }
        if (path == "/api/ask-input") {
#if defined(IMMERSIVE_HAVE_PORTAL)
            if (!opt_.stub && portal::input_denied()) {
                portal::ask_again();
                return "";
            }
#endif
            return "remote control is not blocked";
        }
        if (path == "/api/quit") {
            hooks_.quit();
            return "";
        }
        return "unknown action";
    }

    /// AUDIO_START / AUDIO_STOP to every paired client, as on connect.
    void announce_audio(bool on) {
        protocol::AudioStart a{};
        a.sample_rate = 48000;
        a.channels = 2;
        a.audio_port = opt_.audio_port;
        for (const auto& c : server_.clients()) {
            if (on) server_.send_control_message(c.id, protocol::MessageType::AUDIO_START, &a, sizeof(a));
            else server_.send_control_message(c.id, protocol::MessageType::AUDIO_STOP, nullptr, 0);
        }
    }

    std::string state_json() {
        std::ostringstream j;
        const std::string ip = primary_ipv4();
        const std::string pin = std::to_string(s_.pin.load());
        j << "{\"pc\":{\"name\":" << json_str(local_host_name())
          << ",\"address\":" << json_str(ip) << ",\"port\":" << opt_.tcp_port << "}"
          << ",\"pin\":{\"enabled\":" << (s_.pin_enabled ? "true" : "false")
          << ",\"value\":" << json_str(s_.pin >= 100000 ? pin : "") << "}";

        const auto monitors = hooks_.monitors();
        auto monitor_name = [&](uint8_t id) {
            for (const auto& m : monitors) if (m.id == id) return m.name;
            return std::string();
        };
        uint32_t streaming = 0;
        const auto streams = hooks_.streams(streaming);
        j << ",\"headsets\":[";
        bool first = true;
        for (const auto& c : server_.clients()) {
            j << (first ? "" : ",") << "{\"id\":" << c.id << ",\"name\":" << json_str(c.name)
              << ",\"address\":" << json_str(c.address) << ",\"usb\":" << (c.tcp_media ? "true" : "false")
              << ",\"watching\":" << (c.watcher ? "true" : "false") << ",\"streams\":[";
            first = false;
            bool first_s = true;
            if (c.id == streaming) {
                for (const auto& st : streams) {
                    j << (first_s ? "" : ",") << "{\"monitor\":" << int(st.monitor_id)
                      << ",\"name\":" << json_str(monitor_name(st.monitor_id))
                      << ",\"codec\":" << json_str(st.codec < 4 ? kCodecNames[st.codec] : "")
                      << ",\"width\":" << st.width << ",\"height\":" << st.height
                      << ",\"fps_cap\":" << st.fps_cap << ",\"frames\":" << st.frames
                      << ",\"bytes\":" << st.bytes << "}";
                    first_s = false;
                }
            }
            j << "]}";
        }
        j << "]";

        j << ",\"virtual\":[";
        first = true;
        for (const auto& m : monitors) {
            if (!m.is_virtual) continue;
            j << (first ? "" : ",") << "{\"id\":" << int(m.id) << ",\"width\":" << m.width
              << ",\"height\":" << m.height << "}";
            first = false;
        }
        j << "],\"virtual_supported\":" << (opt_.virtual_supported ? "true" : "false");

        const uint8_t codec = s_.codec;
        j << ",\"settings\":{\"view_only\":" << (s_.view_only ? "true" : "false")
          << ",\"codec\":" << json_str(codec < 4 ? kCodecNames[codec] : "mjpeg")
          << ",\"jpeg_quality\":" << s_.jpeg_quality
          << ",\"audio\":" << (opt_.audio_available && s_.audio ? "true" : "false")
          << ",\"audio_available\":" << (opt_.audio_available ? "true" : "false")
          << ",\"usb\":" << (s_.usb ? "true" : "false")
          << ",\"usb_note\":" << json_str(hooks_.usb_note ? hooks_.usb_note() : "")
          << ",\"autostart\":" << (autostart_enabled() ? "true" : "false") << "}";

        bool denied = false;
#if defined(IMMERSIVE_HAVE_PORTAL)
        denied = !opt_.stub && portal::input_denied();
#endif
        j << ",\"input_denied\":" << (denied ? "true" : "false")
          << ",\"stub\":" << (opt_.stub ? "true" : "false") << "}";
        return j.str();
    }

    Settings& s_;
    INetworkServer& server_;
    Hooks hooks_;
    Options opt_;
    const std::string token_;
    std::string origin_, cookie_name_;
    uint16_t port_ = 0;
    Sock listen_ = kBadSock;
    std::atomic<bool> running_{true};
    std::thread thread_;
    std::unique_ptr<Tray> tray_;
};

}  // namespace

std::unique_ptr<HostUi> start(Settings& settings, INetworkServer& server, Hooks hooks, Options options) {
    auto panel = std::make_unique<Panel>(settings, server, std::move(hooks), std::move(options));
    if (!panel->listen()) {
        std::cerr << "[UI] The settings panel could not listen on 127.0.0.1\n";
        return nullptr;
    }
    std::cout << "[UI] Settings panel: " << panel->url() << "\n";
    panel->start_tray();
    return panel;
}

}  // namespace immersive::ui
