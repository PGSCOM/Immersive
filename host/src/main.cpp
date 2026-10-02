/// Immersive-2 Host Application
///
/// Main entry point for the host (Windows, Linux, macOS).
/// Captures desktop, encodes video, streams to VR clients.

#include "capture/dxgi_capture.h"
#include "encoder/encoder.h"
#include "encoder/mf_encoder.h"
#include "network/server.h"
#include "input/input_injector.h"
#include "driver/idd_manager.h"
#include "audio/audio_capture.h"
#include "ui/host_ui.h"
#include "usb/adb_reverse.h"
#include "protocol.h"

#include <algorithm>
#include <array>
#include <iostream>
#include <thread>
#include <atomic>
#include <mutex>
#include <map>
#include <set>
#include <csignal>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <random>
#include <string>
#include <vector>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#endif

namespace {
    std::atomic<bool> g_running{true};

    void signal_handler(int signal) {
        std::cout << "\n[Host] Shutting down (signal " << signal << ")...\n";
        g_running = false;
    }

    /// Bilinear downscale of a BGRA image (fixed-point 16.16 sampling).
    void scale_bgra_bilinear(const uint8_t* src, uint32_t sw, uint32_t sh, uint32_t spitch,
                             uint8_t* dst, uint32_t dw, uint32_t dh) {
        if (sw == 0 || sh == 0 || dw == 0 || dh == 0) return;
        const uint64_t x_step = (static_cast<uint64_t>(sw - 1) << 16) / (dw > 1 ? dw - 1 : 1);
        const uint64_t y_step = (static_cast<uint64_t>(sh - 1) << 16) / (dh > 1 ? dh - 1 : 1);

        for (uint32_t y = 0; y < dh; ++y) {
            uint64_t sy_fp = y * y_step;
            uint32_t sy    = static_cast<uint32_t>(sy_fp >> 16);
            uint32_t fy    = static_cast<uint32_t>(sy_fp & 0xFFFF);
            uint32_t sy1   = (sy + 1 < sh) ? sy + 1 : sy;

            const uint8_t* row0 = src + static_cast<size_t>(sy)  * spitch;
            const uint8_t* row1 = src + static_cast<size_t>(sy1) * spitch;
            uint8_t*       out  = dst + static_cast<size_t>(y) * dw * 4;

            for (uint32_t x = 0; x < dw; ++x) {
                uint64_t sx_fp = x * x_step;
                uint32_t sx    = static_cast<uint32_t>(sx_fp >> 16);
                uint32_t fx    = static_cast<uint32_t>(sx_fp & 0xFFFF);
                uint32_t sx1   = (sx + 1 < sw) ? sx + 1 : sx;

                const uint8_t* p00 = row0 + sx  * 4;
                const uint8_t* p01 = row0 + sx1 * 4;
                const uint8_t* p10 = row1 + sx  * 4;
                const uint8_t* p11 = row1 + sx1 * 4;

                for (int c = 0; c < 4; ++c) {
                    uint32_t top = (p00[c] * (0x10000 - fx) + p01[c] * fx) >> 16;
                    uint32_t bot = (p10[c] * (0x10000 - fx) + p11[c] * fx) >> 16;
                    out[x * 4 + c] = static_cast<uint8_t>(
                        (top * (0x10000 - fy) + bot * fy) >> 16);
                }
            }
        }
    }

    /// Run a shell command and wait for it. popen, not std::system: POSIX
    /// system() ignores SIGINT while the child runs, so a Ctrl+C landing
    /// meanwhile was silently lost.
    int run_quiet(const std::string& cmd) {
#ifdef _WIN32
        FILE* p = _popen(cmd.c_str(), "r");
        return p ? _pclose(p) : -1;
#else
        FILE* p = popen(cmd.c_str(), "r");
        return p ? pclose(p) : -1;
#endif
    }

    /// Pop a desktop notification (a message box on Windows) without blocking
    /// the caller. `body` must hold no quote characters: it goes through a shell.
    void notify_desktop(const std::string& title, const std::string& body) {
        std::thread([title, body] {
#ifdef _WIN32
            MessageBoxA(nullptr, body.c_str(), title.c_str(),
                        MB_OK | MB_ICONINFORMATION | MB_TOPMOST | MB_SETFOREGROUND);
#elif defined(__APPLE__)
            run_quiet("osascript -e 'display notification \"" + body + "\" with title \""
                      + title + "\"' 2>/dev/null");
#else
            run_quiet("notify-send -a Immersive-2 -u critical \"" + title + "\" \"" + body
                      + "\" 2>/dev/null");
#endif
        }).detach();
    }

    /// Per-user settings directory: %APPDATA%\Immersive2 on Windows,
    /// $XDG_CONFIG_HOME/immersive2 (~/.config/immersive2) elsewhere.
    std::filesystem::path config_dir() {
#ifdef _WIN32
        const char* appdata = std::getenv("APPDATA");
        return std::filesystem::path(appdata ? appdata : ".") / "Immersive2";
#else
        const char* xdg = std::getenv("XDG_CONFIG_HOME");
        const char* home = std::getenv("HOME");
        return ((xdg && *xdg) ? std::filesystem::path(xdg)
                              : std::filesystem::path(home ? home : ".") / ".config") / "immersive2";
#endif
    }

    /// The pairing PIN, generated once and kept in the config dir so a
    /// headset paired once stays paired across host restarts.
    uint32_t load_or_create_pin() {
        const auto path = config_dir() / "pairing-pin";
        uint32_t pin = 0;
        std::ifstream(path) >> pin;
        if (pin >= 100000 && pin <= 999999) return pin;
        std::random_device rd;
        pin = std::uniform_int_distribution<uint32_t>(100000, 999999)(rd);
        std::error_code ec;
        std::filesystem::create_directories(path.parent_path(), ec);
        std::ofstream(path, std::ios::trunc) << pin << "\n";
        std::filesystem::permissions(path, std::filesystem::perms::owner_read |
                                           std::filesystem::perms::owner_write,
                                     std::filesystem::perm_options::replace, ec);
        return pin;
    }

    /// Print usage and exit.
    [[noreturn]] void usage(const char* prog) {
        std::cerr << "Usage: " << prog << " [options]\n"
                  << "Options:\n"
                  << "  --max-clients N     Maximum simultaneous VR clients (default: 4)\n"
                  << "  --tcp-port N        TCP control port (default: 19800)\n"
                  << "  --udp-port N        UDP video port (default: 19801)\n"
                  << "  --audio-port N      UDP audio port (default: 19802)\n"
                  << "  --no-audio          Disable audio streaming\n"
                  << "  --no-usb            Don't run `adb reverse` for USB-connected headsets\n"
                  << "  --codec NAME        Video codec: mjpeg (default), h264, h265 or av1.\n"
                  << "                      h264/h265/av1 use the hardware encoder (Media\n"
                  << "                      Foundation, VideoToolbox, or NVENC/VAAPI via\n"
                  << "                      FFmpeg with libx264 as fallback) and need the\n"
                  << "                      client's MediaCodec decoder (Quest/Pico).\n"
                  << "  --jpeg-quality N    MJPEG quality 10-95 (default: 35)\n"
                  << "  --pin NNNNNN        Pairing PIN headsets must enter (6 digits). By\n"
                  << "                      default a random one is created once and kept in\n"
                  << "                      the settings folder\n"
                  << "  --no-pin            Let any device on the network connect without a PIN\n"
                  << "  --view-only         Share the screens but ignore mouse and keyboard\n"
                  << "                      from headsets (no remote control)\n"
                  << "  --stub              Fake displays and logged-only input, for protocol\n"
                  << "                      tests without touching the real desktop (ignores\n"
                  << "                      host.conf, so test runs are reproducible)\n"
                  << "  --no-ui             No tray icon and no settings window (headless)\n"
                  << "  --panel-port N      Settings panel port on 127.0.0.1 (default: 19803,\n"
                  << "                      any free port if busy)\n"
                  << "  --install-idd-cert  Install a self-signed code-signing certificate\n"
                  << "                      into the machine trust stores so an unsigned\n"
                  << "                      IDD virtual-display driver can be installed,\n"
                  << "                      then exit. Needs administrator rights and\n"
                  << "                      permanently trusts that key — see\n"
                  << "                      docs/IDD_DRIVER.md. Not needed for normal use.\n"
                  << "  --help              Show this message\n"
                  << "Settings changed in the panel are kept in host.conf in the settings\n"
                  << "folder; the flags above override them for one run.\n";
        std::exit(1);
    }
}

int main(int argc, char* argv[]) {
    std::cout << "=== Immersive-2 Host v0.1.0 ===\n\n";

    // Register signal handlers for graceful shutdown
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);
#ifdef SIGHUP
    // Its terminal closed: still exit through the cleanup (which lights the
    // main screen again if a headset had turned it off).
    std::signal(SIGHUP, signal_handler);
#endif
#ifdef SIGPIPE
    // A client that vanishes (Wi-Fi drop, headset sleep) can be written to
    // before its handler thread notices. Without this the default SIGPIPE
    // action terminates the whole host; the send then just fails with EPIPE
    // and the connection is cleaned up normally.
    std::signal(SIGPIPE, SIG_IGN);
#endif

    // --- Parse command-line arguments ---
    // Settings the panel changes live (src/ui): host.conf first, then the
    // flags override them for this run. --stub (tests) ignores host.conf.
    immersive::ui::Settings settings;
    if (std::none_of(argv + 1, argv + argc, [](const char* a) { return std::strcmp(a, "--stub") == 0; }))
        immersive::ui::load_host_conf(config_dir(), settings);
    std::atomic<bool>&     usb_enable    = settings.usb;
    std::atomic<uint8_t>&  default_codec = settings.codec;  // protocol VideoCodec: 0=H264 1=H265 2=MJPEG 3=AV1
    std::atomic<uint32_t>& jpeg_quality  = settings.jpeg_quality;
    std::atomic<bool>&     view_only     = settings.view_only;
    uint32_t max_clients  = 4;
    uint16_t tcp_port     = immersive::protocol::DEFAULT_TCP_PORT;
    uint16_t udp_port     = immersive::protocol::DEFAULT_UDP_PORT;
    uint16_t audio_port   = immersive::protocol::DEFAULT_AUDIO_PORT;
    bool     audio_enable = true;   // this run can send sound; settings.audio is the switch
    bool     stub         = false;
    int64_t  pin_arg      = settings.pin_enabled ? -1 : 0;  // -1: persistent random PIN, 0: --no-pin
    bool     ui_enable    = true;
    uint16_t panel_port   = 19803;
    bool     port_given   = false;

    for (int i = 1; i < argc; ++i) {
        std::string arg(argv[i]);

        if (arg == "--help" || arg == "-h") {
            usage(argv[0]);
        } else if (arg == "--max-clients" && i + 1 < argc) {
            max_clients = static_cast<uint32_t>(std::stoi(argv[++i]));
        } else if (arg == "--tcp-port" && i + 1 < argc) {
            tcp_port = static_cast<uint16_t>(std::stoi(argv[++i]));
            port_given = true;
        } else if (arg == "--no-ui") {
            ui_enable = false;
        } else if (arg == "--panel-port" && i + 1 < argc) {
            panel_port = static_cast<uint16_t>(std::stoi(argv[++i]));
        } else if (arg == "--udp-port" && i + 1 < argc) {
            udp_port = static_cast<uint16_t>(std::stoi(argv[++i]));
        } else if (arg == "--audio-port" && i + 1 < argc) {
            audio_port = static_cast<uint16_t>(std::stoi(argv[++i]));
        } else if (arg == "--no-audio") {
            audio_enable = false;
        } else if (arg == "--stub") {
            stub = true;
            audio_enable = false;
        } else if (arg == "--no-usb") {
            usb_enable = false;
        } else if (arg == "--no-pin") {
            pin_arg = 0;
        } else if (arg == "--view-only") {
            view_only = true;
        } else if (arg == "--pin" && i + 1 < argc) {
            pin_arg = std::strtoll(argv[++i], nullptr, 10);
            if (pin_arg < 100000 || pin_arg > 999999) {
                std::cerr << "[Host] --pin needs six digits (100000-999999)\n";
                usage(argv[0]);
            }
        } else if (arg == "--install-idd-cert") {
            immersive::install_idd_signing_certificate();
            return 0;
        } else if (arg == "--codec" && i + 1 < argc) {
            std::string codec(argv[++i]);
            if      (codec == "h264")  default_codec = 0;
            else if (codec == "h265" || codec == "hevc") default_codec = 1;
            else if (codec == "mjpeg") default_codec = 2;
            else if (codec == "av1")   default_codec = 3;
            else {
                std::cerr << "[Host] Unknown codec: " << codec << "\n";
                usage(argv[0]);
            }
        } else if (arg == "--jpeg-quality" && i + 1 < argc) {
            int q = std::stoi(argv[++i]);
            jpeg_quality = static_cast<uint32_t>(std::max(10, std::min(95, q)));
        } else {
            std::cerr << "[Host] Unknown argument: " << arg << "\n";
            usage(argv[0]);
        }
    }

    // Launched again (from the desktop, say) while running: show the panel
    // of the running host instead of failing on its busy ports.
    if (ui_enable && !stub && !port_given && immersive::ui::open_running_instance(config_dir())) {
        std::cout << "[Host] Already running: opened its settings window\n";
        return 0;
    }

    std::cout << "[Host] Configuration: max_clients=" << max_clients
              << ", tcp=" << tcp_port << ", udp=" << udp_port
              << ", audio=" << audio_port
              << (audio_enable ? "" : " (disabled)") << "\n\n";

    // --- Initialize components ---

    // 1. Screen capture — the native backend for this OS (see
    //    create_screen_capture), or fake displays with --stub. Each stream
    //    worker makes its own instance through make_capture().
    auto make_capture = [stub]() {
        return stub ? immersive::create_stub_capture()
                    : immersive::create_screen_capture();
    };
    if (stub) {
        std::cout << "[Host] --stub: fake displays, input is only logged\n";
    }
    // Virtual displays: extra monitors made on a headset's request. Made
    // first: on X11 it clears ones a killed host left behind.
    auto vdm = stub ? immersive::create_stub_virtual_display_manager()
                    : immersive::create_virtual_display_manager();
    const bool vdm_ok = vdm->can_create_displays();
#ifdef _WIN32
    vdm->is_driver_installed();  // logs whether an IDD driver is present
#endif

    auto capture = make_capture();
    auto displays = capture ? capture->enumerate_displays()
                            : std::vector<immersive::DisplayInfo>{};

    std::cout << "[Host] Found " << displays.size() << " display(s):\n";
    for (const auto& d : displays) {
        std::cout << "  [" << (int)d.id << "] " << d.name
                  << " (" << d.width << "x" << d.height << ")"
                  << (d.is_primary ? " (primary)" : "") << "\n";
    }

    if (displays.empty() && vdm_ok) {
        std::cout << "[Host] No physical display: add a virtual screen from the headset\n";
    } else if (displays.empty()) {
        std::cerr << "[Host] No displays found. Exiting.\n"
#ifdef __APPLE__
                  << "       Grant Screen Recording to this binary (or its terminal) in\n"
                  << "       System Settings > Privacy & Security, then run it again.\n"
#elif !defined(_WIN32)
                  << "       Needs a graphical session (WAYLAND_DISPLAY or DISPLAY set)\n"
                  << "       and, on Wayland, the screen-share request accepted.\n"
#endif
                  << "       Use --stub to test the protocol without a desktop.\n";
        return 1;
    }

    // 2. Encoder availability. MJPEG always works (CPU). H.264/HEVC/AV1 use
    // the OS hardware encoder (create_hw_encoder); each stream worker creates
    // its own encoder instance.
    const bool has_h264 = immersive::hw_encoder_available(immersive::VideoCodec::H264);
    const bool has_h265 = immersive::hw_encoder_available(immersive::VideoCodec::H265);
    const bool has_av1  = immersive::hw_encoder_available(immersive::VideoCodec::AV1);
    std::cout << "[Host] Encoders available: MJPEG (software)"
              << (has_h264 ? ", H.264" : "")
              << (has_h265 ? ", HEVC" : "")
              << (has_av1  ? ", AV1"  : "") << "\n";
    if ((default_codec == 0 && !has_h264) ||
        (default_codec == 1 && !has_h265) ||
        (default_codec == 3 && !has_av1)) {
        std::cout << "[Host] Requested codec not available on this machine, "
                  << "streams will fall back automatically\n";
    }

    // 3. Input injector
    auto input_injector = stub ? immersive::create_stub_input_injector()
                               : immersive::create_input_injector();
    input_injector->initialize();
    input_injector->set_displays(displays);

    // 5. Audio capture (WASAPI loopback)
    std::unique_ptr<immersive::IAudioCapture> audio_capture;
    if (audio_enable && settings.audio) {
        audio_capture = immersive::create_audio_capture();
        if (!audio_capture || !audio_capture->start()) {
            std::cerr << "[Host] Audio capture failed to start — audio disabled\n";
            audio_enable = false;
        }
    }

    // 6. Network server
    auto server = immersive::create_network_server();

    // The monitor list as sent to clients, rebuilt whenever a virtual
    // display comes or goes. displays_mutex guards `displays` and these two
    // (read by network threads, rewritten under ops_mutex).
    std::mutex displays_mutex;
    std::vector<immersive::protocol::MonitorInfo> proto_monitors;
    std::vector<uint8_t> monitor_flags;  // MONITOR_FLAG_* per entry
    auto build_proto_monitors = [&]() {  // caller holds displays_mutex
        proto_monitors.clear();
        monitor_flags.clear();
        for (const auto& d : displays) {
            immersive::protocol::MonitorInfo info = {};
            info.monitor_id   = d.id;
            info.width        = d.width;
            info.height       = d.height;
            info.refresh_rate = d.refresh_rate;
            strncpy(info.name, d.name.c_str(), sizeof(info.name) - 1);
            proto_monitors.push_back(info);
            monitor_flags.push_back(
                (d.id >= immersive::protocol::VIRTUAL_MONITOR_ID_BASE
                     ? immersive::protocol::MONITOR_FLAG_VIRTUAL : 0) |
                (d.is_primary ? immersive::protocol::MONITOR_FLAG_PRIMARY : 0));
        }
    };
    build_proto_monitors();

    // --- Multi-monitor streaming state ---
    // One worker per selected monitor, each with its own capture (DXGI
    // duplication) and encoder instance.
    //  - ops_mutex serialises whole selection/restart/stop operations,
    //    including the wait for workers to stop, so two clients' requests
    //    can't interleave half-way.
    //  - streams_mutex only guards the map and streams_client_id for short
    //    reads (REQUEST_KEYFRAME), so those never wait on a stopping worker.
    // Lock order: ops_mutex -> streams_mutex / input_mutex / graveyard_mutex.
    struct ActiveStream {
        std::atomic<bool> stop{false};
        std::atomic<bool> force_keyframe{false};  // set by REQUEST_KEYFRAME (loss recovery)
        std::atomic<bool> done{false};            // worker returned: join() won't block
        std::thread       worker;
        // For the settings panel.
        std::atomic<uint8_t>  codec{0xFF};
        std::atomic<uint16_t> width{0}, height{0};
        std::atomic<uint32_t> fps_cap{0};
        std::atomic<uint64_t> frames{0}, bytes{0};
        // A STREAM_CONFIG that keeps codec and size: the worker retunes its
        // encoder in place instead of being restarted.
        std::mutex        cfg_mutex;
        immersive::protocol::StreamConfig new_cfg{};
        std::atomic<bool> cfg_changed{false};
    };

    std::mutex ops_mutex;
    std::mutex streams_mutex;
    std::map<uint8_t, std::unique_ptr<ActiveStream>> active_streams;
    // Last frame number sent per monitor, across stream restarts.
    std::array<std::atomic<uint32_t>, 256> frame_high_water{};
    uint32_t streams_client_id = 0;
    std::atomic<int> live_stream_count{0};  // streams actively sending (gates audio)

    // Workers that did not stop in time (stuck in a capture backend, e.g. a
    // Wayland share dialog nobody answers). The main loop joins them once they
    // return; nothing else waits on them.
    std::mutex graveyard_mutex;
    std::vector<std::unique_ptr<ActiveStream>> graveyard;

    // Client-requested stream quality (protected by ops_mutex).
    // Defaults mean "use the host CLI settings".
    immersive::protocol::StreamConfig stream_cfg = {};
    stream_cfg.codec = 0xFF;

    // Per-monitor scale from stream pixels to native pixels, used to map
    // incoming mouse coordinates when the stream is downscaled. `owner` is
    // the worker that registered it, so a late-exiting old worker can't erase
    // the entry of its replacement.
    struct InputScale {
        double sx, sy;
        uint16_t native_w, native_h;
        const ActiveStream* owner;
    };
    std::mutex input_scale_mutex;
    std::map<uint8_t, InputScale> input_scale;

    // Input: only the streaming client drives it (input_client_id mirrors
    // streams_client_id for this hot path). input_mutex serialises every
    // injector call (their button/scroll state is not thread-safe) and the
    // record of what is held down, released when that client goes away.
    std::atomic<uint32_t> input_client_id{0};
    std::mutex input_mutex;
    immersive::protocol::InputMouse held_mouse = {};  // last injected, native px
    std::set<uint16_t> held_keys;                      // VKs injected down, not yet up

    auto release_input = [&]() {
        std::lock_guard<std::mutex> lock(input_mutex);
        if (held_mouse.buttons) {
            immersive::protocol::InputMouse up = held_mouse;
            up.buttons = 0;
            up.scroll_delta = up.scroll_delta_h = 0;
            input_injector->inject_mouse(up);
            held_mouse.buttons = 0;
        }
        for (uint16_t vk : held_keys) {
            immersive::protocol::InputKeyboard k = {};
            k.monitor_id = held_mouse.monitor_id;
            k.scancode = vk;
            input_injector->inject_keyboard(k);
        }
        held_keys.clear();
    };

    // Re-read the display layout after a capture had to restart (monitor
    // unplugged, resolution or arrangement changed), so input lands where the
    // stream now shows. Returns the fresh list (empty on failure).
    auto refresh_input_displays = [&]() {
        auto probe = make_capture();
        auto now_displays = probe ? probe->enumerate_displays()
                                  : std::vector<immersive::DisplayInfo>{};
        if (!now_displays.empty()) {
            std::lock_guard<std::mutex> lock(input_mutex);
            input_injector->set_displays(now_displays);
        }
        return now_displays;
    };

    // Capture → encode → send loop for a single monitor.
    // `cfg` is a snapshot of the client stream settings taken at start time.
    auto stream_worker = [&](uint32_t client_id,
                             immersive::DisplayInfo display,
                             immersive::protocol::StreamConfig cfg,
                             ActiveStream* ctx) {
        const uint8_t monitor_id = display.id;

        // --- Resolve effective settings (client config overrides CLI) ---
        // Protocol codec values: 0=H.264, 1=HEVC, 2=MJPEG, 3=AV1, 0xFF=default
        uint8_t requested_codec = (cfg.codec != 0xFF) ? cfg.codec : default_codec.load();

        // Output resolution (downscale keeping aspect, even dimensions for NV12)
        uint32_t out_w = display.width;
        uint32_t out_h = display.height;
        if (cfg.max_width >= 320 && cfg.max_width < display.width) {
            out_w = cfg.max_width;
            out_h = static_cast<uint32_t>(display.height) * out_w / display.width;
        }
        // Even at native size too: a scaled desktop can report e.g. 1707x960,
        // which x264/NVENC/VAAPI refuse and NV12 conversion would overrun.
        out_w = std::max(2u, out_w & ~1u);
        out_h = std::max(2u, out_h & ~1u);

        // The retry loop is a safety net for transient failures (mode changes,
        // a Wayland portal being re-created, a permission prompt).
        std::unique_ptr<immersive::IScreenCapture> stream_capture;
        for (;;) {
            if (!stream_capture) {  // a backend can be unavailable for a while
                stream_capture = make_capture();
                if (stream_capture) stream_capture->set_output_size(out_w, out_h);
            }
            if (stream_capture && stream_capture->start_capture(monitor_id)) break;
            if (!g_running || ctx->stop) return;
            std::cerr << "[Host] Capture unavailable on monitor " << (int)monitor_id
                      << " — retrying in 3 s...\n";
            for (int i = 0; i < 30 && g_running && !ctx->stop; ++i)
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        // Stopped while start_capture() was blocked (a share dialog, say):
        // don't announce a stream that has already been replaced.
        if (!g_running || ctx->stop) {
            stream_capture->stop_capture();
            return;
        }

        immersive::EncoderConfig enc_config;
        enc_config.width        = out_w;
        enc_config.height       = out_h;
        enc_config.fps          = (cfg.max_fps > 0)
                                      ? cfg.max_fps
                                      : static_cast<uint32_t>(display.refresh_rate);
        // Keyframes are driven from the streaming loop below: the first frame,
        // and on demand whenever the client sees a frame missing (it asks with
        // REQUEST_KEYFRAME; every lost frame shows as a gap in frame numbers,
        // a lost last one at the next 1 s idle re-send). No periodic IDR: an
        // IDR must fit the small VBV, so it shows a desktop's text blurred
        // (~30 dB PSNR against ~54 dB once P-frames have refined it), and a
        // refresh every second made the whole picture pulse. The encoder's own
        // GOP is only a safety ceiling.
        enc_config.gop_size     = std::max<uint32_t>(30, enc_config.fps * 60);
        enc_config.jpeg_quality = (cfg.jpeg_quality >= 10 && cfg.jpeg_quality <= 95)
                                      ? cfg.jpeg_quality : jpeg_quality.load();
        // A bitrate ceiling scaled to this client's share of its link (the
        // server's rate control, from FRAME_ACKs), at least 1 Mbps. The
        // encoder opens at it, as retune() below keeps it: opened at the
        // ceiling, VAAPI had to re-open (an IDR) at once.
        auto link_kbps = [&](uint32_t ceil) {
            return std::max(std::min(ceil, 1000u),
                            static_cast<uint32_t>(ceil * server->link_rate_scale(client_id)));
        };
        enc_config.bitrate_kbps = link_kbps(cfg.bitrate_kbps > 0
            ? std::min<uint32_t>(cfg.bitrate_kbps, 100000) : enc_config.bitrate_kbps);

        // Fallback chain: requested codec → H.264 → MJPEG. `actual_codec`
        // (protocol value) is what we announce in STREAM_START.
        std::unique_ptr<immersive::IVideoEncoder> stream_encoder;
        uint8_t actual_codec = 2;

        // H.264 stops at Level 5.2 in practice: 4096 px a side (VAAPI refuses
        // more) and 36864 macroblocks a frame, 4096x2304 (Qualcomm decoders,
        // the Pico 4's too). A bigger screen (a 5120x1440 virtual one, say)
        // streams scaled down to fit; HEVC and AV1 carry the whole 7680x4320.
        // The client mirrors this in virtual_size.gd (h264_size).
        auto fit_h264 = [](uint32_t& w, uint32_t& h) {
            const double mbs = ((w + 15) / 16) * ((h + 15) / 16);
            const double s = std::min({1.0, 4096.0 / w, 4096.0 / h, std::sqrt(36864.0 / mbs)});
            if (s < 1.0) {
                w = static_cast<uint32_t>(w * s + 0.5) & ~15u;
                h = static_cast<uint32_t>(h * s + 0.5) & ~15u;
            }
        };

        auto try_mf_codec = [&](immersive::VideoCodec vc, uint8_t proto_value) -> bool {
            enc_config.codec  = vc;
            enc_config.width  = out_w;
            enc_config.height = out_h;
            if (vc == immersive::VideoCodec::H264) fit_h264(enc_config.width, enc_config.height);
            auto enc = immersive::create_hw_encoder();
            if (enc && enc->initialize(enc_config)) {
                stream_encoder = std::move(enc);
                actual_codec   = proto_value;
                return true;
            }
            return false;
        };

        switch (requested_codec) {
        case 0: try_mf_codec(immersive::VideoCodec::H264, 0); break;
        case 1:
            if (!try_mf_codec(immersive::VideoCodec::H265, 1)) {
                std::cout << "[Host] HEVC unavailable, trying H.264...\n";
                try_mf_codec(immersive::VideoCodec::H264, 0);
            }
            break;
        case 3:
            if (!try_mf_codec(immersive::VideoCodec::AV1, 3)) {
                std::cout << "[Host] AV1 unavailable, trying H.264...\n";
                try_mf_codec(immersive::VideoCodec::H264, 0);
            }
            break;
        default:
            break;  // MJPEG requested
        }

        if (!stream_encoder) {
            if (requested_codec != 2) {
                std::cout << "[Host] Falling back to software MJPEG on monitor "
                          << (int)monitor_id << "\n";
            }
            stream_encoder = immersive::create_encoder(immersive::EncoderBackend::SOFTWARE);
            actual_codec   = 2;
            enc_config.width  = out_w;
            enc_config.height = out_h;
            if (!stream_encoder->initialize(enc_config)) {
                std::cerr << "[Host] Software encoder failed too, aborting stream\n";
                stream_capture->stop_capture();
                return;
            }
        }
        if (enc_config.width != out_w || enc_config.height != out_h) {
            std::cout << "[Host] Monitor " << (int)monitor_id << ": " << out_w << "x" << out_h
                      << " streams at " << enc_config.width << "x" << enc_config.height
                      << " (H.264 Level 5.2)\n";
            out_w = enc_config.width;
            out_h = enc_config.height;
        }

        const bool is_mjpeg = (actual_codec == 2);
        const bool cpu_encoder = !is_mjpeg &&
            stream_encoder->backend() == immersive::EncoderBackend::SOFTWARE;

        // The client's settings are ceilings: retune() scales them to what the
        // link carries (the server's rate control, from FRAME_ACKs) and what
        // this thread encodes in time, and applies that to the running encoder.
        uint32_t ceil_kbps = 0, ceil_quality = 0, fps_cap = 0;
        auto take_cfg = [&](const immersive::protocol::StreamConfig& c) {
            ceil_kbps = c.bitrate_kbps > 0 ? std::min<uint32_t>(c.bitrate_kbps, 100000)
                                           : immersive::EncoderConfig{}.bitrate_kbps;
            ceil_quality = (c.jpeg_quality >= 10 && c.jpeg_quality <= 95) ? c.jpeg_quality
                                                                          : jpeg_quality.load();
            // FPS cap: explicit from the client, otherwise 24 for MJPEG (Wi-Fi
            // friendly), 30 for a CPU H.264 encoder (libx264 needs ~22 ms for
            // a 1920x1200 frame on a 2025 laptop), else the refresh rate.
            const uint32_t hz = display.refresh_rate ? display.refresh_rate : 60;
            fps_cap = c.max_fps > 0 ? c.max_fps
                    : is_mjpeg ? 24u : cpu_encoder ? std::min(30u, hz) : hz;
            fps_cap = std::max(1u, std::min(fps_cap, 120u));
        };
        take_cfg(cfg);

        uint32_t cpu_fps = 120;  // what this thread encodes in time (measured below)
        uint32_t fps = fps_cap;  // paced rate: the cap, lowered for the link / the CPU
        auto min_interval = std::chrono::microseconds(1000000u / fps);
        bool auto_tune = true;   // off once the encoder refused a live change

        // `forced`: the client changed its settings, which must take effect
        // (re-opening the encoder if it can't retune live). Returns false only
        // when that re-open failed and the stream is dead.
        auto retune = [&](bool forced) -> bool {
            const float share = server->link_rate_scale(client_id);
            immersive::EncoderConfig c = enc_config;
            uint32_t f = std::min(fps_cap, cpu_fps);
            if (is_mjpeg) {
                // A JPEG's size follows its quality, the stream's also the frame rate.
                c.jpeg_quality = 10 + static_cast<uint32_t>((ceil_quality - 10) * share + 0.5f);
                f = std::min(f, std::max(1u, static_cast<uint32_t>(
                                                 fps_cap * std::min(1.0f, 2 * share) + 0.5f)));
            } else {
                c.bitrate_kbps = link_kbps(ceil_kbps);
            }
            c.fps = f;
            const bool same = c.fps == enc_config.fps && c.jpeg_quality == enc_config.jpeg_quality;
            // Automatic: a cut at once (the server cuts by 30 %), a raise once
            // it adds up to 25 % or reaches the ceiling. On VAAPI every change
            // is a re-open (an IDR, a 20-40 ms stall), so the climb from half
            // rate is three of them instead of one a second for six seconds.
            const uint32_t kbps = c.bitrate_kbps, cur = enc_config.bitrate_kbps;
            const bool minor = kbps >= cur ? kbps == cur || (kbps * 4 < cur * 5 && kbps != ceil_kbps)
                                           : kbps * 20 > cur * 19;
            if (same && (forced ? kbps == cur : minor)) return true;
            if (!forced && !auto_tune) return true;

            immersive::EncoderConfig live = c;
            bool ok = stream_encoder->reconfigure(live);
            if (!ok && c.fps != enc_config.fps) {
                live.fps = enc_config.fps;  // Media Foundation: the rate live, not the frame rate
                ok = stream_encoder->reconfigure(live);
            }
            if (!ok && forced) {
                // Re-open at the same size and codec: the stream goes on from
                // an IDR, and the client keeps its decoder.
                live = c;
                if (!stream_encoder->initialize(live)) return false;
                ok = true;
            }
            if (!ok) {
                auto_tune = false;
                std::cout << "[Host] Monitor " << (int)monitor_id << ": " << stream_encoder->name()
                          << " cannot change its rate while running; adaptive bitrate off\n";
                return true;
            }
            enc_config = live;
            fps = f;
            min_interval = std::chrono::microseconds(1000000u / fps);
            if (forced) {
                std::cout << "[Host] Monitor " << (int)monitor_id << " retuned: "
                          << (is_mjpeg ? "JPEG quality " + std::to_string(live.jpeg_quality)
                                       : std::to_string(live.bitrate_kbps) + " kbps")
                          << ", " << fps << " fps\n";
            }
            return true;
        };
        retune(false);  // this client's current link share, the CPU default

        // Register the mouse-coordinate scale for this monitor
        {
            std::lock_guard<std::mutex> lock(input_scale_mutex);
            input_scale[monitor_id] = {
                static_cast<double>(display.width)  / out_w,
                static_cast<double>(display.height) / out_h,
                display.width, display.height, ctx
            };
        }

        // Frame numbers keep growing across restarts of this monitor's stream
        // (with a margin for a previous worker still winding down), so the
        // client can tell this stream's frames from late ones of the last.
        const uint32_t first_frame = frame_high_water[monitor_id].load() + 1000;

        immersive::protocol::StreamStart start_info = {};
        start_info.monitor_id  = monitor_id;
        start_info.width       = static_cast<uint16_t>(out_w);
        start_info.height      = static_cast<uint16_t>(out_h);
        start_info.codec       = actual_codec;  // 0=H264 1=HEVC 2=MJPEG 3=AV1
        start_info.first_frame = first_frame;
        server->send_stream_start(client_id, start_info);
        ctx->codec = actual_codec;
        ctx->width = static_cast<uint16_t>(out_w);
        ctx->height = static_cast<uint16_t>(out_h);
        ctx->fps_cap = fps_cap;

        std::cout << "[Host] Streaming monitor " << (int)monitor_id
                  << " to client " << client_id
                  << " at " << out_w << "x" << out_h
                  << " (native " << display.width << "x" << display.height << ")"
                  << " cap " << fps_cap << " fps, "
                  << (is_mjpeg ? "JPEG quality " + std::to_string(enc_config.jpeg_quality)
                               : std::to_string(enc_config.bitrate_kbps) + " of "
                                     + std::to_string(ceil_kbps) + " kbps to start")
                  << "\n";

        std::vector<uint8_t> scaled;

        live_stream_count++;
        uint32_t frame_number = first_frame;
        auto last_sent = std::chrono::steady_clock::time_point{};

        // On-demand IDRs at most every 200 ms: a client that keeps asking
        // while the last one is still on its way gets it once, not per ask.
        // The first frame is one.
        ctx->force_keyframe = true;
        auto last_idr = std::chrono::steady_clock::time_point{};
        const auto kIdrGap = std::chrono::milliseconds(200);

        // Encoder overload, software encoders only (libx264, MJPEG): the CPU
        // time of one frame (scale + encode) against the frame interval. A
        // CPU encoder that can't keep up otherwise delivers whatever rate it
        // manages while budgeting its bits for frames that never come; paced
        // to what it holds, with 15% headroom, the frames it does send get
        // the whole bitrate. (A GPU encoder that is slow simply takes the
        // newest frame when it is free; pacing it below that only lost frames,
        // and on VAAPI every new frame rate meant a re-open and an IDR.)
        // Judged only on freshly captured frames (a re-sent still frame is
        // not the load of a moving screen) and after the slow first frames.
        const bool cpu_paced = stream_encoder->backend() == immersive::EncoderBackend::SOFTWARE;
        double busy_ms = 0;        // moving average
        uint32_t encoded = 0;      // frames encoded, all time
        uint32_t tick_frames = 0;  // since the last tune tick
        auto next_tune = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);

        // The newest captured frame, and whether it still has to be sent.
        // Event-driven backends (WGC, ScreenCaptureKit, PipeWire) deliver
        // nothing while the screen is static, so a frame the pacing below
        // skipped — the last keystroke, the final position of a dragged
        // window — would otherwise stay unsent until something else changes,
        // and a keyframe the client asks for after Wi-Fi loss would never
        // come. Both are served from this frame when the capture goes idle.
        std::unique_ptr<immersive::CapturedFrame> last_frame;
        bool last_frame_unsent = false;
        // Still-screen refinement (inter codecs): once the screen stops
        // changing an event-driven capture sends nothing more, so the last
        // frame would stay at the quality its bit budget allowed in motion
        // (or an IDR's). It is re-encoded as P-frames at the paced rate this
        // many times after each change or IDR, which brings static text from
        // ~30 to ~54 dB PSNR in about 20 frames (VAAPI and libx264, measured),
        // then every second as a keepalive (a few hundred bytes).
        constexpr uint32_t kRefineFrames = 30;
        uint32_t refine_left = 0;

        while (g_running && !ctx->stop) {
            // Wake when a held or refining frame is due, not a whole capture
            // interval later: waiting for the next capture made a frame held
            // by the pacing go out up to one capture interval late (measured:
            // 28 fps out of a 40 fps pace).
            uint32_t wait_ms = 16;  // ~60 fps
            if (last_frame && (last_frame_unsent || refine_left > 0)) {
                const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                    last_sent + min_interval - std::chrono::steady_clock::now()).count();
                wait_ms = static_cast<uint32_t>(std::clamp<long long>(left, 1, 16));
            }
            auto frame = stream_capture->acquire_frame(wait_ms);
            auto now = std::chrono::steady_clock::now();
            bool resend = false;  // frame is last_frame again, not a new capture

            if (ctx->cfg_changed.exchange(false)) {
                immersive::protocol::StreamConfig c;
                {
                    std::lock_guard<std::mutex> lock(ctx->cfg_mutex);
                    c = ctx->new_cfg;
                }
                take_cfg(c);
                if (!retune(true)) {
                    std::cerr << "[Host] Encoder failed to re-open on monitor "
                              << (int)monitor_id << ", stopping its stream\n";
                    break;
                }
            }
            if (now >= next_tune) {
                next_tune = now + std::chrono::milliseconds(500);
                if (cpu_paced && busy_ms > 0 && tick_frames >= 5) {
                    const uint32_t can = std::min(fps_cap, std::max(5u,
                        static_cast<uint32_t>(1000.0 / (busy_ms * 1.15))));
                    const uint32_t cur = std::min(cpu_fps, fps_cap);
                    if (can + 2 < cur || can >= cur + 5 || (can == fps_cap && cur < fps_cap)) {
                        cpu_fps = can;
                        std::cout << "[Host] Monitor " << (int)monitor_id << ": a frame takes "
                                  << static_cast<int>(busy_ms + 0.5) << " ms to encode, "
                                  << (can < fps_cap ? "streaming at " + std::to_string(can) + " of "
                                                    : std::string("back to "))
                                  << fps_cap << " fps\n";
                    }
                }
                tick_frames = 0;
                retune(false);
            }

            if (!frame && stream_capture->is_capturing() && last_frame) {
                const bool due = now - last_sent >= min_interval;
                if (((last_frame_unsent || refine_left > 0) && due) ||
                    (ctx->force_keyframe && now - last_idr >= kIdrGap) ||
                    now - last_sent >= std::chrono::seconds(1)) {
                    resend = !last_frame_unsent;
                    frame = std::move(last_frame);  // idle: (re)send the newest
                }
            }
            if (!frame) {
                // A backend that lost its source for good (monitor unplugged,
                // screen-share revoked, compositor restart) stops capturing
                // and returns nullptr at once; without this the loop spins a
                // core. Restart it with a pause, like the initial start.
                if (!stream_capture->is_capturing()) {
                    for (int i = 0; i < 10 && g_running && !ctx->stop; ++i)
                        std::this_thread::sleep_for(std::chrono::milliseconds(100));
                    if (g_running && !ctx->stop) {
                        if (!stream_capture->start_capture(monitor_id)) {
                            std::cerr << "[Host] Capture lost on monitor "
                                      << (int)monitor_id << ", retrying...\n";
                        } else {
                            for (const auto& d : refresh_input_displays()) {
                                if (d.id != monitor_id || !d.width || !d.height) continue;
                                std::lock_guard<std::mutex> lock(input_scale_mutex);
                                input_scale[monitor_id] = {
                                    static_cast<double>(d.width) / out_w,
                                    static_cast<double>(d.height) / out_h,
                                    d.width, d.height, ctx};
                            }
                        }
                    }
                }
                continue;
            }

            // Frame pacing
            if (last_sent.time_since_epoch().count() != 0 &&
                now - last_sent < min_interval) {
                last_frame = std::move(frame);
                last_frame_unsent = true;
                continue;
            }

            const uint8_t* pixels = frame->pixels.data();
            uint32_t w = frame->width, h = frame->height, pitch = frame->pitch;

            // Scale whenever the frame is not the announced stream size: a
            // client downscale, but also a frame whose size differs from the
            // enumerated one (HiDPI/fractional scaling, a resolution change
            // mid-stream). The encoder is fixed at out_w x out_h.
            if ((w != out_w || h != out_h) && !stream_encoder->scales_input()) {
                scaled.resize(static_cast<size_t>(out_w) * out_h * 4);
                scale_bgra_bilinear(pixels, w, h, pitch,
                                    scaled.data(), out_w, out_h);
                pixels = scaled.data();
                w = out_w; h = out_h; pitch = out_w * 4;
            }

            // An IDR when the client asks (recovery after packet loss, a
            // no-op for MJPEG whose every frame stands alone) and first.
            if (ctx->force_keyframe && now - last_idr >= kIdrGap) {
                ctx->force_keyframe = false;
                stream_encoder->request_keyframe();
                last_idr = now;
            }

            auto packets = stream_encoder->encode(
                pixels, w, h, pitch, frame->timestamp_us);
            const double work_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - now).count();
            if (!resend && ++encoded > 5) {
                busy_ms = busy_ms > 0 ? busy_ms * 0.95 + work_ms * 0.05 : work_ms;
                ++tick_frames;
            }
            bool key = false;
            for (const auto& pkt : packets) key = key || pkt.is_keyframe;
            if (is_mjpeg) refine_left = 0;
            else if (!resend || key) refine_left = kRefineFrames;
            else if (refine_left > 0) --refine_left;

            for (const auto& pkt : packets) {
                server->send_video_packet(
                    client_id,
                    monitor_id,
                    frame_number,
                    pkt.data.data(),
                    static_cast<uint32_t>(pkt.data.size()));
                ctx->bytes += pkt.data.size();
            }
            if (!packets.empty()) {
                frame_high_water[monitor_id].store(frame_number);
                frame_number++;  // number only frames actually sent
                ctx->frames++;
                last_sent = now;
            }
            last_frame = std::move(frame);
            last_frame_unsent = false;
        }

        live_stream_count--;
        {
            std::lock_guard<std::mutex> lock(input_scale_mutex);
            auto it = input_scale.find(monitor_id);
            if (it != input_scale.end() && it->second.owner == ctx) input_scale.erase(it);
        }
        stream_capture->stop_capture();
        std::cout << "[Host] Stopped streaming monitor " << (int)monitor_id << "\n";
    };

    // Stop workers without letting a stuck one hold up the caller: ask all of
    // them to stop, wait up to 5 s (a TCP-media send can hold one for its 3 s
    // SO_SNDTIMEO), join the ones that returned and park the rest for the
    // main loop.
    auto retire = [&](std::vector<std::unique_ptr<ActiveStream>> ctxs) {
        for (auto& c : ctxs) c->stop = true;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        for (auto& c : ctxs) {
            while (!c->done && std::chrono::steady_clock::now() < deadline)
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            if (c->done) {
                if (c->worker.joinable()) c->worker.join();
                continue;
            }
            std::cerr << "[Host] A stream worker is stuck in its capture backend;"
                         " it will be cleaned up when it returns\n";
            std::lock_guard<std::mutex> lock(graveyard_mutex);
            graveyard.push_back(std::move(c));
        }
    };

    auto send_stream_stop = [&](uint32_t client_id, uint8_t monitor_id) {
        immersive::protocol::StreamStop stop_msg = { monitor_id };
        server->send_control_message(client_id,
                                     immersive::protocol::MessageType::STREAM_STOP,
                                     &stop_msg, sizeof(stop_msg));
    };

    // Stop every stream. Caller holds ops_mutex.
    auto stop_all_locked = [&](bool notify_client) {
        std::vector<uint8_t> ids;
        std::vector<std::unique_ptr<ActiveStream>> ctxs;
        {
            std::lock_guard<std::mutex> lock(streams_mutex);
            for (auto& [id, ctx] : active_streams) {
                ids.push_back(id);
                ctxs.push_back(std::move(ctx));
            }
            active_streams.clear();
        }
        retire(std::move(ctxs));
        if (notify_client)
            for (uint8_t id : ids) send_stream_stop(streams_client_id, id);
    };

    // Reconcile the set of active streams with the client's selection:
    // stops deselected monitors, starts newly selected ones, keeps the rest.
    // Caller holds ops_mutex.
    auto apply_selection_locked = [&](uint32_t client_id, std::vector<uint8_t> ids) {
        if (ids.size() > 3) ids.resize(3);  // protocol limit

        // Stop streams that are no longer selected (or belong to another client)
        std::vector<uint8_t> stopped_ids;
        std::vector<std::unique_ptr<ActiveStream>> stopping;
        {
            std::lock_guard<std::mutex> lock(streams_mutex);
            for (auto it = active_streams.begin(); it != active_streams.end();) {
                const bool keep = (client_id == streams_client_id) &&
                                  std::find(ids.begin(), ids.end(), it->first) != ids.end();
                if (keep) { ++it; continue; }
                stopped_ids.push_back(it->first);
                stopping.push_back(std::move(it->second));
                it = active_streams.erase(it);
            }
        }
        retire(std::move(stopping));
        for (uint8_t id : stopped_ids) send_stream_stop(streams_client_id, id);

        if (client_id != streams_client_id) {
            // Another client takes over: whatever the previous one held down
            // would stay pressed, since its input is ignored from now on.
            input_client_id = client_id;
            release_input();
            std::lock_guard<std::mutex> lock(streams_mutex);
            streams_client_id = client_id;
        }

        // Start newly selected streams
        for (uint8_t id : ids) {
            {
                std::lock_guard<std::mutex> lock(streams_mutex);
                if (active_streams.count(id)) continue;
            }

            immersive::DisplayInfo display;
            bool found = false;
            {
                std::lock_guard<std::mutex> lock(displays_mutex);
                for (const auto& d : displays) {
                    if (d.id == id) { display = d; found = true; break; }
                }
            }
            if (!found) {
                std::cerr << "[Host] Monitor " << (int)id << " not found\n";
                continue;
            }

            auto ctx = std::make_unique<ActiveStream>();
            ActiveStream* ctx_ptr = ctx.get();
            immersive::protocol::StreamConfig cfg_snapshot = stream_cfg;
            ctx->worker = std::thread(
                [&stream_worker, client_id, display, cfg_snapshot, ctx_ptr]() {
                    stream_worker(client_id, display, cfg_snapshot, ctx_ptr);
                    ctx_ptr->done = true;
                });
            std::lock_guard<std::mutex> lock(streams_mutex);
            active_streams[id] = std::move(ctx);
        }
    };

    auto apply_selection = [&](uint32_t client_id, std::vector<uint8_t> ids) {
        std::lock_guard<std::mutex> ops(ops_mutex);
        apply_selection_locked(client_id, std::move(ids));
    };

    auto stop_all_streams = [&](bool notify_client) {
        std::lock_guard<std::mutex> ops(ops_mutex);
        stop_all_locked(notify_client);
    };

    // Set up server callbacks
    server->set_on_client_connected([&](uint32_t client_id) {
        std::cout << "[Host] Client " << client_id << " connected, sending monitor list\n";
        std::vector<immersive::protocol::MonitorInfo> monitors;
        std::vector<uint8_t> flags;
        {
            std::lock_guard<std::mutex> lock(displays_mutex);
            monitors = proto_monitors;
            flags = monitor_flags;
        }
        server->send_monitor_list(client_id, monitors, flags);

        // Notify about audio stream if enabled
        if (audio_enable && settings.audio) {
            immersive::protocol::AudioStart astart;
            astart.sample_rate = 48000;
            astart.channels    = 2;
            astart.audio_port  = audio_port;
            server->send_control_message(
                client_id,
                immersive::protocol::MessageType::AUDIO_START,
                &astart,
                sizeof(astart));
            std::cout << "[Host] Audio stream available on UDP:" << audio_port << "\n";
        }
    });

    // --- Main screen off ---
    // A headset can darken the PC's main monitor while it works on it in VR
    // (it keeps streaming). Never without a headset: the client that turned
    // it off holds a lease it renews every 2 s (protocol::ScreenOff), and the
    // screen is lit again when that lease runs out, when that client leaves,
    // in view-only and on exit. Each connection starts with it lit.
    // screen_off_client (0 = lit) changes under ops_mutex.
    std::atomic<uint32_t> screen_off_client{0};
    std::atomic<int64_t>  screen_off_until_ms{0};
    auto steady_ms = [] {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
    };
    auto send_screen_off = [&](uint32_t client_id, bool off) {
        immersive::protocol::ScreenOff msg{static_cast<uint8_t>(off ? 1 : 0)};
        server->send_control_message(client_id, immersive::protocol::MessageType::SCREEN_OFF,
                                     &msg, sizeof(msg));
    };
    auto light_screen_locked = [&](const char* why) {
        const uint32_t owner = screen_off_client.exchange(0);
        if (!owner) return;
        vdm->set_primary_off(false);
        std::cout << "[Host] Main screen on (" << why << ")\n";
        send_screen_off(owner, false);
    };
    server->set_on_screen_off([&](uint32_t client_id, bool off) {
        std::lock_guard<std::mutex> ops(ops_mutex);
        const uint32_t owner = screen_off_client;
        if (!off) {
            if (owner) light_screen_locked("asked by the headset");
            if (owner != client_id) send_screen_off(client_id, false);
            return;
        }
        if (!owner) {
            if (view_only || !vdm->set_primary_off(true)) {
                send_screen_off(client_id, false);  // no: its switch goes back
                return;
            }
            std::cout << "[Host] Main screen off: client " << client_id
                      << " works on it in the headset\n";
        } else {
            vdm->set_primary_off(true);  // again: GNOME restores its ramp on monitor changes
        }
        screen_off_until_ms = steady_ms() + immersive::protocol::SCREEN_OFF_LEASE_MS;
        screen_off_client = client_id;
        if (owner != client_id) send_screen_off(client_id, true);
    });

    server->set_on_client_disconnected([&](uint32_t client_id) {
        std::cout << "[Host] Client " << client_id << " disconnected\n";
        // Check and stop under one lock: another client taking over in
        // between must not have its fresh streams killed.
        std::lock_guard<std::mutex> ops(ops_mutex);
        if (client_id == screen_off_client) light_screen_locked("its headset left");
        if (client_id != streams_client_id) return;
        stop_all_locked(false);
        input_client_id = 0;
        release_input();  // a drag or key held when Wi-Fi dropped
    });

    server->set_on_monitor_select([&](uint32_t client_id, uint8_t monitor_id) {
        std::cout << "[Host] Client " << client_id
                  << " selected monitor " << (int)monitor_id << "\n";
        apply_selection(client_id, {monitor_id});
    });

    server->set_on_multi_monitor_select(
        [&](uint32_t client_id, const std::vector<uint8_t>& monitor_ids) {
            apply_selection(client_id, monitor_ids);
        });

    // A new stream configuration. Bitrate, JPEG quality and frame rate are
    // retuned in the running workers: the picture goes on. A new codec or
    // size restarts the active streams, STREAM_STOP first for each monitor:
    // the client rebuilds its panel and decoder from the following
    // STREAM_START, and an Android panel that kept its old ExternalTexture
    // would otherwise show a frozen image.
    // One ops_mutex hold: no other client's selection can slip in between.
    server->set_on_stream_config(
        [&](uint32_t client_id, const immersive::protocol::StreamConfig& cfg) {
            std::lock_guard<std::mutex> ops(ops_mutex);
            std::vector<uint8_t> ids;
            const bool same_picture = cfg.codec == stream_cfg.codec &&
                                      cfg.max_width == stream_cfg.max_width;
            {
                std::lock_guard<std::mutex> lock(streams_mutex);
                if (!active_streams.empty() && client_id != streams_client_id) {
                    return;  // only the streaming client may reconfigure
                }
                for (const auto& [id, ctx] : active_streams) {
                    ids.push_back(id);
                    if (!same_picture) continue;
                    std::lock_guard<std::mutex> cfg_lock(ctx->cfg_mutex);
                    ctx->new_cfg = cfg;
                    ctx->cfg_changed = true;
                }
            }
            stream_cfg = cfg;  // after the check: a bystander client must
                               // not poison the next restart's settings
            if (same_picture) return;
            stop_all_locked(true);
            if (!ids.empty()) apply_selection_locked(streams_client_id, ids);
        });

    // --view-only: the headsets watch, they never drive this PC.
    std::atomic<bool> view_only_logged{false};
    auto refuse_input = [&]() {
        if (!view_only) return false;
        if (!view_only_logged.exchange(true))
            std::cout << "[Host] View-only: ignoring mouse and keyboard from headsets\n";
        return true;
    };

    server->set_on_input_mouse([&](uint32_t client_id,
                                   const immersive::protocol::InputMouse& input) {
        if (refuse_input()) return;
        if (client_id != input_client_id) return;  // a second headset or the web bridge
        // Mouse coordinates arrive in stream pixels; map them to native
        // monitor pixels when the stream is downscaled, clamped to the
        // monitor (casting a double past uint16 is UB, and in practice wraps
        // an overshoot to the opposite edge).
        immersive::protocol::InputMouse scaled_input = input;
        {
            std::lock_guard<std::mutex> lock(input_scale_mutex);
            auto it = input_scale.find(input.monitor_id);
            if (it != input_scale.end()) {
                const InputScale& sc = it->second;
                scaled_input.x = static_cast<uint16_t>(
                    std::min<double>(input.x * sc.sx, sc.native_w - 1));
                scaled_input.y = static_cast<uint16_t>(
                    std::min<double>(input.y * sc.sy, sc.native_h - 1));
            }
        }
        std::lock_guard<std::mutex> lock(input_mutex);
        input_injector->inject_mouse(scaled_input);
        held_mouse = scaled_input;
    });

    server->set_on_input_keyboard([&](uint32_t client_id,
                                      const immersive::protocol::InputKeyboard& input) {
        if (refuse_input()) return;
        if (client_id != input_client_id) return;
        // The client's VR keyboard latches Shift/Ctrl/Alt/Win itself and only
        // reports them in `modifiers`, never as key events. Press them around
        // the key, or Shift+A types 'a'.
        struct Mod { uint8_t bit; uint16_t vk; };
        static constexpr Mod kMods[] = {{0x01, 0x10}, {0x02, 0x11}, {0x04, 0x12}, {0x08, 0x5B}};
        const bool is_modifier = (input.scancode >= 0x10 && input.scancode <= 0x12) ||
                                 (input.scancode >= 0xA0 && input.scancode <= 0xA5) ||
                                 input.scancode == 0x5B || input.scancode == 0x5C;
        std::lock_guard<std::mutex> lock(input_mutex);
        auto key = [&](uint16_t vk, bool down) {
            immersive::protocol::InputKeyboard k = input;
            k.scancode = vk;
            k.pressed  = down ? 1 : 0;
            input_injector->inject_keyboard(k);
            if (down) held_keys.insert(vk); else held_keys.erase(vk);
        };
        auto send_mods = [&](bool down) {
            if (is_modifier) return;
            for (const Mod& m : kMods)
                if (input.modifiers & m.bit) key(m.vk, down);
        };
        if (input.pressed) send_mods(true);
        key(input.scancode, input.pressed != 0);
        if (!input.pressed) send_mods(false);
    });

    // Client lost a frame and asks for an IDR so its inter-frame decoder can
    // recover immediately (instead of waiting for the next periodic keyframe).
    server->set_on_request_keyframe([&](uint32_t client_id, uint8_t monitor_id) {
        std::lock_guard<std::mutex> lock(streams_mutex);
        if (client_id != streams_client_id) return;
        auto it = active_streams.find(monitor_id);
        if (it != active_streams.end()) {
            it->second->force_keyframe = true;
        }
    });

    // --- Virtual displays ---
    // Re-read the monitors after one came or went: the list clients see,
    // the input mapping and the count in HELLO_ACK / discovery. Returns
    // whether `want` (if not 0xFF) is in the new list. Caller holds ops_mutex.
    auto refresh_displays = [&](uint8_t want) {
        auto probe = make_capture();
        auto fresh = probe ? probe->enumerate_displays()
                           : std::vector<immersive::DisplayInfo>{};
        bool has = want == 0xFF;
        for (const auto& d : fresh) has = has || d.id == want;
        {
            std::lock_guard<std::mutex> lock(displays_mutex);
            displays = fresh;
            build_proto_monitors();
            server->set_monitor_count(static_cast<uint8_t>(std::min<size_t>(displays.size(), 255)));
        }
        {
            std::lock_guard<std::mutex> lock(input_mutex);
            input_injector->set_displays(fresh);
        }
        return has;
    };
    auto broadcast_monitor_list = [&]() {
        std::vector<immersive::protocol::MonitorInfo> monitors;
        std::vector<uint8_t> flags;
        {
            std::lock_guard<std::mutex> lock(displays_mutex);
            monitors = proto_monitors;
            flags = monitor_flags;
        }
        server->send_monitor_list(0, monitors, flags);
    };
    auto send_vresult = [&](uint32_t client_id, uint8_t status, bool removed, uint8_t id) {
        immersive::protocol::VirtualDisplayResult r{status, static_cast<uint8_t>(removed ? 1 : 0), id};
        server->send_control_message(client_id,
                                     immersive::protocol::MessageType::VIRTUAL_DISPLAY_RESULT,
                                     &r, sizeof(r));
    };

    server->set_on_virtual_display_create(
        [&](uint32_t client_id, const immersive::protocol::VirtualDisplayCreate& req) {
            namespace p = immersive::protocol;
            std::lock_guard<std::mutex> ops(ops_mutex);
            uint8_t status = p::VDISPLAY_OK, id = 0xFF;
            if (!vdm_ok) {
                status = p::VDISPLAY_UNSUPPORTED;
            } else if (vdm->get_active_displays().size() >= p::MAX_VIRTUAL_DISPLAYS) {
                status = p::VDISPLAY_LIMIT;
            } else {
                immersive::VirtualDisplayConfig c;
                // Even sizes (encoders), within what every backend accepts.
                c.width  = static_cast<uint16_t>(std::clamp<int>(req.width, 640, 7680) & ~1);
                c.height = static_cast<uint16_t>(std::clamp<int>(req.height, 480, 4320) & ~1);
                c.refresh_rate = req.refresh_rate ? std::clamp<uint8_t>(req.refresh_rate, 24, 144) : 60;
                id = vdm->create_display(c);
                // A new monitor can take a moment to show up (macOS).
                bool listed = id != 0;
                for (int i = 0; listed && !refresh_displays(id); ++i) {
                    if (i == 30) { listed = false; break; }
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
                }
                if (!listed) {
                    if (id) vdm->remove_display(id);
                    refresh_displays(0xFF);
                    status = p::VDISPLAY_FAILED;
                    id = 0xFF;
                }
                std::cout << "[Host] Client " << client_id << " asked for a " << c.width << "x"
                          << c.height << " virtual screen: "
                          << (status == p::VDISPLAY_OK ? "monitor " + std::to_string(id)
                                                       : std::string("failed")) << "\n";
            }
            send_vresult(client_id, status, false, id);
            if (status == p::VDISPLAY_OK) broadcast_monitor_list();
        });

    // Remove a virtual screen this host made (from a headset or the panel).
    // Caller holds ops_mutex and then broadcasts the monitor list.
    auto remove_virtual_locked = [&](uint8_t id) {
        const auto active = vdm->get_active_displays();
        if (std::find(active.begin(), active.end(), id) == active.end()) return false;
        // Stop its stream first (STREAM_STOP to whoever watches it).
        std::vector<uint8_t> keep;
        bool streaming = false;
        {
            std::lock_guard<std::mutex> lock(streams_mutex);
            for (const auto& [sid, ctx] : active_streams) {
                if (sid == id) streaming = true; else keep.push_back(sid);
            }
        }
        if (streaming) apply_selection_locked(streams_client_id, keep);
        vdm->remove_display(id);
        refresh_displays(0xFF);
        return true;
    };

    server->set_on_virtual_display_remove([&](uint32_t client_id, uint8_t id) {
        namespace p = immersive::protocol;
        std::lock_guard<std::mutex> ops(ops_mutex);
        if (!remove_virtual_locked(id)) {
            send_vresult(client_id, vdm_ok ? p::VDISPLAY_FAILED : p::VDISPLAY_UNSUPPORTED, true, id);
            return;
        }
        std::cout << "[Host] Client " << client_id << " removed virtual monitor " << (int)id << "\n";
        send_vresult(client_id, p::VDISPLAY_OK, true, id);
        broadcast_monitor_list();
    });

    // --- USB ---
    // A headset on a USB cable reaches the host through `adb reverse`: its
    // 127.0.0.1:<tcp_port> tunnels to ours, and the app finds and prefers
    // that on its own. Only TCP can be tunnelled, so the client asks for
    // video/audio in-band on TCP (HELLO_FLAG_TCP_MEDIA). The adb server is
    // started HERE, before any socket is opened (see start_adb()).
    // Only an adb server started here, before the sockets, is used: turning
    // USB on later in the panel takes effect on the next start.
    const std::string adb = usb_enable ? immersive::start_adb() : "";
    const bool adb_started = !adb.empty(), adb_missing = usb_enable && adb.empty();
    if (usb_enable && adb.empty()) {
        std::cout << "[Host] USB: adb not found (PATH, Android SDK folders); install Android\n"
                  << "       platform-tools to use a USB cable. Wi-Fi still works.\n";
    } else if (usb_enable) {
        std::cout << "[Host] USB: plug in the headset (USB debugging on) and it uses the cable"
                  << " by itself (" << adb << ")\n";
    }

    // Start the network server with configured options
    immersive::ServerConfig srv_config;
    srv_config.tcp_port    = tcp_port;
    srv_config.udp_port    = udp_port;
    srv_config.max_clients = max_clients;
    srv_config.monitor_count = static_cast<uint8_t>(std::min<size_t>(displays.size(), 255));
    const bool screen_off_ok = vdm->can_turn_off_primary();
    srv_config.host_flags = (view_only ? immersive::protocol::HOST_FLAG_VIEW_ONLY : 0) |
                            (vdm_ok ? immersive::protocol::HOST_FLAG_VIRTUAL_DISPLAYS : 0) |
                            (screen_off_ok ? immersive::protocol::HOST_FLAG_SCREEN_OFF : 0);
    // With --no-pin an existing PIN is kept for when the panel turns it back on.
    settings.pin = pin_arg > 0 ? static_cast<uint32_t>(pin_arg)
                 : pin_arg < 0 ? load_or_create_pin()
                               : [] { uint32_t p = 0; std::ifstream(config_dir() / "pairing-pin") >> p; return p; }();
    settings.pin_enabled = pin_arg != 0;
    srv_config.pin = settings.pin_enabled ? settings.pin.load() : 0;

    // A headset asked to pair: show the PIN on this PC's screen, since the
    // host may be running with no visible console. At most one every 5 s.
    server->set_on_pin_requested([&settings](const std::string& peer_ip) {
        static std::atomic<int64_t> last_s{-5};
        const int64_t now = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        int64_t prev = last_s.load();
        if (now - prev < 5 || !last_s.compare_exchange_strong(prev, now)) return;
        const std::string p = std::to_string(settings.pin.load());
        notify_desktop("Immersive-2 PIN: " + p.substr(0, 3) + " " + p.substr(3),
                       "A headset at " + peer_ip + " wants to connect. Type this PIN in it.");
    });

    if (!server->start(srv_config)) {
        std::cerr << "[Host] Failed to start network server\n";
        return 1;
    }

    // --- Audio streaming thread ---
    std::thread audio_thread;
    if (audio_enable) {
        audio_thread = std::thread([&]() {
            // 288 stereo frames (6 ms) = 1160-byte packets: under any Wi-Fi
            // MTU, so a packet is never IP-fragmented (one lost fragment
            // loses the whole datagram).
            constexpr size_t kFramesPerPacket = 288;
            uint32_t seq = 0;
            std::vector<uint8_t> pkt;
            while (g_running) {
                if (!settings.audio) {  // switched off in the panel
                    if (audio_capture) { audio_capture->stop(); audio_capture.reset(); }
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
                    continue;
                }
                if (!audio_capture) {   // switched (back) on
                    audio_capture = immersive::create_audio_capture();
                    if (!audio_capture || !audio_capture->start()) {
                        std::cerr << "[Host] Audio capture failed to start\n";
                        audio_capture.reset();
                        settings.audio = false;
                        continue;
                    }
                }
                auto audio_frame = audio_capture->get_frame();
                if (!audio_frame) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(5));
                    continue;
                }
                // Nobody streaming: drop it, so the next stream starts with
                // live audio instead of a backlog.
                if (live_stream_count == 0 || audio_frame->channels == 0) continue;

                const size_t ch = audio_frame->channels;
                const size_t total = audio_frame->samples.size() / ch;
                for (size_t off = 0; off < total; off += kFramesPerPacket) {
                    const size_t n = std::min(kFramesPerPacket, total - off);
                    immersive::protocol::AudioPacketHeader ahdr;
                    ahdr.seq      = seq++;
                    ahdr.samples  = static_cast<uint16_t>(n);
                    ahdr.channels = audio_frame->channels;
                    ahdr.reserved = 0;
                    const size_t pcm_bytes = n * ch * sizeof(int16_t);
                    pkt.resize(sizeof(ahdr) + pcm_bytes);
                    std::memcpy(pkt.data(), &ahdr, sizeof(ahdr));
                    std::memcpy(pkt.data() + sizeof(ahdr),
                                audio_frame->samples.data() + off * ch, pcm_bytes);
                    server->broadcast_udp(pkt.data(), pkt.size(), audio_port);
                }
            }
        });
    }

    // What the person at the PC needs to connect the headset: the app finds
    // this PC by itself on the LAN, so the PIN is the one thing to type.
    const std::string lan_ip = immersive::primary_ipv4();
    std::cout << "\n[Host] Ready. Waiting for VR client connections (max " << max_clients << ")...\n"
              << "\n    PC name   " << immersive::local_host_name() << "\n"
              << "    Address   " << (lan_ip.empty() ? "no network" : lan_ip) << "\n";
    if (srv_config.pin) {
        const std::string p = std::to_string(srv_config.pin);
        std::cout << "    PIN       " << p.substr(0, 3) << " " << p.substr(3)
                  << "   (asked once per headset; --no-pin to turn off)\n";
    } else {
        std::cout << "    PIN       off: any device on this network can connect\n";
    }
    std::cout << "    Control   " << (view_only ? "off (--view-only): headsets can only watch"
                                               : "on: headsets drive the mouse and keyboard") << "\n"
              << "    Virtual   " << (vdm_ok ? "headsets can add up to 4 virtual screens"
                                           : "no virtual screens on this desktop") << "\n";
    std::cout << "\n[Host] Press Ctrl+C to quit.\n\n";

    // --- Tray icon + settings panel (src/ui) ---
    std::unique_ptr<immersive::ui::HostUi> ui;
    if (ui_enable) {
        immersive::ui::Hooks hooks;
        hooks.monitors = [&] {
            std::vector<immersive::ui::MonitorRow> rows;
            std::lock_guard<std::mutex> lock(displays_mutex);
            for (const auto& d : displays)
                rows.push_back({d.id, d.name, static_cast<uint16_t>(d.width), static_cast<uint16_t>(d.height),
                                d.id >= immersive::protocol::VIRTUAL_MONITOR_ID_BASE});
            return rows;
        };
        hooks.streams = [&](uint32_t& client_id) {
            std::vector<immersive::ui::StreamRow> rows;
            std::lock_guard<std::mutex> lock(streams_mutex);
            client_id = active_streams.empty() ? 0 : streams_client_id;
            for (const auto& [id, c] : active_streams)
                if (c->codec != 0xFF)
                    rows.push_back({id, c->codec, c->width, c->height, c->fps_cap, c->frames, c->bytes});
            return rows;
        };
        hooks.remove_virtual = [&](uint8_t id) {
            std::lock_guard<std::mutex> ops(ops_mutex);
            if (!remove_virtual_locked(id)) return false;
            std::cout << "[Host] Removed virtual monitor " << (int)id << " from the settings panel\n";
            broadcast_monitor_list();
            return true;
        };
        hooks.usb_note = [&, adb_started, adb_missing]() -> std::string {
            if (!usb_enable) return "";
            if (adb_missing) return "adb not found: install Android platform-tools";
            if (!adb_started) return "Takes effect the next time Immersive-2 starts";
            return "";
        };
        hooks.quit = [] { g_running = false; };
        immersive::ui::Options opts;
        opts.config_dir = config_dir();
        opts.panel_port = panel_port;
        opts.tcp_port = tcp_port;
        opts.audio_port = audio_port;
        opts.audio_available = audio_enable;
        opts.virtual_supported = vdm_ok;
        opts.screen_off_supported = screen_off_ok;
        opts.stub = stub;
        ui = immersive::ui::start(settings, *server, std::move(hooks), std::move(opts));
    }

    // --- Main loop ---
    // Streaming happens in per-monitor worker threads and the USB tunnel is
    // kept armed on its own thread (adb can be slow); the main thread just
    // waits for the shutdown signal.
    std::thread usb_thread;
    if (!adb.empty())
        usb_thread = std::thread(immersive::keep_adb_reverse, adb, tcp_port, std::cref(g_running));
    auto reap_graveyard = [&](bool wait) {
        std::lock_guard<std::mutex> lock(graveyard_mutex);
        for (auto it = graveyard.begin(); it != graveyard.end();) {
            if (!wait && !(*it)->done) { ++it; continue; }
            if ((*it)->worker.joinable()) (*it)->worker.join();
            it = graveyard.erase(it);
        }
    };
    while (g_running) {
        reap_graveyard(false);
        if (screen_off_client && (view_only || steady_ms() > screen_off_until_ms)) {
            std::lock_guard<std::mutex> ops(ops_mutex);
            if (view_only) light_screen_locked("view-only");
            else if (steady_ms() > screen_off_until_ms) light_screen_locked("the headset went quiet");
        }
        if (ui) ui->pump(std::chrono::milliseconds(100));  // runs the macOS menu bar
        else std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    // --- Shutdown ---
    std::cout << "[Host] Cleaning up...\n";
    ui.reset();  // it calls into the server

    // Server first: its handler threads can still be inside a MONITOR_SELECT
    // callback starting new workers. Stopping streams before that left those
    // workers joinable in active_streams, and destroying a joinable
    // std::thread at return is std::terminate.
    server->stop();
    {
        std::lock_guard<std::mutex> ops(ops_mutex);
        light_screen_locked("quitting");
    }
    stop_all_streams(false);
    reap_graveyard(true);  // they reference this frame's locals
    if (audio_thread.joinable()) audio_thread.join();
    if (audio_capture)            audio_capture->stop();
    vdm->remove_all_displays();
    if (usb_thread.joinable()) usb_thread.join();

    std::cout << "[Host] Goodbye.\n";
    return 0;
}
