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
    /// during a periodic `adb reverse` was silently lost.
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
                  << "                      tests without touching the real desktop\n"
                  << "  --install-idd-cert  Install a self-signed code-signing certificate\n"
                  << "                      into the machine trust stores so an unsigned\n"
                  << "                      IDD virtual-display driver can be installed,\n"
                  << "                      then exit. Needs administrator rights and\n"
                  << "                      permanently trusts that key — see\n"
                  << "                      docs/IDD_DRIVER.md. Not needed for normal use.\n"
                  << "  --help              Show this message\n";
        std::exit(1);
    }
}

int main(int argc, char* argv[]) {
    std::cout << "=== Immersive-2 Host v0.1.0 ===\n\n";

    // Register signal handlers for graceful shutdown
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);
#ifdef SIGPIPE
    // A client that vanishes (Wi-Fi drop, headset sleep) can be written to
    // before its handler thread notices. Without this the default SIGPIPE
    // action terminates the whole host; the send then just fails with EPIPE
    // and the connection is cleaned up normally.
    std::signal(SIGPIPE, SIG_IGN);
#endif

    // --- Parse command-line arguments ---
    uint32_t max_clients  = 4;
    uint16_t tcp_port     = immersive::protocol::DEFAULT_TCP_PORT;
    uint16_t udp_port     = immersive::protocol::DEFAULT_UDP_PORT;
    uint16_t audio_port   = immersive::protocol::DEFAULT_AUDIO_PORT;
    bool     audio_enable = true;
    bool     usb_enable   = true;
    uint8_t  default_codec = 2;  // protocol VideoCodec: 0=H264 1=H265 2=MJPEG 3=AV1
    uint32_t jpeg_quality = 35;
    bool     stub         = false;
    int64_t  pin_arg      = -1;  // -1: persistent random PIN, 0: --no-pin
    bool     view_only    = false;

    for (int i = 1; i < argc; ++i) {
        std::string arg(argv[i]);

        if (arg == "--help" || arg == "-h") {
            usage(argv[0]);
        } else if (arg == "--max-clients" && i + 1 < argc) {
            max_clients = static_cast<uint32_t>(std::stoi(argv[++i]));
        } else if (arg == "--tcp-port" && i + 1 < argc) {
            tcp_port = static_cast<uint16_t>(std::stoi(argv[++i]));
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
    if (audio_enable) {
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
        uint8_t requested_codec = (cfg.codec != 0xFF) ? cfg.codec : default_codec;

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
        // Keyframes are driven explicitly from the streaming loop below: a fixed
        // ~1 s periodic refresh plus on-demand IDRs whenever the client reports
        // packet loss. The encoder's own GOP is therefore only a safety ceiling.
        // Driving IDRs in software is deterministic even on hardware MFTs that
        // quietly ignore CODECAPI_AVEncMPVGOPSize and would otherwise emit a
        // single IDR followed by an unbroken run of P-frames — the root cause of
        // inter-frame artefacts (e.g. a "ghost" cursor left by a dropped delta)
        // lingering until something else forces a refresh.
        enc_config.gop_size     = std::max<uint32_t>(30, enc_config.fps * 4);
        enc_config.jpeg_quality = (cfg.jpeg_quality >= 10 && cfg.jpeg_quality <= 95)
                                      ? cfg.jpeg_quality : jpeg_quality;
        if (cfg.bitrate_kbps > 0) {
            enc_config.bitrate_kbps = std::min<uint32_t>(cfg.bitrate_kbps, 100000);
        }

        // Fallback chain: requested codec → H.264 → MJPEG. `actual_codec`
        // (protocol value) is what we announce in STREAM_START.
        std::unique_ptr<immersive::IVideoEncoder> stream_encoder;
        uint8_t actual_codec = 2;

        auto try_mf_codec = [&](immersive::VideoCodec vc, uint8_t proto_value) -> bool {
            enc_config.codec = vc;
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
            if (!stream_encoder->initialize(enc_config)) {
                std::cerr << "[Host] Software encoder failed too, aborting stream\n";
                stream_capture->stop_capture();
                return;
            }
        }

        const bool is_mjpeg = (actual_codec == 2);

        // FPS cap: explicit from the client, otherwise 24 for MJPEG (WiFi
        // friendly) or the display refresh rate for H.264.
        uint32_t fps_cap = cfg.max_fps > 0
            ? cfg.max_fps
            : (is_mjpeg ? 24u : static_cast<uint32_t>(display.refresh_rate));
        fps_cap = std::max(1u, std::min(fps_cap, 120u));
        const auto min_interval = std::chrono::microseconds(1000000u / fps_cap);

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

        std::cout << "[Host] Streaming monitor " << (int)monitor_id
                  << " to client " << client_id
                  << " at " << out_w << "x" << out_h
                  << " (native " << display.width << "x" << display.height << ")"
                  << " cap " << fps_cap << " fps\n";

        std::vector<uint8_t> scaled;

        live_stream_count++;
        uint32_t frame_number = first_frame;
        auto last_sent = std::chrono::steady_clock::time_point{};

        // Guaranteed periodic IDR (~1 s of sent frames). Independent of whether
        // the MFT honours its GOP, this bounds how long any inter-frame
        // corruption can persist; the client's on-demand REQUEST_KEYFRAME clears
        // it faster (within a round-trip) when loss is actually detected.
        const uint32_t keyframe_interval = std::max(1u, fps_cap);
        uint32_t frames_since_keyframe = keyframe_interval;  // force one promptly

        // The newest captured frame, and whether it still has to be sent.
        // Event-driven backends (WGC, ScreenCaptureKit, PipeWire) deliver
        // nothing while the screen is static, so a frame the pacing below
        // skipped — the last keystroke, the final position of a dragged
        // window — would otherwise stay unsent until something else changes,
        // and a keyframe the client asks for after Wi-Fi loss would never
        // come. Both are served from this frame when the capture goes idle.
        std::unique_ptr<immersive::CapturedFrame> last_frame;
        bool last_frame_unsent = false;

        while (g_running && !ctx->stop) {
            auto frame = stream_capture->acquire_frame(16);  // ~60fps timeout
            auto now = std::chrono::steady_clock::now();
            if (!frame && stream_capture->is_capturing() && last_frame) {
                const bool due = now - last_sent >= min_interval;
                if ((last_frame_unsent && due) || ctx->force_keyframe ||
                    now - last_sent >= std::chrono::seconds(1)) {
                    frame = std::move(last_frame);  // idle: (re)send the newest
                    if (!last_frame_unsent) ctx->force_keyframe = true;
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

            // Emit an IDR when the client asks (recovery after packet loss) or
            // when the periodic refresh interval elapses. The periodic IDR caps
            // how long a dropped P-frame can leave artefacts on screen; the
            // on-demand request clears them within a round-trip. Both are no-ops
            // for MJPEG (every frame is already independent).
            bool want_keyframe = ctx->force_keyframe.exchange(false);
            if (frames_since_keyframe >= keyframe_interval) {
                want_keyframe = true;
            }
            if (want_keyframe) {
                stream_encoder->request_keyframe();
                frames_since_keyframe = 0;
            }

            auto packets = stream_encoder->encode(
                pixels, w, h, pitch, frame->timestamp_us);

            for (const auto& pkt : packets) {
                server->send_video_packet(
                    client_id,
                    monitor_id,
                    frame_number,
                    pkt.data.data(),
                    static_cast<uint32_t>(pkt.data.size()));
            }
            if (!packets.empty()) {
                frame_high_water[monitor_id].store(frame_number);
                frame_number++;  // number only frames actually sent
                last_sent = now;
                frames_since_keyframe++;
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
        if (audio_enable) {
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

    server->set_on_client_disconnected([&](uint32_t client_id) {
        std::cout << "[Host] Client " << client_id << " disconnected\n";
        // Check and stop under one lock: another client taking over in
        // between must not have its fresh streams killed.
        std::lock_guard<std::mutex> ops(ops_mutex);
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

    // Restart the active streams so a new stream configuration takes effect.
    // STREAM_STOP *is* sent for each monitor first: the client rebuilds its
    // panel and decoder from the following STREAM_START, and an Android panel
    // that kept its old ExternalTexture would otherwise show a frozen image.
    // One ops_mutex hold: no other client's selection can slip in between.
    server->set_on_stream_config(
        [&](uint32_t client_id, const immersive::protocol::StreamConfig& cfg) {
            std::lock_guard<std::mutex> ops(ops_mutex);
            std::vector<uint8_t> ids;
            {
                std::lock_guard<std::mutex> lock(streams_mutex);
                if (!active_streams.empty() && client_id != streams_client_id) {
                    return;  // only the streaming client may reconfigure
                }
                for (const auto& [id, ctx] : active_streams) ids.push_back(id);
            }
            stream_cfg = cfg;  // after the check: a bystander client must
                               // not poison the next restart's settings
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

    server->set_on_virtual_display_remove([&](uint32_t client_id, uint8_t id) {
        namespace p = immersive::protocol;
        std::lock_guard<std::mutex> ops(ops_mutex);
        const auto active = vdm->get_active_displays();
        if (std::find(active.begin(), active.end(), id) == active.end()) {
            send_vresult(client_id, vdm_ok ? p::VDISPLAY_FAILED : p::VDISPLAY_UNSUPPORTED, true, id);
            return;
        }
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
        std::cout << "[Host] Client " << client_id << " removed virtual monitor " << (int)id << "\n";
        send_vresult(client_id, p::VDISPLAY_OK, true, id);
        broadcast_monitor_list();
    });

    // --- USB ---
    // A headset on a USB cable reaches the host through `adb reverse`: its
    // 127.0.0.1:<tcp_port> tunnels to ours. Only TCP can be tunnelled, so the
    // client asks for video/audio in-band on TCP (HELLO_FLAG_TCP_MEDIA).
    // The adb server daemon is started HERE, before any socket is opened: a
    // daemon spawned later would inherit the listening socket and keep the
    // port bound after the host exits.
    // ponytail: `adb kill-server` mid-session restarts it with our sockets
    // inherited; mark them non-inheritable if that ever bites.
#ifdef _WIN32
    const char* kNull = " >nul 2>&1";
#else
    const char* kNull = " >/dev/null 2>&1";
#endif
    const std::string adb_reverse = "adb reverse tcp:" + std::to_string(tcp_port) +
                                    " tcp:" + std::to_string(tcp_port) + kNull;
    if (usb_enable && run_quiet(std::string("adb start-server") + kNull) != 0) {
        std::cout << "[Host] USB: adb not found on PATH; install Android platform-tools\n"
                  << "       to connect a headset over USB (Wi-Fi still works).\n";
        usb_enable = false;
    } else if (usb_enable) {
        std::cout << "[Host] USB: plug in the headset (USB debugging on) and press USB in the app.\n";
    }

    // Start the network server with configured options
    immersive::ServerConfig srv_config;
    srv_config.tcp_port    = tcp_port;
    srv_config.udp_port    = udp_port;
    srv_config.max_clients = max_clients;
    srv_config.monitor_count = static_cast<uint8_t>(std::min<size_t>(displays.size(), 255));
    srv_config.host_flags = (view_only ? immersive::protocol::HOST_FLAG_VIEW_ONLY : 0) |
                            (vdm_ok ? immersive::protocol::HOST_FLAG_VIRTUAL_DISPLAYS : 0);
    srv_config.pin = pin_arg >= 0 ? static_cast<uint32_t>(pin_arg) : load_or_create_pin();

    // A headset asked to pair: show the PIN on this PC's screen, since the
    // host may be running with no visible console. At most one every 5 s.
    server->set_on_pin_requested([pin = srv_config.pin](const std::string& peer_ip) {
        static std::atomic<int64_t> last_s{-5};
        const int64_t now = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        int64_t prev = last_s.load();
        if (now - prev < 5 || !last_s.compare_exchange_strong(prev, now)) return;
        const std::string p = std::to_string(pin);
        notify_desktop("Immersive-2 PIN: " + p.substr(0, 3) + " " + p.substr(3),
                       "A headset at " + peer_ip + " wants to connect. Type this PIN in it.");
    });

    if (!server->start(srv_config)) {
        std::cerr << "[Host] Failed to start network server\n";
        return 1;
    }

    // --- Audio streaming thread ---
    std::thread audio_thread;
    if (audio_enable && audio_capture) {
        audio_thread = std::thread([&]() {
            // 288 stereo frames (6 ms) = 1160-byte packets: under any Wi-Fi
            // MTU, so a packet is never IP-fragmented (one lost fragment
            // loses the whole datagram).
            constexpr size_t kFramesPerPacket = 288;
            uint32_t seq = 0;
            std::vector<uint8_t> pkt;
            while (g_running) {
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

    // --- Main loop ---
    // Streaming happens in per-monitor worker threads; the main thread just
    // waits for the shutdown signal, and re-arms the USB tunnel every few
    // seconds: it dies whenever the cable is unplugged or the headset reboots
    // (re-running it is idempotent, and just fails with no device attached).
    // ponytail: plain `adb reverse` fails with several Android devices plugged
    // in; loop over `adb devices` with -s if that ever matters.
    auto reap_graveyard = [&](bool wait) {
        std::lock_guard<std::mutex> lock(graveyard_mutex);
        for (auto it = graveyard.begin(); it != graveyard.end();) {
            if (!wait && !(*it)->done) { ++it; continue; }
            if ((*it)->worker.joinable()) (*it)->worker.join();
            it = graveyard.erase(it);
        }
    };
    auto next_adb = std::chrono::steady_clock::now();
    while (g_running) {
        if (usb_enable && std::chrono::steady_clock::now() >= next_adb) {
            run_quiet(adb_reverse);
            next_adb = std::chrono::steady_clock::now() + std::chrono::seconds(3);
        }
        reap_graveyard(false);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    // --- Shutdown ---
    std::cout << "[Host] Cleaning up...\n";

    // Server first: its handler threads can still be inside a MONITOR_SELECT
    // callback starting new workers. Stopping streams before that left those
    // workers joinable in active_streams, and destroying a joinable
    // std::thread at return is std::terminate.
    server->stop();
    stop_all_streams(false);
    reap_graveyard(true);  // they reference this frame's locals
    if (audio_thread.joinable()) audio_thread.join();
    if (audio_capture)            audio_capture->stop();
    vdm->remove_all_displays();

    std::cout << "[Host] Goodbye.\n";
    return 0;
}
