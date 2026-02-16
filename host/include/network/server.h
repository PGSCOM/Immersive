#pragma once

/// Network streaming server.
/// Manages TCP control channel and UDP video stream.

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "protocol.h"

namespace immersive {

/// Callback for when a client connects
using ClientConnectedCallback = std::function<void(uint32_t client_id)>;

/// Callback for when a client disconnects
using ClientDisconnectedCallback = std::function<void(uint32_t client_id)>;

/// Callback for when a client requests a monitor
using MonitorSelectCallback = std::function<void(uint32_t client_id, uint8_t monitor_id)>;

/// Callback for incoming input events
using InputMouseCallback = std::function<void(uint32_t client_id, const protocol::InputMouse& input)>;
using InputKeyboardCallback = std::function<void(uint32_t client_id, const protocol::InputKeyboard& input)>;

/// Network server configuration
struct ServerConfig {
    uint16_t tcp_port = protocol::DEFAULT_TCP_PORT;
    uint16_t udp_port = protocol::DEFAULT_UDP_PORT;
    uint32_t max_clients = 4;
};

/// Network server interface
class INetworkServer {
public:
    virtual ~INetworkServer() = default;

    /// Start listening for connections
    virtual bool start(const ServerConfig& config) = 0;

    /// Stop the server
    virtual void stop() = 0;

    /// Send monitor list to a specific client
    virtual void send_monitor_list(uint32_t client_id,
                                   const std::vector<protocol::MonitorInfo>& monitors) = 0;

    /// Send stream-start notification
    virtual void send_stream_start(uint32_t client_id,
                                   const protocol::StreamStart& info) = 0;

    /// Send an encoded video packet via UDP
    virtual void send_video_packet(uint32_t client_id,
                                   uint8_t monitor_id,
                                   uint32_t frame_number,
                                   const uint8_t* data,
                                   uint32_t size) = 0;

    /// Set event callbacks
    virtual void set_on_client_connected(ClientConnectedCallback cb) = 0;
    virtual void set_on_client_disconnected(ClientDisconnectedCallback cb) = 0;
    virtual void set_on_monitor_select(MonitorSelectCallback cb) = 0;
    virtual void set_on_input_mouse(InputMouseCallback cb) = 0;
    virtual void set_on_input_keyboard(InputKeyboardCallback cb) = 0;

    /// Check if server is running
    virtual bool is_running() const = 0;

    /// Get number of connected clients
    virtual uint32_t client_count() const = 0;
};

/// Create a network server instance
std::unique_ptr<INetworkServer> create_network_server();

}  // namespace immersive
