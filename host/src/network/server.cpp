/// Network server implementation.
///
/// Manages TCP control channel for handshake/configuration/input
/// and UDP channel for video streaming.

#include "network/server.h"

#include <algorithm>
#include <iostream>
#include <thread>
#include <atomic>
#include <mutex>
#include <unordered_map>
#include <cstring>
#include <chrono>
#include <limits>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using SocketType = SOCKET;
constexpr SocketType INVALID_SOCK = INVALID_SOCKET;
// Windows headers define INPUT_MOUSE and INPUT_KEYBOARD as macros which
// collide with the protocol enum values. Undefine them after all Win32
// includes so the qualified name protocol::MessageType::INPUT_MOUSE compiles.
#ifdef INPUT_MOUSE
#  undef INPUT_MOUSE
#endif
#ifdef INPUT_KEYBOARD
#  undef INPUT_KEYBOARD
#endif
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
using SocketType = int;
constexpr SocketType INVALID_SOCK = -1;
inline void closesocket(int fd) { close(fd); }
#endif

namespace immersive {

/// Client state tracked by the server
struct ClientState {
    uint32_t            id;
    SocketType          tcp_socket;
    struct sockaddr_in  udp_addr;
    bool                udp_addr_set = false;
    std::string         name;
    struct FlowState {
        uint32_t last_ack = 0;
        bool     ack_seen = false;
        std::chrono::steady_clock::time_point last_log{};
    };
    std::unordered_map<uint8_t, FlowState> flow_state;
};

class NetworkServer : public INetworkServer {
public:
    NetworkServer() = default;

    ~NetworkServer() override {
        stop();
    }

    static constexpr uint32_t kMaxInFlightFrames = 6;

    bool start(const ServerConfig& config) override {
        if (running_) return false;
        config_ = config;

#ifdef _WIN32
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            std::cerr << "[Server] WSAStartup failed\n";
            return false;
        }
#endif

        // Create TCP listening socket
        tcp_socket_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (tcp_socket_ == INVALID_SOCK) {
            std::cerr << "[Server] Failed to create TCP socket\n";
            return false;
        }

        int reuse = 1;
        setsockopt(tcp_socket_, SOL_SOCKET, SO_REUSEADDR,
                   reinterpret_cast<const char*>(&reuse), sizeof(reuse));

        struct sockaddr_in tcp_addr = {};
        tcp_addr.sin_family = AF_INET;
        tcp_addr.sin_addr.s_addr = INADDR_ANY;
        tcp_addr.sin_port = htons(config_.tcp_port);

        if (bind(tcp_socket_, reinterpret_cast<struct sockaddr*>(&tcp_addr),
                 sizeof(tcp_addr)) < 0) {
            std::cerr << "[Server] TCP bind failed on port " << config_.tcp_port << "\n";
            closesocket(tcp_socket_);
            return false;
        }

        if (listen(tcp_socket_, 4) < 0) {
            std::cerr << "[Server] TCP listen failed\n";
            closesocket(tcp_socket_);
            return false;
        }

        // Create UDP socket
        udp_socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (udp_socket_ == INVALID_SOCK) {
            std::cerr << "[Server] Failed to create UDP socket\n";
            closesocket(tcp_socket_);
            return false;
        }

        // Aumentar el buffer de envío UDP a 2 MB
        int sndbuf = 2 * 1024 * 1024;
        setsockopt(udp_socket_, SOL_SOCKET, SO_SNDBUF, reinterpret_cast<const char*>(&sndbuf), sizeof(sndbuf));

        struct sockaddr_in udp_addr = {};
        udp_addr.sin_family = AF_INET;
        udp_addr.sin_addr.s_addr = INADDR_ANY;
        udp_addr.sin_port = htons(config_.udp_port);

        if (bind(udp_socket_, reinterpret_cast<struct sockaddr*>(&udp_addr),
                 sizeof(udp_addr)) < 0) {
            std::cerr << "[Server] UDP bind failed on port " << config_.udp_port << "\n";
            closesocket(tcp_socket_);
            closesocket(udp_socket_);
            return false;
        }

        running_ = true;

        // Start TCP accept thread
        tcp_thread_ = std::thread([this]() { tcp_accept_loop(); });

        std::cout << "[Server] Started on TCP:" << config_.tcp_port
                  << " UDP:" << config_.udp_port << "\n";
        return true;
    }

    void stop() override {
        if (!running_) return;
        running_ = false;

        closesocket(tcp_socket_);
        closesocket(udp_socket_);

        if (tcp_thread_.joinable()) tcp_thread_.join();

        // Close all client sockets
        std::lock_guard<std::mutex> lock(clients_mutex_);
        for (auto& [id, client] : clients_) {
            closesocket(client.tcp_socket);
        }
        clients_.clear();

#ifdef _WIN32
        WSACleanup();
#endif

        std::cout << "[Server] Stopped\n";
    }

    void send_monitor_list(uint32_t client_id,
                           const std::vector<protocol::MonitorInfo>& monitors) override {
        std::lock_guard<std::mutex> lock(clients_mutex_);
        auto it = clients_.find(client_id);
        if (it == clients_.end()) return;

        // Build message
        protocol::MonitorList list_header;
        list_header.count = static_cast<uint8_t>(monitors.size());

        uint32_t payload_size = sizeof(list_header) +
            static_cast<uint32_t>(monitors.size() * sizeof(protocol::MonitorInfo));

        protocol::ControlHeader header;
        header.type = static_cast<uint8_t>(protocol::MessageType::MONITOR_LIST);
        header.length = payload_size;

        send_tcp(it->second.tcp_socket, &header, sizeof(header));
        send_tcp(it->second.tcp_socket, &list_header, sizeof(list_header));
        for (const auto& mon : monitors) {
            send_tcp(it->second.tcp_socket, &mon, sizeof(mon));
        }
    }

    void send_stream_start(uint32_t client_id,
                           const protocol::StreamStart& info) override {
        send_control_message(client_id,
                             protocol::MessageType::STREAM_START,
                             &info,
                             sizeof(info));
    }

    void send_video_packet(uint32_t client_id,
                           uint8_t monitor_id,
                           uint32_t frame_number,
                           const uint8_t* data,
                           uint32_t size) override {
        std::lock_guard<std::mutex> lock(clients_mutex_);
        auto it = clients_.find(client_id);
        if (it == clients_.end() || !it->second.udp_addr_set) return;

        auto& flow = it->second.flow_state[monitor_id];
        if (frame_number == 0 || (flow.ack_seen && frame_number < flow.last_ack)) {
            flow.ack_seen = false;
            flow.last_ack = frame_number;
        }
        if (flow.ack_seen) {
            uint32_t backlog = (frame_number >= flow.last_ack)
                ? (frame_number - flow.last_ack)
                : 0;
            if (backlog > kMaxInFlightFrames) {
                auto now = std::chrono::steady_clock::now();
                if (flow.last_log.time_since_epoch().count() == 0 ||
                    std::chrono::duration_cast<std::chrono::milliseconds>(now - flow.last_log).count() > 500) {
                    std::cout << "[Server] Dropping frame " << frame_number
                              << " for client " << client_id
                              << " monitor " << static_cast<int>(monitor_id)
                              << " (backlog " << backlog << " > "
                              << kMaxInFlightFrames << ")\n";
                    flow.last_log = now;
                }
                return;
            }
        }

        uint16_t chunk_count = protocol::compute_chunk_count(size);

        for (uint16_t i = 0; i < chunk_count; ++i) {
            uint32_t offset = i * protocol::MAX_UDP_PAYLOAD;
            uint32_t chunk_size = std::min(
                static_cast<uint32_t>(protocol::MAX_UDP_PAYLOAD),
                size - offset);

            // Build UDP packet: header + payload
            std::vector<uint8_t> packet(sizeof(protocol::VideoPacketHeader) + chunk_size);

            protocol::VideoPacketHeader vph;
            vph.monitor_id = monitor_id;
            vph.frame_number = frame_number;
            vph.chunk_index = i;
            vph.chunk_count = chunk_count;

            std::memcpy(packet.data(), &vph, sizeof(vph));
            std::memcpy(packet.data() + sizeof(vph), data + offset, chunk_size);

            sendto(udp_socket_,
                   reinterpret_cast<const char*>(packet.data()),
                   static_cast<int>(packet.size()), 0,
                   reinterpret_cast<struct sockaddr*>(&it->second.udp_addr),
                   sizeof(it->second.udp_addr));
        }
    }

    bool send_control_message(uint32_t client_id,
                              protocol::MessageType type,
                              const void* payload,
                              size_t payload_size) override {
        if (payload_size > std::numeric_limits<uint32_t>::max()) {
            std::cerr << "[Server] Control payload too large: "
                      << payload_size << " bytes\n";
            return false;
        }

        std::lock_guard<std::mutex> lock(clients_mutex_);
        auto it = clients_.find(client_id);
        if (it == clients_.end()) return false;

        protocol::ControlHeader header;
        header.type = static_cast<uint8_t>(type);
        header.length = static_cast<uint32_t>(payload_size);

        if (!send_tcp(it->second.tcp_socket, &header, sizeof(header))) {
            return false;
        }
        if (payload_size > 0 && payload) {
            if (!send_tcp(it->second.tcp_socket, payload, payload_size)) {
                return false;
            }
        }
        return true;
    }

    void broadcast_udp(const uint8_t* data,
                       size_t size,
                       uint16_t port) override {
        if (!data || size == 0) return;
        std::lock_guard<std::mutex> lock(clients_mutex_);
        for (const auto& [id, client] : clients_) {
            if (!client.udp_addr_set) continue;
            auto dest = client.udp_addr;
            dest.sin_port = htons(port);
            sendto(udp_socket_,
                   reinterpret_cast<const char*>(data),
                   static_cast<int>(size),
                   0,
                   reinterpret_cast<struct sockaddr*>(&dest),
                   sizeof(dest));
        }
    }

    void set_on_client_connected(ClientConnectedCallback cb) override {
        on_connected_ = std::move(cb);
    }

    void set_on_client_disconnected(ClientDisconnectedCallback cb) override {
        on_disconnected_ = std::move(cb);
    }

    void set_on_monitor_select(MonitorSelectCallback cb) override {
        on_monitor_select_ = std::move(cb);
    }

    void set_on_input_mouse(InputMouseCallback cb) override {
        on_input_mouse_ = std::move(cb);
    }

    void set_on_input_keyboard(InputKeyboardCallback cb) override {
        on_input_keyboard_ = std::move(cb);
    }

    bool is_running() const override { return running_; }

    uint32_t client_count() const override {
        std::lock_guard<std::mutex> lock(clients_mutex_);
        return static_cast<uint32_t>(clients_.size());
    }

private:
    void tcp_accept_loop() {
        while (running_) {
            struct sockaddr_in client_addr;
            socklen_t addr_len = sizeof(client_addr);

            SocketType client_sock = accept(tcp_socket_,
                reinterpret_cast<struct sockaddr*>(&client_addr), &addr_len);

            if (client_sock == INVALID_SOCK) {
                if (running_) {
                    std::cerr << "[Server] Accept failed\n";
                }
                continue;
            }

            uint32_t client_id = next_client_id_++;

            {
                std::lock_guard<std::mutex> lock(clients_mutex_);
                ClientState state;
                state.id = client_id;
                state.tcp_socket = client_sock;
                state.udp_addr = client_addr;
                state.udp_addr.sin_port = htons(config_.udp_port);
                state.udp_addr_set = true;
                clients_[client_id] = state;
            }

            std::cout << "[Server] Client " << client_id << " connected from "
                      << inet_ntoa(client_addr.sin_addr) << "\n";

            if (on_connected_) on_connected_(client_id);

            // Start a client handler thread
            std::thread([this, client_id]() {
                handle_client(client_id);
            }).detach();
        }
    }

    void handle_client(uint32_t client_id) {
        SocketType sock;
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            auto it = clients_.find(client_id);
            if (it == clients_.end()) return;
            sock = it->second.tcp_socket;
        }

        while (running_) {
            protocol::ControlHeader header;
            if (!recv_exact(sock, &header, sizeof(header))) break;

            // Read payload
            std::vector<uint8_t> payload(header.length);
            if (header.length > 0) {
                if (!recv_exact(sock, payload.data(), header.length)) break;
            }

            // Dispatch by message type
            auto msg_type = static_cast<protocol::MessageType>(header.type);
            switch (msg_type) {
            case protocol::MessageType::HELLO: {
                if (payload.size() >= sizeof(protocol::Hello)) {
                    protocol::Hello hello;
                    std::memcpy(&hello, payload.data(), sizeof(hello));
                    std::cout << "[Server] Client " << client_id
                              << " says hello: " << hello.client_name << "\n";

                    // Send HELLO_ACK de forma segura para evitar mezclar bytes
                    protocol::HelloAck ack;
                    ack.protocol_version = protocol::PROTOCOL_VERSION;
                    ack.udp_port = config_.udp_port;
                    ack.monitor_count = 0;

                    send_control_message(client_id, protocol::MessageType::HELLO_ACK, &ack, sizeof(ack));
                }
                break;
            }
            case protocol::MessageType::MONITOR_SELECT: {
                if (payload.size() >= sizeof(protocol::MonitorSelect)) {
                    protocol::MonitorSelect sel;
                    std::memcpy(&sel, payload.data(), sizeof(sel));
                    if (on_monitor_select_) {
                        on_monitor_select_(client_id, sel.monitor_id);
                    }
                }
                break;
            }
            case protocol::MessageType::INPUT_MOUSE: {
                if (payload.size() >= sizeof(protocol::InputMouse)) {
                    protocol::InputMouse input;
                    std::memcpy(&input, payload.data(), sizeof(input));
                    if (on_input_mouse_) {
                        on_input_mouse_(client_id, input);
                    }
                }
                break;
            }
            case protocol::MessageType::INPUT_KEYBOARD: {
                if (payload.size() >= sizeof(protocol::InputKeyboard)) {
                    protocol::InputKeyboard input;
                    std::memcpy(&input, payload.data(), sizeof(input));
                    if (on_input_keyboard_) {
                        on_input_keyboard_(client_id, input);
                    }
                }
                break;
            }
            case protocol::MessageType::MULTI_MONITOR_SELECT: {
                if (payload.size() >= sizeof(protocol::MultiMonitorSelect)) {
                    protocol::MultiMonitorSelect sel;
                    std::memcpy(&sel, payload.data(), sizeof(sel));
                    std::cout << "[Server] Client " << client_id
                              << " selected " << (int)sel.monitor_count
                              << " monitor(s)\n";
                    // Forward each selected monitor via existing callback
                    for (uint8_t i = 0; i < sel.monitor_count && i < 3; ++i) {
                        if (sel.monitor_ids[i] != 0xFF && on_monitor_select_) {
                            on_monitor_select_(client_id, sel.monitor_ids[i]);
                        }
                    }
                }
                break;
            }
            case protocol::MessageType::FRAME_ACK: {
                // Flow control: client acknowledged a frame — currently logged only
                if (payload.size() >= sizeof(protocol::FrameAck)) {
                    protocol::FrameAck ack;
                    std::memcpy(&ack, payload.data(), sizeof(ack));
                    std::lock_guard<std::mutex> lock(clients_mutex_);
                    auto it = clients_.find(client_id);
                    if (it != clients_.end()) {
                        auto& flow = it->second.flow_state[ack.monitor_id];
                        flow.ack_seen = true;
                        flow.last_ack = std::max(flow.last_ack, ack.frame_number);
                    }
                }
                break;
            }
            case protocol::MessageType::LATENCY_PROBE: {
                if (payload.size() >= sizeof(protocol::LatencyProbe)) {
                    protocol::LatencyProbe probe;
                    std::memcpy(&probe, payload.data(), sizeof(probe));

                    // Build LATENCY_RESPONSE
                    protocol::LatencyResponse resp;
                    resp.probe_id          = probe.probe_id;
                    resp.client_timestamp  = probe.client_timestamp;
                    auto now = std::chrono::steady_clock::now();
                    resp.server_timestamp = static_cast<uint64_t>(
                        std::chrono::duration_cast<std::chrono::microseconds>(
                            now.time_since_epoch()).count());

                    send_control_message(client_id,
                                         protocol::MessageType::LATENCY_RESPONSE,
                                         &resp,
                                         sizeof(resp));
                }
                break;
            }
            case protocol::MessageType::PING: {
                // Echo back de forma segura
                send_control_message(client_id, protocol::MessageType::PING, nullptr, 0);
                break;
            }
            default:
                std::cerr << "[Server] Unknown message type: 0x"
                          << std::hex << (int)header.type << "\n";
                break;
            }
        }

        // Client disconnected
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            auto it = clients_.find(client_id);
            if (it != clients_.end()) {
                closesocket(it->second.tcp_socket);
                clients_.erase(it);
            }
        }

        std::cout << "[Server] Client " << client_id << " disconnected\n";
        if (on_disconnected_) on_disconnected_(client_id);
    }

    /// Receive exactly `size` bytes from a TCP socket.
    /// Returns true on success, false on error or disconnect.
    static bool recv_exact(SocketType sock, void* buf, size_t size) {
        char* ptr = reinterpret_cast<char*>(buf);
        size_t remaining = size;
        while (remaining > 0) {
            int n = recv(sock, ptr, static_cast<int>(remaining), 0);
            if (n <= 0) return false;
            ptr += n;
            remaining -= static_cast<size_t>(n);
        }
        return true;
    }

    /// Send exactly `size` bytes (send() may transmit fewer in one call).
    static bool send_tcp(SocketType sock, const void* data, size_t size) {
        const char* ptr = reinterpret_cast<const char*>(data);
        size_t remaining = size;
        while (remaining > 0) {
            int sent = send(sock, ptr, static_cast<int>(remaining), 0);
            if (sent <= 0) return false;
            ptr += sent;
            remaining -= static_cast<size_t>(sent);
        }
        return true;
    }

    ServerConfig config_;
    std::atomic<bool> running_{false};
    uint32_t next_client_id_ = 1;

    SocketType tcp_socket_ = INVALID_SOCK;
    SocketType udp_socket_ = INVALID_SOCK;

    std::thread tcp_thread_;

    mutable std::mutex clients_mutex_;
    std::unordered_map<uint32_t, ClientState> clients_;

    ClientConnectedCallback     on_connected_;
    ClientDisconnectedCallback  on_disconnected_;
    MonitorSelectCallback       on_monitor_select_;
    InputMouseCallback          on_input_mouse_;
    InputKeyboardCallback       on_input_keyboard_;
};

std::unique_ptr<INetworkServer> create_network_server() {
    return std::make_unique<NetworkServer>();
}

}  // namespace immersive
