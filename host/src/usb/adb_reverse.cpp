/// Keeps the USB tunnel (`adb reverse`) armed on every headset on a cable.

#include "usb/adb_reverse.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <map>
#include <sstream>
#include <thread>
#include <vector>

#ifndef _WIN32
#include <unistd.h>
#endif

namespace immersive {
namespace {

namespace fs = std::filesystem;

/// Run `"<adb>" <args>`; its stdout+stderr in `out`, true when it exited 0.
// ponytail: _popen flashes a console window if the host is ever built as a
// GUI-subsystem app; use CreateProcess(CREATE_NO_WINDOW) with pipes then.
bool adb_run(const std::string& adb, const std::string& args, std::string& out) {
    out.clear();
    std::string cmd = "\"" + adb + "\" " + args + " 2>&1";
#ifdef _WIN32
    // cmd.exe drops the first and last quote of a command starting with one.
    FILE* p = _popen(("\"" + cmd + "\"").c_str(), "r");
#else
    FILE* p = popen(cmd.c_str(), "r");
#endif
    if (!p) return false;
    char buf[512];
    while (std::fgets(buf, sizeof(buf), p)) out += buf;
#ifdef _WIN32
    return _pclose(p) == 0;
#else
    return pclose(p) == 0;
#endif
}

std::string first_line(const std::string& s) {
    std::string line = s.substr(0, s.find('\n'));
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
    return line.empty() ? "no output" : line;
}

bool is_executable(const fs::path& p) {
    std::error_code ec;
    if (!fs::is_regular_file(p, ec)) return false;
#ifdef _WIN32
    return true;
#else
    return access(p.c_str(), X_OK) == 0;
#endif
}

std::string find_adb() {
#ifdef _WIN32
    const char* exe = "adb.exe";
    const char sep = ';';
#else
    const char* exe = "adb";
    const char sep = ':';
#endif
    auto env = [](const char* name) -> std::string {
        const char* v = std::getenv(name);
        return v ? v : "";
    };
    std::vector<fs::path> dirs;
    std::stringstream path(env("PATH"));
    for (std::string d; std::getline(path, d, sep);)
        if (!d.empty()) dirs.emplace_back(d);
    for (const char* v : {"ANDROID_HOME", "ANDROID_SDK_ROOT"})
        if (!env(v).empty()) dirs.push_back(fs::path(env(v)) / "platform-tools");
#ifdef _WIN32
    if (!env("LOCALAPPDATA").empty())
        dirs.push_back(fs::path(env("LOCALAPPDATA")) / "Android" / "Sdk" / "platform-tools");
#else
    if (!env("HOME").empty()) {
        const fs::path home = env("HOME");
        dirs.push_back(home / "Android" / "Sdk" / "platform-tools");              // Android Studio, Linux
        dirs.push_back(home / "Library" / "Android" / "sdk" / "platform-tools");  // Android Studio, macOS
        dirs.push_back(home / ".local" / "bin");
    }
    for (const char* d : {"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                          "/usr/lib/android-sdk/platform-tools", "/opt/android-sdk/platform-tools"})
        dirs.emplace_back(d);
#endif
    for (const auto& d : dirs)
        if (is_executable(d / exe)) return (d / exe).string();
    return "";
}

/// A serial safe to put on a command line (adb prints whatever the device says).
bool plain_serial(const std::string& s) {
    return !s.empty() && s.find_first_not_of(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-") == std::string::npos;
}

/// `adb reverse --list` has a `<device port> <pc port>` rule for `rule`.
bool has_rule(const std::string& list, const std::string& rule) {
    std::istringstream lines(list);
    for (std::string line; std::getline(lines, line);) {
        std::istringstream words(line);
        std::vector<std::string> w;
        for (std::string t; words >> t;) w.push_back(t);
        if (w.size() >= 2 && w[w.size() - 2] == rule) return true;
    }
    return false;
}

void report(const std::string& serial, const std::string& state, uint16_t port) {
    std::cout << "[Host] USB: ";
    if (state == "ready")
        std::cout << "headset " << serial << " is on the cable and uses it by itself"
                  << " (its 127.0.0.1:" << port << " reaches this PC)\n";
    else if (state == "unauthorized")
        std::cout << "headset " << serial << " is plugged in but has not allowed USB debugging:"
                  << " put it on and accept the prompt (tick \"Always allow\")\n";
    else if (state == "offline")
        std::cout << "headset " << serial << " is offline: unplug the cable and plug it back in\n";
    else if (state.rfind("no permissions", 0) == 0)
        std::cout << "adb may not use " << serial << ": add a udev rule for it (see docs/BUILDING.md)\n";
    else if (state == "gone")
        std::cout << "headset " << serial << " unplugged\n";
    else
        std::cout << serial << ": " << state << "\n";
}

}  // namespace

std::string start_adb() {
    const std::string adb = find_adb();
    std::string out;
    if (!adb.empty()) adb_run(adb, "start-server", out);
    return adb;
}

void keep_adb_reverse(const std::string& adb, uint16_t port, const std::atomic<bool>& running) {
    const std::string rule = "tcp:" + std::to_string(port);
    std::map<std::string, std::string> last;  // serial -> state last reported
    bool adb_ok = true;
    std::string out, list;
    while (running) {
        if (!adb_run(adb, "devices", out)) {
            if (adb_ok) std::cout << "[Host] USB: adb is not answering (" << first_line(out) << ")\n";
            adb_ok = false;
        } else {
            if (!adb_ok) std::cout << "[Host] USB: adb answers again\n";
            adb_ok = true;
            std::map<std::string, std::string> now;
            std::istringstream lines(out);
            for (std::string line; std::getline(lines, line);) {
                const size_t tab = line.find('\t');
                if (tab == std::string::npos) continue;  // the header, daemon chatter
                const std::string serial = line.substr(0, tab);
                std::string state = line.substr(tab + 1);
                while (!state.empty() && (state.back() == '\r' || state.back() == ' ')) state.pop_back();
                if (!plain_serial(serial)) continue;
                if (state == "device") {
                    const std::string s = "-s " + serial + " reverse ";
                    if (!(adb_run(adb, s + "--list", list) && has_rule(list, rule)) &&
                        !adb_run(adb, s + rule + " " + rule, list))
                        state = "tunnel failed: " + first_line(list);
                    else
                        state = "ready";
                }
                now[serial] = state;
            }
            for (const auto& [serial, state] : now) {
                // Passing states on the way to "device": nothing to tell.
                if (state == "authorizing" || state == "connecting") continue;
                auto it = last.find(serial);
                if (it == last.end() || it->second != state) report(serial, state, port);
            }
            for (const auto& [serial, state] : last)
                if (!now.count(serial)) report(serial, "gone", port);
            last = std::move(now);
        }
        for (int i = 0; i < 30 && running; ++i)
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

}  // namespace immersive
