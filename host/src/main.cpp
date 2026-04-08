/// Immersive-2 Host Application
///
/// Main entry point for the Windows host.
/// Captures desktop, encodes video, streams to VR clients.

#include "capture/dxgi_capture.h"
#include "encoder/encoder.h"
#include "network/server.h"
#include "input/input_injector.h"
#include "driver/idd_manager.h"
#include "audio/audio_capture.h"
#include "protocol.h"

#include <iostream>
#include <thread>
#include <atomic>
#include <csignal>
#include <chrono>
#include <cstring>
#include <string>

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

    /// Print usage and exit.
    [[noreturn]] void usage(const char* prog) {
        std::cerr << "Usage: " << prog << " [options]\n"
                  << "Options:\n"
                  << "  --max-clients N     Maximum simultaneous VR clients (default: 4)\n"
                  << "  --tcp-port N        TCP control port (default: 19800)\n"
                  << "  --udp-port N        UDP video port (default: 19801)\n"
                  << "  --audio-port N      UDP audio port (default: 19802)\n"
                  << "  --no-audio          Disable audio streaming\n"
                  << "  --help              Show this message\n";
        std::exit(1);
    }
}

int main(int argc, char* argv[]) {
    std::cout << "=== Immersive-2 Host v0.1.0 ===\n\n";

    // Register signal handlers for graceful shutdown
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    // --- Parse command-line arguments ---
    uint32_t max_clients  = 4;
    uint16_t tcp_port     = immersive::protocol::DEFAULT_TCP_PORT;
    uint16_t udp_port     = immersive::protocol::DEFAULT_UDP_PORT;
    uint16_t audio_port   = immersive::protocol::DEFAULT_AUDIO_PORT;
    bool     audio_enable = true;

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

    // 2. Encoder
    auto encoder_backend = immersive::detect_best_encoder();
    auto encoder = immersive::create_encoder(encoder_backend);

    // 3. Input injector
    auto input_injector = immersive::create_input_injector();
    input_injector->initialize();

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

    // Active streaming state
    std::atomic<bool> streaming{false};
    uint8_t  active_monitor_id = 0;
    uint32_t active_client_id  = 0;
    uint32_t frame_number      = 0;

    // Set up server callbacks
    server->set_on_client_connected([&](uint32_t client_id) {
        std::cout << "[Host] Client " << client_id << " connected, sending monitor list\n";
        server->send_monitor_list(client_id, proto_monitors);

        // Notify about audio stream if enabled
        if (audio_enable) {
            immersive::protocol::ControlHeader ahdr;
            ahdr.type   = static_cast<uint8_t>(immersive::protocol::MessageType::AUDIO_START);
            ahdr.length = sizeof(immersive::protocol::AudioStart);

            immersive::protocol::AudioStart astart;
            astart.sample_rate = 48000;
            astart.channels    = 2;
            astart.audio_port  = audio_port;

            // server->send_control_message is not in the interface; we piggy-back on
            // send_monitor_list infrastructure — for now log the intent.
            // A future update to the INetworkServer interface will add send_raw_control().
            std::cout << "[Host] Audio stream available on UDP:" << audio_port << "\n";
        }
    });

    server->set_on_client_disconnected([&](uint32_t client_id) {
        std::cout << "[Host] Client " << client_id << " disconnected\n";
        if (client_id == active_client_id) {
            streaming = false;
            capture->stop_capture();
        }
    });

    server->set_on_monitor_select([&](uint32_t client_id, uint8_t monitor_id) {
        std::cout << "[Host] Client " << client_id
                  << " selected monitor " << (int)monitor_id << "\n";

        // Find the display
        const immersive::DisplayInfo* selected = nullptr;
        for (const auto& d : displays) {
            if (d.id == monitor_id) {
                selected = &d;
                break;
            }
        }

        if (!selected) {
            std::cerr << "[Host] Monitor " << (int)monitor_id << " not found\n";
            return;
        }

        // Start capture
        if (!capture->start_capture(monitor_id)) {
            std::cerr << "[Host] Failed to start capture on monitor "
                      << (int)monitor_id << "\n";
            return;
        }

        // Initialize encoder
        immersive::EncoderConfig enc_config;
        enc_config.width  = selected->width;
        enc_config.height = selected->height;
        enc_config.fps    = selected->refresh_rate;

        if (!encoder->initialize(enc_config)) {
            std::cerr << "[Host] Failed to initialize encoder\n";
            capture->stop_capture();
            return;
        }

        // Notify client that stream is starting
        immersive::protocol::StreamStart start_info = {};
        start_info.monitor_id = monitor_id;
        start_info.width      = selected->width;
        start_info.height     = selected->height;
        // Codec: 2 = MJPEG, 0 = H.264 (MF hardware)
        start_info.codec = (encoder->backend() == immersive::EncoderBackend::SOFTWARE) ? 2 : 0;

        server->send_stream_start(client_id, start_info);

        active_monitor_id = monitor_id;
        active_client_id  = client_id;
        frame_number      = 0;
        streaming         = true;
    });

    server->set_on_input_mouse([&](uint32_t /*client_id*/,
                                   const immersive::protocol::InputMouse& input) {
        input_injector->inject_mouse(input);
    });

    server->set_on_input_keyboard([&](uint32_t /*client_id*/,
                                      const immersive::protocol::InputKeyboard& input) {
        input_injector->inject_keyboard(input);
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
            // Open a separate UDP socket for audio streaming
            WSADATA wsa;
            WSAStartup(MAKEWORD(2, 2), &wsa);

            SOCKET audio_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);

            // We broadcast to all known clients.
            // For a production build this would use per-client sockets from the server.
            // For now, we send to the broadcast address on the audio port.
            // The client must bind to the audio port to receive.

            while (g_running) {
                if (!streaming) {
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

                // Determine destination: re-use active client UDP address
                // In a real implementation, the server exposes client UDP addresses.
                // Here we send to the video UDP port's known client address by using
                // server->send_video_packet as a template — for audio we use the same client.
                // Since send_video_packet already handles that, we forward audio via the
                // same UDP socket on a separate port.
                // We leave the actual sendto for the full multi-client server refactor.
                // This stub logs progress.
                (void)audio_sock;
                // TODO: sendto(audio_sock, ...) to each connected client
            }

            closesocket(audio_sock);
            WSACleanup();
        });
#endif
    }

    std::cout << "\n[Host] Ready. Waiting for VR client connections (max " << max_clients << ")...\n";
    std::cout << "[Host] Press Ctrl+C to quit.\n\n";

    // --- Main loop: capture → encode → stream ---
    while (g_running) {
        if (!streaming) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            continue;
        }

        auto frame = capture->acquire_frame(16);  // ~60fps timeout
        if (!frame) continue;

        // Encode the frame
        auto packets = encoder->encode(
            frame->pixels.data(),
            frame->width,
            frame->height,
            frame->pitch,
            frame->timestamp_us);

        // Send each encoded packet to the active client
        for (const auto& pkt : packets) {
            server->send_video_packet(
                active_client_id,
                active_monitor_id,
                frame_number,
                pkt.data.data(),
                static_cast<uint32_t>(pkt.data.size()));
        }

        frame_number++;
    }

    // --- Shutdown ---
    std::cout << "[Host] Cleaning up...\n";

    if (audio_thread.joinable()) audio_thread.join();
    if (audio_capture)            audio_capture->stop();
    capture->stop_capture();
    server->stop();
    vdm->remove_all_displays();

    std::cout << "[Host] Goodbye.\n";
    return 0;
}
