/// Per-OS pieces of the host UI: opening the panel as an app window and
/// starting the host at login. (The tray icons live in tray_*.)

#include "ui/host_ui.h"

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <thread>

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#else
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#endif
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

namespace immersive::ui {

namespace {

#ifndef _WIN32
/// Full path of `name` on PATH, or "".
std::string which(const std::string& name) {
    const char* path = std::getenv("PATH");
    std::string dirs = path ? path : "/usr/bin:/bin";
    size_t start = 0;
    while (start <= dirs.size()) {
        const size_t end = dirs.find(':', start);
        const std::string dir = dirs.substr(start, end == std::string::npos ? std::string::npos : end - start);
        const std::string full = (dir.empty() ? "." : dir) + "/" + name;
        if (access(full.c_str(), X_OK) == 0) return full;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return "";
}

/// Start a program detached, without our descriptors: popen() would hand the
/// browser the host's listening sockets, keeping the ports bound after the
/// host exits. Double fork so no zombie is left.
void spawn_detached(const std::vector<std::string>& argv) {
    std::vector<char*> args;
    for (const auto& a : argv) args.push_back(const_cast<char*>(a.c_str()));
    args.push_back(nullptr);
    const long max_fd = sysconf(_SC_OPEN_MAX);
    const pid_t pid = fork();
    if (pid == 0) {
        if (fork() != 0) _exit(0);
        setsid();
        for (long fd = 3; fd < (max_fd > 0 ? max_fd : 1024); ++fd) close(static_cast<int>(fd));
        const int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) { dup2(devnull, 0); dup2(devnull, 1); dup2(devnull, 2); }
        execv(args[0], args.data());
        _exit(127);
    }
    if (pid > 0) waitpid(pid, nullptr, 0);
}

std::string self_exe() {
#ifdef __APPLE__
    char buf[4096];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) return "";
    std::error_code ec;
    auto p = std::filesystem::canonical(buf, ec);
    return ec ? std::string(buf) : p.string();
#else
    std::error_code ec;
    auto p = std::filesystem::read_symlink("/proc/self/exe", ec);
    return ec ? "" : p.string();
#endif
}

std::filesystem::path home() {
    const char* h = std::getenv("HOME");
    return h ? h : ".";
}
#endif

#if !defined(_WIN32) && !defined(__APPLE__)
std::filesystem::path autostart_file() {
    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    const std::filesystem::path base = (xdg && *xdg) ? std::filesystem::path(xdg) : home() / ".config";
    return base / "autostart" / "immersive2-host.desktop";
}

/// Exec= argument quoting from the Desktop Entry spec.
std::string desktop_quote(const std::string& s) {
    std::string q = "\"";
    for (char c : s) {
        if (c == '"' || c == '`' || c == '$' || c == '\\') q += '\\';
        q += c;
    }
    return q + "\"";
}
#endif

#ifdef __APPLE__
std::filesystem::path launch_agent() {
    return home() / "Library" / "LaunchAgents" / "org.immersive2.host.plist";
}

std::string xml_escape(const std::string& s) {
    std::string o;
    for (char c : s) {
        if (c == '&') o += "&amp;";
        else if (c == '<') o += "&lt;";
        else if (c == '>') o += "&gt;";
        else o += c;
    }
    return o;
}
#endif

#ifdef _WIN32
constexpr const wchar_t* kRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr const wchar_t* kRunValue = L"Immersive2Host";
#endif

}  // namespace

#if !defined(_WIN32) && !defined(__APPLE__) && !defined(IMMERSIVE_HAVE_DBUS)
std::unique_ptr<Tray> create_tray(TrayModel) { return nullptr; }  // built without libdbus
#endif

void open_app_window(const std::string& url) {
#ifdef _WIN32
    // Edge ships with Windows 10/11; --app gives a window without tabs or
    // address bar. ShellExecute finds msedge.exe through App Paths.
    const std::wstring wurl(url.begin(), url.end());  // ASCII only
    const std::wstring args = L"--app=" + wurl + L" --window-size=720,860";
    auto r = reinterpret_cast<INT_PTR>(
        ShellExecuteW(nullptr, L"open", L"msedge.exe", args.c_str(), nullptr, SW_SHOWNORMAL));
    if (r <= 32) ShellExecuteW(nullptr, L"open", wurl.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
#elif defined(__APPLE__)
    spawn_detached({"/usr/bin/open", url});
#else
    if (!std::getenv("DISPLAY") && !std::getenv("WAYLAND_DISPLAY")) {
        std::cout << "[UI] No graphical session: open that address in a browser on this PC\n";
        return;
    }
    for (const char* b : {"google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
                          "microsoft-edge", "brave-browser"}) {
        const std::string exe = which(b);
        if (!exe.empty()) {
            spawn_detached({exe, "--app=" + url, "--window-size=720,860"});
            return;
        }
    }
    const std::string opener = which("xdg-open");
    if (!opener.empty()) spawn_detached({opener, url});
#endif
}

bool autostart_enabled() {
#ifdef _WIN32
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) return false;
    const bool on = RegQueryValueExW(key, kRunValue, nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS;
    RegCloseKey(key);
    return on;
#elif defined(__APPLE__)
    return std::filesystem::exists(launch_agent());
#else
    return std::filesystem::exists(autostart_file());
#endif
}

bool set_autostart(bool on) {
#ifdef _WIN32
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS)
        return false;
    LSTATUS r;
    if (on) {
        wchar_t exe[MAX_PATH];
        const DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
        const std::wstring cmd = L"\"" + std::wstring(exe, n) + L"\"";
        r = RegSetValueExW(key, kRunValue, 0, REG_SZ, reinterpret_cast<const BYTE*>(cmd.c_str()),
                           static_cast<DWORD>((cmd.size() + 1) * sizeof(wchar_t)));
    } else {
        r = RegDeleteValueW(key, kRunValue);
        if (r == ERROR_FILE_NOT_FOUND) r = ERROR_SUCCESS;
    }
    RegCloseKey(key);
    return r == ERROR_SUCCESS;
#else
#ifdef __APPLE__
    const auto file = launch_agent();
#else
    const auto file = autostart_file();
#endif
    std::error_code ec;
    if (!on) {
        std::filesystem::remove(file, ec);
        return !ec;
    }
    const std::string exe = self_exe();
    if (exe.empty()) return false;
    std::filesystem::create_directories(file.parent_path(), ec);
    std::ofstream f(file, std::ios::trunc);
#ifdef __APPLE__
    f << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
         "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
         "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
         "<plist version=\"1.0\">\n<dict>\n"
         "  <key>Label</key><string>org.immersive2.host</string>\n"
         "  <key>ProgramArguments</key><array><string>" << xml_escape(exe) << "</string></array>\n"
         "  <key>RunAtLoad</key><true/>\n"
         "</dict>\n</plist>\n";
#else
    f << "[Desktop Entry]\n"
         "Type=Application\n"
         "Name=Immersive-2\n"
         "Comment=Use this PC's screens in VR\n"
         "Exec=" << desktop_quote(exe) << "\n"
         "Terminal=false\n"
         "X-GNOME-Autostart-enabled=true\n";
#endif
    return static_cast<bool>(f);
#endif
}

}  // namespace immersive::ui
