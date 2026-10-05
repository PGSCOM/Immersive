#pragma once

/// Network streaming server.
/// Manages TCP control channel and UDP video stream.

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "protocol.h"

namespace immersive {

namespace tls { class Identity; }

/// Callback for when a client connects
using ClientConnectedCallback = std::function<void(uint32_t client_id)>;

/// Callback for when a client disconnects
using ClientDisconnectedCallback = std::function<void(uint32_t client_id)>;

/// Callback for when a client requests a monitor
using MonitorSelectCallback = std::function<void(uint32_t client_id, uint8_t monitor_id)>;

/// Callback for when a client requests a set of monitors (multi-monitor)
using MultiMonitorSelectCallback =
    std::function<void(uint32_t client_id, const std::vector<uint8_t>& monitor_ids)>;

/// Callback for when a client requests stream quality settings
using StreamConfigCallback =
    std::function<void(uint32_t client_id, const protocol::StreamConfig& config)>;

/// Callback for incoming input events
using InputMouseCallback = std::function<void(uint32_t client_id, const protocol::InputMouse& input)>;
using InputKeyboardCallback = std::function<void(uint32_t client_id, const protocol::InputKeyboard& input)>;

/// Callback for when a client requests a keyframe (loss recovery)
using RequestKeyframeCallback = std::function<void(uint32_t client_id, uint8_t monitor_id)>;

/// Callbacks for VIRTUAL_DISPLAY_CREATE / VIRTUAL_DISPLAY_REMOVE
using VirtualDisplayCreateCallback =
    std::function<void(uint32_t client_id, const protocol::VirtualDisplayCreate& request)>;
using VirtualDisplayRemoveCallback = std::function<void(uint32_t client_id, uint8_t monitor_id)>;

/// SCREEN_OFF from a client (off = darken the main screen).
using ScreenOffCallback = std::function<void(uint32_t client_id, bool off)>;

/// A headset at `peer_ip` was refused for a missing or wrong PIN: the host
/// shows the PIN to the person at the PC.
using PinRequestedCallback = std::function<void(const std::string& peer_ip)>;

/// Network server configuration
struct ServerConfig {
    uint16_t tcp_port = protocol::DEFAULT_TCP_PORT;
    uint16_t udp_port = protocol::DEFAULT_UDP_PORT;
    uint32_t max_clients = 4;
    /// Pairing PIN every non-loopback client must send in HELLO; 0 = none.
    uint32_t pin = 0;
    /// Reported in HELLO_ACK and LAN discovery replies (see set_monitor_count).
    uint8_t  monitor_count = 0;
    /// protocol::HOST_FLAG_* sent in HELLO_ACK (and view-only in discovery).
    uint8_t  host_flags = 0;
    /// This PC's TLS key and certificate (tls.h). Without one, only plain
    /// connections work: from this PC, or anywhere with allow_plaintext.
    std::shared_ptr<tls::Identity> identity;
    /// Let headsets on the network connect unencrypted (old versions of the
    /// app): their PIN, input and screens cross the network in the clear.
    bool allow_plaintext = false;
};

/// Network server interface
class INetworkServer {
public:
    virtual ~INetworkServer() = default;

    /// Start listening for connections
    virtual bool start(const ServerConfig& config) = 0;

    /// Stop the server
    virtual void stop() = 0;

    /// Send the monitor list, followed by one protocol::MONITOR_FLAG_* byte
    /// per monitor, to a client — or to every paired client when client_id
    /// is 0 (ids start at 1).
    virtual void send_monitor_list(uint32_t client_id,
                                   const std::vector<protocol::MonitorInfo>& monitors,
                                   const std::vector<uint8_t>& flags) = 0;

    /// Monitor count reported from now on (virtual displays come and go).
    virtual void set_monitor_count(uint8_t count) = 0;

    /// Send stream-start notification
    virtual void send_stream_start(uint32_t client_id,
                                   const protocol::StreamStart& info) = 0;

    /// Send STREAM_STOP for a monitor, to the client and its watchers
    virtual void send_stream_stop(uint32_t client_id, uint8_t monitor_id) = 0;

    /// Watchers (protocol::WatchCode) get a copy of their own of `owner`'s
    /// streams: announce one (also to watchers that join later), whether
    /// anybody watches `owner` now, and one encoded frame of it, to them all.
    virtual void send_watch_start(uint32_t owner, const protocol::StreamStart& info) = 0;
    virtual bool has_watchers(uint32_t owner) const = 0;
    virtual void send_watch_packet(uint32_t owner, uint8_t monitor_id, uint32_t frame_number,
                                   const uint8_t* data, uint32_t size) = 0;

    /// Send an encoded video packet via UDP
    virtual void send_video_packet(uint32_t client_id,
                                   uint8_t monitor_id,
                                   uint32_t frame_number,
                                   const uint8_t* data,
                                   uint32_t size) = 0;

    /// Send a raw control-channel message (TCP)
    virtual bool send_control_message(uint32_t client_id,
                                      protocol::MessageType type,
                                      const void* payload,
                                      size_t payload_size) = 0;

    /// Broadcast a UDP payload to all known clients (helper for audio channel)
    virtual void broadcast_udp(const uint8_t* data,
                               size_t size,
                               uint16_t port) = 0;

    /// Set event callbacks
    virtual void set_on_client_connected(ClientConnectedCallback cb) = 0;
    virtual void set_on_client_disconnected(ClientDisconnectedCallback cb) = 0;
    virtual void set_on_monitor_select(MonitorSelectCallback cb) = 0;
    virtual void set_on_multi_monitor_select(MultiMonitorSelectCallback cb) = 0;
    virtual void set_on_stream_config(StreamConfigCallback cb) = 0;
    virtual void set_on_input_mouse(InputMouseCallback cb) = 0;
    virtual void set_on_input_keyboard(InputKeyboardCallback cb) = 0;
    virtual void set_on_request_keyframe(RequestKeyframeCallback cb) = 0;
    virtual void set_on_virtual_display_create(VirtualDisplayCreateCallback cb) = 0;
    virtual void set_on_virtual_display_remove(VirtualDisplayRemoveCallback cb) = 0;
    virtual void set_on_pin_requested(PinRequestedCallback cb) = 0;
    virtual void set_on_screen_off(ScreenOffCallback cb) = 0;

    /// Settings panel (host/src/ui): change the pairing PIN (0 = none) and
    /// the HOST_FLAG_* bits while running. New flags are re-sent in a fresh
    /// HELLO_ACK to every paired client (clients treat it as an update).
    virtual void set_pin(uint32_t pin) = 0;
    virtual void set_host_flags(uint8_t flags) = 0;

    struct ClientInfo {
        uint32_t    id;
        std::string name;       ///< from HELLO
        std::string address;    ///< peer IPv4
        bool        tcp_media;  ///< HELLO_FLAG_TCP_MEDIA (USB)
        bool        watcher;    ///< HELLO_FLAG_WATCH: only watches another client's screens
    };
    /// Paired clients.
    virtual std::vector<ClientInfo> clients() const = 0;

    /// Drop a client. Its next HELLO from that address is refused once with
    /// REJECT_PIN_REQUIRED, so the headset stops auto-reconnecting and asks
    /// for the PIN instead of coming straight back.
    virtual void disconnect_client(uint32_t client_id) = 0;

    /// Share (0.05-1) of the configured video bitrate the client's link
    /// carries right now, adapted from its FRAME_ACKs across all its streams:
    /// cut at once on lost frames or a growing backlog, raised slowly while
    /// clean. Starts at 0.5 per connection; 1 for an unknown client.
    virtual float link_rate_scale(uint32_t client_id) const = 0;

    /// Check if server is running
    virtual bool is_running() const = 0;

    /// Get number of connected clients
    virtual uint32_t client_count() const = 0;
};

/// Create a network server instance
std::unique_ptr<INetworkServer> create_network_server();

/// This machine's name (gethostname), for discovery replies and the banner.
std::string local_host_name();

/// The IPv4 address this machine uses to reach the LAN (the source address
/// of its default route), or "" when it has none. Call after start() on
/// Windows (needs WSAStartup).
std::string primary_ipv4();

}  // namespace immersive
