/// host.conf, the pairing PIN file, the single-instance check and the tray
/// mark: the OS-independent parts of the host UI.

#include "ui/host_ui.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <map>
#include <random>
#include <sstream>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace immersive::ui {

namespace {

std::string trim(const std::string& s) {
    const auto a = s.find_first_not_of(" \t\r\n");
    const auto b = s.find_last_not_of(" \t\r\n");
    return a == std::string::npos ? "" : s.substr(a, b - a + 1);
}

bool truthy(const std::string& v) { return v == "on" || v == "1" || v == "true" || v == "yes"; }

/// Lines of host.conf as (key, value), in file order; comments kept as-is.
std::vector<std::pair<std::string, std::string>> read_lines(const std::filesystem::path& file) {
    std::vector<std::pair<std::string, std::string>> out;
    std::ifstream f(file);
    std::string line;
    while (std::getline(f, line)) {
        const auto eq = line.find('=');
        const std::string key = trim(line.substr(0, eq));
        if (eq == std::string::npos || key.empty() || key[0] == '#') out.push_back({"", line});
        else out.push_back({key, trim(line.substr(eq + 1))});
    }
    return out;
}

void make_private(const std::filesystem::path& p) {
    std::error_code ec;
    std::filesystem::permissions(p, std::filesystem::perms::owner_read |
                                    std::filesystem::perms::owner_write,
                                 std::filesystem::perm_options::replace, ec);
}

}  // namespace

void load_host_conf(const std::filesystem::path& dir, Settings& s) {
    for (const auto& [k, v] : read_lines(dir / "host.conf")) {
        if (k == "pin") s.pin_enabled = truthy(v);
        else if (k == "view_only") s.view_only = truthy(v);
        else if (k == "audio") s.audio = truthy(v);
        else if (k == "usb") s.usb = truthy(v);
        else if (k == "jpeg_quality") {
            const int q = std::atoi(v.c_str());
            if (q >= 10 && q <= 95) s.jpeg_quality = static_cast<uint32_t>(q);
        } else if (k == "codec") {
            if (v == "h264") s.codec = 0;
            else if (v == "h265" || v == "hevc") s.codec = 1;
            else if (v == "mjpeg") s.codec = 2;
            else if (v == "av1") s.codec = 3;
        }
    }
}

bool save_host_conf_key(const std::filesystem::path& dir, const std::string& key,
                        const std::string& value) {
    const auto file = dir / "host.conf";
    auto lines = read_lines(file);
    bool found = false;
    for (auto& [k, v] : lines) {
        if (k == key) { v = value; found = true; }
    }
    if (!found) lines.push_back({key, value});
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    const auto tmp = dir / "host.conf.tmp";
    {
        std::ofstream f(tmp, std::ios::trunc);
        if (lines.empty() || lines.front().first != "" ||
            lines.front().second.rfind("# Immersive-2", 0) != 0)
            f << "# Immersive-2 host settings, written by its settings panel.\n"
                 "# Command-line flags override them for one run.\n";
        for (const auto& [k, v] : lines) f << (k.empty() ? v : k + " = " + v) << "\n";
        if (!f) return false;
    }
    std::filesystem::rename(tmp, file, ec);
    return !ec;
}

uint32_t new_pairing_pin(const std::filesystem::path& dir) {
    std::random_device rd;
    const uint32_t pin = std::uniform_int_distribution<uint32_t>(100000, 999999)(rd);
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    const auto path = dir / "pairing-pin";
    std::ofstream(path, std::ios::trunc) << pin << "\n";
    make_private(path);
    return pin;
}

bool open_running_instance(const std::filesystem::path& config_dir) {
    std::string url;
    std::getline(std::ifstream(config_dir / "panel-url"), url);
    const std::string prefix = "http://127.0.0.1:";
    if (url.rfind(prefix, 0) != 0) return false;
    const int port = std::atoi(url.c_str() + prefix.size());
    if (port <= 0 || port > 65535) return false;

    // Only if something answers there: a stale file (a crashed host) must
    // not stop this one from starting.
#ifdef _WIN32
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    const bool have = s != INVALID_SOCKET;
#else
    int s = socket(AF_INET, SOCK_STREAM, 0);
    const bool have = s >= 0;
#endif
    bool alive = false;
    if (have) {
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_port = htons(static_cast<uint16_t>(port));
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        alive = connect(s, reinterpret_cast<sockaddr*>(&a), sizeof(a)) == 0;
#ifdef _WIN32
        closesocket(s);
#else
        close(s);
#endif
    }
#ifdef _WIN32
    WSACleanup();
#endif
    if (alive) open_app_window(url);
    return alive;
}

std::vector<uint32_t> tray_icon_pixels(int size, uint32_t ink, bool tally) {
    // The mark of web/client/index.html (viewBox 40x28): a screen whose lower
    // edge the headset lens swallows. Sampled into polylines, then drawn with
    // an analytic anti-aliased stroke, thicker than on the page so it holds
    // up at 16-22 px.
    std::vector<std::vector<std::pair<double, double>>> paths;
    auto arc = [](std::vector<std::pair<double, double>>& p, double cx, double cy, double r,
                  double a0, double a1) {
        for (int i = 0; i <= 8; ++i) {
            const double a = a0 + (a1 - a0) * i / 8.0;
            p.push_back({cx + r * std::cos(a), cy + r * std::sin(a)});
        }
    };
    auto cubic = [](double x0, double y0, double x1, double y1, double x2, double y2, double x3,
                    double y3) {
        std::vector<std::pair<double, double>> p;
        for (int i = 0; i <= 24; ++i) {
            const double t = i / 24.0, u = 1 - t;
            p.push_back({u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3,
                         u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3});
        }
        return p;
    };
    const double pi = 3.14159265358979;
    std::vector<std::pair<double, double>> screen = {{2.5, 17}};
    arc(screen, 5, 6, 2.5, pi, 1.5 * pi);
    arc(screen, 27, 6, 2.5, 1.5 * pi, 2 * pi);
    screen.push_back({29.5, 17});
    paths.push_back(screen);
    paths.push_back(cubic(2, 21.5, 8, 26.5, 32, 26.5, 38, 21.5));
    paths.push_back(cubic(16, 12.5, 19, 10.3, 25, 10.3, 28, 12.5));

    const double scale = size / 42.0;                  // 1 unit of margin each side
    const double ox = scale * 1.0, oy = (size - 28 * scale) / 2;
    const double half = std::max(0.75, 3.2 * scale / 2);  // stroke half-width, px
    const double tx = ox + 35.5 * scale, ty = oy + 5.5 * scale, tr = 3.6 * scale;

    std::vector<uint32_t> px(static_cast<size_t>(size) * size, 0);
    for (int y = 0; y < size; ++y) {
        for (int x = 0; x < size; ++x) {
            const double fx = x + 0.5, fy = y + 0.5;
            double d = 1e9;
            for (const auto& p : paths) {
                for (size_t i = 1; i < p.size(); ++i) {
                    const double ax = ox + p[i - 1].first * scale, ay = oy + p[i - 1].second * scale;
                    const double bx = ox + p[i].first * scale, by = oy + p[i].second * scale;
                    const double vx = bx - ax, vy = by - ay;
                    const double len2 = vx * vx + vy * vy;
                    double t = len2 > 0 ? ((fx - ax) * vx + (fy - ay) * vy) / len2 : 0;
                    t = std::clamp(t, 0.0, 1.0);
                    d = std::min(d, std::hypot(fx - ax - t * vx, fy - ay - t * vy));
                }
            }
            double a = std::clamp(half + 0.5 - d, 0.0, 1.0);
            uint32_t rgb = ink & 0xFFFFFF;
            if (tally) {
                const double ta = std::clamp(tr + 0.5 - std::hypot(fx - tx, fy - ty), 0.0, 1.0);
                if (ta > 0) { a = std::max(a, ta); rgb = 0xD9533B; }
            }
            px[static_cast<size_t>(y) * size + x] =
                (static_cast<uint32_t>(std::lround(a * ((ink >> 24) & 0xFF))) << 24) | rgb;
        }
    }
    return px;
}

}  // namespace immersive::ui
