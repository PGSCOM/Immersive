/// Immersive-2 Host Application
///
/// Main entry point for the Windows host.
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
#include <iostream>
#include <thread>
#include <atomic>
#include <mutex>
#include <map>
#include <csignal>
#include <chrono>
#include <cstring>
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

    /// Print usage and exit.
    [[noreturn]] void usage(const char* prog) {
        std::cerr << "Usage: " << prog << " [options]\n"
                  << "Options:\n"
                  << "  --max-clients N     Maximum simultaneous VR clients (default: 4)\n"
                  << "  --tcp-port N        TCP control port (default: 19800)\n"
                  << "  --udp-port N        UDP video port (default: 19801)\n"
                  << "  --audio-port N      UDP audio port (default: 19802)\n"
                  << "  --no-audio          Disable audio streaming\n"
                  << "  --codec NAME        Video codec: mjpeg (default), h264, h265 or av1.\n"
                  << "                      h264/h265/av1 use the GPU encoder (Media\n"
                  << "                      Foundation) and require a matching decoder on\n"
                  << "                      the client (Android MediaCodec plugin).\n"
                  << "  --jpeg-quality N    MJPEG quality 10-95 (default: 35)\n"
                  << "  --help              Show this message\n";
        std::exit(1);
    }
}

int main(int argc, char* argv[]) {
    std::cout << "=== Immersive-2 Host v0.1.0 ===\n\n";

#ifndef _WIN32
    std::cout << "[Host] Portable mode (Linux/macOS): using stub capture/input backends.\n"
              << "       This mode is intended for development and protocol testing.\n\n";
#endif

    // Register signal handlers for graceful shutdown
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    // --- Parse command-line arguments ---
    uint32_t max_clients  = 4;
    uint16_t tcp_port     = immersive::protocol::DEFAULT_TCP_PORT;
    uint16_t udp_port     = immersive::protocol::DEFAULT_UDP_PORT;
    uint16_t audio_port   = immersive::protocol::DEFAULT_AUDIO_PORT;
    bool     audio_enable = true;
    uint8_t  default_codec = 2;  // protocol VideoCodec: 0=H264 1=H265 2=MJPEG 3=AV1
    uint32_t jpeg_quality = 35;

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

    // 1. Screen capture
    auto capture = immersive::create_dxgi_capture();
    auto displays = capture->enumerate_displays();

    std::cout << "[Host] Found " << displays.size() << " display(s):\n";
    for (const auto& d : displays) {
        std::cout << "  [" << (int)d.id << "] " << d.name
                  << " (" << d.width << "x" << d.height << ")"
                  << (d.is_primary ? " (primary)" : "") << "\n";
    }

    if (displays.empty()) {
        std::cerr << "[Host] No displays found. Exiting.\n";
        return 1;
    }

    // 2. Encoder availability. MJPEG always works (CPU). H.264/HEVC/AV1 use
    // Media Foundation; each stream worker creates its own encoder instance.
#ifdef _WIN32
    const bool has_h264 = immersive::mf_encoder_available(immersive::VideoCodec::H264);
    const bool has_h265 = immersive::mf_encoder_available(immersive::VideoCodec::H265);
    const bool has_av1  = immersive::mf_encoder_available(immersive::VideoCodec::AV1);
#else
    const bool has_h264 = false, has_h265 = false, has_av1 = false;
#endif
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
    auto input_injector = immersive::create_input_injector();
    input_injector->initialize();
    input_injector->set_displays(displays);

    // 4. Virtual display manager (optional)
    auto vdm = immersive::create_virtual_display_manager();
    if (vdm->is_driver_installed()) {
        std::cout << "[Host] IDD driver found — virtual displays available\n";
    } else {
        std::cout << "[Host] IDD driver not installed — using physical displays only\n";
    }

    // 5. Audio capture (WASAPI loopback)
    std::unique_ptr<immersive::IAudioCapture> audio_capture;
    if (audio_enable) {
        audio_capture = immersive::create_audio_capture();
        if (!audio_capture->start()) {
            std::cerr << "[Host] Audio capture failed to start — audio disabled\n";
            audio_enable = false;
        }
    }

    // 6. Network server
    auto server = immersive::create_network_server();

    // Prepare monitor info for the protocol
    std::vector<immersive::protocol::MonitorInfo> proto_monitors;
    for (const auto& d : displays) {
        immersive::protocol::MonitorInfo info = {};
        info.monitor_id   = d.id;
        info.width        = d.width;
        info.height       = d.height;
        info.refresh_rate = d.refresh_rate;
        strncpy(info.name, d.name.c_str(), sizeof(info.name) - 1);
        proto_monitors.push_back(info);
    }

    // --- Multi-monitor streaming state ---
    // One worker per selected monitor, each with its own capture (DXGI
    // duplication) and encoder instance. streams_mutex guards the map and
    // is held while starting/stopping workers (network-thread callbacks).
    struct ActiveStream {
        std::atomic<bool> stop{false};
        std::atomic<bool> force_keyframe{false};  // set by REQUEST_KEYFRAME (loss recovery)
        std::thread       worker;
    };

    std::mutex streams_mutex;
    std::map<uint8_t, std::unique_ptr<ActiveStream>> active_streams;
    uint32_t streams_client_id = 0;
    std::atomic<int> live_stream_count{0};  // streams actively sending (gates audio)

    // Client-requested stream quality (protected by streams_mutex).
    // Defaults mean "use the host CLI settings".
    immersive::protocol::StreamConfig stream_cfg = {};
    stream_cfg.codec = 0xFF;

    // Per-monitor scale from stream pixels to native pixels, used to map
    // incoming mouse coordinates when the stream is downscaled.
    std::mutex input_scale_mutex;
    std::map<uint8_t, std::pair<double, double>> input_scale;

    // Capture → encode → send loop for a single monitor.
    // `cfg` is a snapshot of the client stream settings taken at start time.
    auto stream_worker = [&](uint32_t client_id,
                             immersive::DisplayInfo display,
                             immersive::protocol::StreamConfig cfg,
                             ActiveStream* ctx) {
        const uint8_t monitor_id = display.id;

        auto stream_capture = immersive::create_dxgi_capture();
        if (!stream_capture->start_capture(monitor_id)) {
            std::cerr << "[Host] Failed to start capture on monitor "
                      << (int)monitor_id << "\n";
            return;
        }

        // --- Resolve effective settings (client config overrides CLI) ---
        // Protocol codec values: 0=H.264, 1=HEVC, 2=MJPEG, 3=AV1, 0xFF=default
        uint8_t requested_codec = (cfg.codec != 0xFF) ? cfg.codec : default_codec;

        // Output resolution (downscale keeping aspect, even dimensions for NV12)
        uint32_t out_w = display.width;
        uint32_t out_h = display.height;
        if (cfg.max_width >= 320 && cfg.max_width < display.width) {
            out_w = cfg.max_width & ~1u;
            out_h = (static_cast<uint32_t>(display.height) * out_w / display.width) & ~1u;
            if (out_h < 2) out_h = 2;
        }

        immersive::EncoderConfig enc_config;
        enc_config.width        = out_w;
        enc_config.height       = out_h;
        enc_config.fps          = (cfg.max_fps > 0)
                                      ? cfg.max_fps
                                      : static_cast<uint32_t>(display.refresh_rate);
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
            auto enc = immersive::create_mf_encoder();
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
                static_cast<double>(display.height) / out_h
            };
        }

        immersive::protocol::StreamStart start_info = {};
        start_info.monitor_id = monitor_id;
        start_info.width      = static_cast<uint16_t>(out_w);
        start_info.height     = static_cast<uint16_t>(out_h);
        start_info.codec      = actual_codec;  // 0=H264 1=HEVC 2=MJPEG 3=AV1
        server->send_stream_start(client_id, start_info);

        std::cout << "[Host] Streaming monitor " << (int)monitor_id
                  << " to client " << client_id
                  << " at " << out_w << "x" << out_h
                  << " (native " << display.width << "x" << display.height << ")"
                  << " cap " << fps_cap << " fps\n";

        const bool scaling = (out_w != display.width || out_h != display.height);
        std::vector<uint8_t> scaled;
        if (scaling) scaled.resize(static_cast<size_t>(out_w) * out_h * 4);

        live_stream_count++;
        uint32_t frame_number = 0;
        auto last_sent = std::chrono::steady_clock::time_point{};

        while (g_running && !ctx->stop) {
            auto frame = stream_capture->acquire_frame(16);  // ~60fps timeout
            if (!frame) continue;

            // Frame pacing
            auto now = std::chrono::steady_clock::now();
            if (last_sent.time_since_epoch().count() != 0 &&
                now - last_sent < min_interval) {
                continue;
            }

            const uint8_t* pixels = frame->pixels.data();
            uint32_t w = frame->width, h = frame->height, pitch = frame->pitch;

            if (scaling) {
                scale_bgra_bilinear(pixels, w, h, pitch,
                                    scaled.data(), out_w, out_h);
                pixels = scaled.data();
                w = out_w; h = out_h; pitch = out_w * 4;
            }

            // Honour a client keyframe request (recovery after packet loss).
            // No-op for MJPEG (every frame is already independent).
            if (ctx->force_keyframe.exchange(false)) {
                stream_encoder->request_keyframe();
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
                frame_number++;  // number only frames actually sent
                last_sent = now;
            }
        }

        live_stream_count--;
        {
            std::lock_guard<std::mutex> lock(input_scale_mutex);
            input_scale.erase(monitor_id);
        }
        stream_capture->stop_capture();
        std::cout << "[Host] Stopped streaming monitor " << (int)monitor_id << "\n";
    };

    // Reconcile the set of active streams with the client's selection:
    // stops deselected monitors, starts newly selected ones, keeps the rest.
    auto apply_selection = [&](uint32_t client_id, std::vector<uint8_t> ids) {
        if (ids.size() > 3) ids.resize(3);  // protocol limit

        std::lock_guard<std::mutex> lock(streams_mutex);

        // Stop streams that are no longer selected (or belong to another client)
        for (auto it = active_streams.begin(); it != active_streams.end();) {
            bool keep = (client_id == streams_client_id) &&
                        std::find(ids.begin(), ids.end(), it->first) != ids.end();
            if (keep) { ++it; continue; }

            it->second->stop = true;
            if (it->second->worker.joinable()) it->second->worker.join();

            immersive::protocol::StreamStop stop_msg = { it->first };
            server->send_control_message(
                streams_client_id,
                immersive::protocol::MessageType::STREAM_STOP,
                &stop_msg, sizeof(stop_msg));

            it = active_streams.erase(it);
        }
        streams_client_id = client_id;

        // Start newly selected streams
        for (uint8_t id : ids) {
            if (active_streams.count(id)) continue;

            const immersive::DisplayInfo* selected = nullptr;
            for (const auto& d : displays) {
                if (d.id == id) { selected = &d; break; }
            }
            if (!selected) {
                std::cerr << "[Host] Monitor " << (int)id << " not found\n";
                continue;
            }

            auto ctx = std::make_unique<ActiveStream>();
            ActiveStream* ctx_ptr = ctx.get();
            immersive::DisplayInfo display = *selected;
            immersive::protocol::StreamConfig cfg_snapshot = stream_cfg;
            ctx->worker = std::thread(
                [&stream_worker, client_id, display, cfg_snapshot, ctx_ptr]() {
                    stream_worker(client_id, display, cfg_snapshot, ctx_ptr);
                });
            active_streams[id] = std::move(ctx);
        }
    };

    // Restart the active streams in place (no STREAM_STOP notifications) so
    // a new stream configuration takes effect without dropping panels.
	auto restart_streams = [&]() {
        std::vector<uint8_t> ids;
        uint32_t client_id;
        {
            std::lock_guard<std::mutex> lock(streams_mutex);
            client_id = streams_client_id;
            for (auto& [id, ctx] : active_streams) {
                ids.push_back(id);
                ctx->stop = true;
                if (ctx->worker.joinable()) ctx->worker.join();
            }
            active_streams.clear();
        }
        for (uint8_t id : ids) {
            immersive::protocol::StreamStop stop_msg = { id };
            server->send_control_message(
                client_id,
                immersive::protocol::MessageType::STREAM_STOP,
                &stop_msg, sizeof(stop_msg));
        }
        if (!ids.empty()) {
            apply_selection(client_id, ids);
        }
    };

    auto stop_all_streams = [&](bool notify_client) {
        std::lock_guard<std::mutex> lock(streams_mutex);
        for (auto& [id, ctx] : active_streams) {
            ctx->stop = true;
            if (ctx->worker.joinable()) ctx->worker.join();
            if (notify_client) {
                immersive::protocol::StreamStop stop_msg = { id };
                server->send_control_message(
                    streams_client_id,
                    immersive::protocol::MessageType::STREAM_STOP,
                    &stop_msg, sizeof(stop_msg));
            }
        }
        active_streams.clear();
    };

    // Set up server callbacks
    server->set_on_client_connected([&](uint32_t client_id) {
        std::cout << "[Host] Client " << client_id << " connected, sending monitor list\n";
        server->send_monitor_list(client_id, proto_monitors);

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
        bool is_streaming_client;
        {
            std::lock_guard<std::mutex> lock(streams_mutex);
            is_streaming_client = (client_id == streams_client_id);
        }
        if (is_streaming_client) {
            stop_all_streams(false);
        }
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

    server->set_on_stream_config(
        [&](uint32_t client_id, const immersive::protocol::StreamConfig& cfg) {
            {
                std::lock_guard<std::mutex> lock(streams_mutex);
                stream_cfg = cfg;
                if (!active_streams.empty() && client_id != streams_client_id) {
                    return;  // only the streaming client may reconfigure
                }
            }
            restart_streams();
        });

    server->set_on_input_mouse([&](uint32_t /*client_id*/,
                                   const immersive::protocol::InputMouse& input) {
        // Mouse coordinates arrive in stream pixels; map them to native
        // monitor pixels when the stream is downscaled.
        immersive::protocol::InputMouse scaled_input = input;
        {
            std::lock_guard<std::mutex> lock(input_scale_mutex);
            auto it = input_scale.find(input.monitor_id);
            if (it != input_scale.end()) {
                scaled_input.x = static_cast<uint16_t>(input.x * it->second.first);
                scaled_input.y = static_cast<uint16_t>(input.y * it->second.second);
            }
        }
        input_injector->inject_mouse(scaled_input);
    });

    server->set_on_input_keyboard([&](uint32_t /*client_id*/,
                                      const immersive::protocol::InputKeyboard& input) {
        input_injector->inject_keyboard(input);
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

    // Start the network server with configured options
    immersive::ServerConfig srv_config;
    srv_config.tcp_port    = tcp_port;
    srv_config.udp_port    = udp_port;
    srv_config.max_clients = max_clients;

    if (!server->start(srv_config)) {
        std::cerr << "[Host] Failed to start network server\n";
        return 1;
    }

    // --- Audio streaming thread ---
    std::thread audio_thread;
    if (audio_enable && audio_capture) {
#ifdef _WIN32
        audio_thread = std::thread([&]() {
            while (g_running) {
                if (live_stream_count == 0) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                    continue;
                }

                auto audio_frame = audio_capture->get_frame();
                if (!audio_frame) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(5));
                    continue;
                }

                // Build UDP audio packet
                immersive::protocol::AudioPacketHeader ahdr;
                ahdr.seq      = audio_frame->seq;
                ahdr.samples  = static_cast<uint16_t>(
                    audio_frame->samples.size() / audio_frame->channels);
                ahdr.channels = audio_frame->channels;
                ahdr.reserved = 0;

                size_t pcm_bytes = audio_frame->samples.size() * sizeof(int16_t);
                std::vector<uint8_t> pkt(sizeof(ahdr) + pcm_bytes);
                std::memcpy(pkt.data(), &ahdr, sizeof(ahdr));
                std::memcpy(pkt.data() + sizeof(ahdr),
                            audio_frame->samples.data(), pcm_bytes);

                server->broadcast_udp(pkt.data(), pkt.size(), audio_port);
            }
        });
#endif
    }

    std::cout << "\n[Host] Ready. Waiting for VR client connections (max " << max_clients << ")...\n";
    std::cout << "[Host] Press Ctrl+C to quit.\n\n";

    // --- Main loop ---
    // Streaming happens in per-monitor worker threads; the main thread just
    // waits for the shutdown signal.
    while (g_running) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    // --- Shutdown ---
    std::cout << "[Host] Cleaning up...\n";

    stop_all_streams(false);
    if (audio_thread.joinable()) audio_thread.join();
    if (audio_capture)            audio_capture->stop();
    server->stop();
    vdm->remove_all_displays();

    std::cout << "[Host] Goodbye.\n";
    return 0;
}
