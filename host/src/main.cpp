/// Immersive-2 Host Application
///
/// Main entry point for the Windows host.
/// Captures desktop, encodes video, streams to VR clients.

#include "capture/dxgi_capture.h"
#include "encoder/encoder.h"
#include "network/server.h"
#include "input/input_injector.h"
#include "driver/idd_manager.h"
#include "protocol.h"

#include <iostream>
#include <thread>
#include <atomic>
#include <csignal>
#include <chrono>

namespace {
    std::atomic<bool> g_running{true};

    void signal_handler(int signal) {
        std::cout << "\n[Host] Shutting down (signal " << signal << ")...\n";
        g_running = false;
    }
}

int main(int argc, char* argv[]) {
    std::cout << "=== Immersive-2 Host v0.1.0 ===\n\n";

    // Register signal handlers for graceful shutdown
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

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

    // 5. Network server
    auto server = immersive::create_network_server();

    // Prepare monitor info for the protocol
    std::vector<immersive::protocol::MonitorInfo> proto_monitors;
    for (const auto& d : displays) {
        immersive::protocol::MonitorInfo info = {};
        info.monitor_id = d.id;
        info.width = d.width;
        info.height = d.height;
        info.refresh_rate = d.refresh_rate;
        strncpy(info.name, d.name.c_str(), sizeof(info.name) - 1);
        proto_monitors.push_back(info);
    }

    // Active streaming state
    std::atomic<bool> streaming{false};
    uint8_t active_monitor_id = 0;
    uint32_t active_client_id = 0;
    uint32_t frame_number = 0;

    // Set up server callbacks
    server->set_on_client_connected([&](uint32_t client_id) {
        std::cout << "[Host] Client " << client_id << " connected, sending monitor list\n";
        server->send_monitor_list(client_id, proto_monitors);
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
        enc_config.width = selected->width;
        enc_config.height = selected->height;
        enc_config.fps = selected->refresh_rate;

        if (!encoder->initialize(enc_config)) {
            std::cerr << "[Host] Failed to initialize encoder\n";
            capture->stop_capture();
            return;
        }

        // Notify client that stream is starting
        immersive::protocol::StreamStart start_info = {};
        start_info.monitor_id = monitor_id;
        start_info.width = selected->width;
        start_info.height = selected->height;
        start_info.codec = 0;  // H.264

        server->send_stream_start(client_id, start_info);

        active_monitor_id = monitor_id;
        active_client_id = client_id;
        frame_number = 0;
        streaming = true;
    });

    server->set_on_input_mouse([&](uint32_t /*client_id*/,
                                   const immersive::protocol::InputMouse& input) {
        input_injector->inject_mouse(input);
    });

    server->set_on_input_keyboard([&](uint32_t /*client_id*/,
                                      const immersive::protocol::InputKeyboard& input) {
        input_injector->inject_keyboard(input);
    });

    // Start the network server
    immersive::ServerConfig srv_config;
    if (!server->start(srv_config)) {
        std::cerr << "[Host] Failed to start network server\n";
        return 1;
    }

    std::cout << "\n[Host] Ready. Waiting for VR client connections...\n";
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

        // Send each encoded packet
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
    capture->stop_capture();
    server->stop();
    vdm->remove_all_displays();

    std::cout << "[Host] Goodbye.\n";
    return 0;
}
