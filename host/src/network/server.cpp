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
#include <set>
#include <vector>
#include <cstring>
#include <chrono>
#include <limits>
#include <cstddef>
#include <string>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using SocketType = SOCKET;
constexpr SocketType INVALID_SOCK = INVALID_SOCKET;
constexpr int SHUTDOWN_BOTH = SD_BOTH;
constexpr int SEND_FLAGS = 0;  // Winsock has no SIGPIPE to suppress
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
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <netdb.h>
using SocketType = int;
constexpr SocketType INVALID_SOCK = -1;
constexpr int SHUTDOWN_BOTH = SHUT_RDWR;
// Writing to a socket the peer has reset raises SIGPIPE, whose default action
// kills the process. A VR client that drops off Wi-Fi mid-handshake did exactly
// that. MSG_NOSIGNAL turns it into EPIPE; macOS has no such flag, so the
// SO_NOSIGPIPE socket option is set per socket instead (and main() also
// installs SIG_IGN as a backstop).
#ifdef MSG_NOSIGNAL
constexpr int SEND_FLAGS = MSG_NOSIGNAL;
#else
constexpr int SEND_FLAGS = 0;
#endif
inline void closesocket(int fd) { close(fd); }
#endif

namespace immersive {

/// Client state tracked by the server
struct ClientState {
    uint32_t            id;
    SocketType          tcp_socket;
    struct sockaddr_in  udp_addr;
    bool                udp_addr_set = false;
    bool                tcp_media = false;  ///< HELLO_FLAG_TCP_MEDIA: video/audio in-band on TCP
    bool                authed = false;     ///< HELLO accepted (PIN checked); nothing else is served before
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

    /// Hard ceiling on a control-message payload. Every message defined in
    /// protocol.h is a few dozen bytes; anything larger is a corrupt stream or a
    /// hostile peer, and allocating on an attacker-chosen 32-bit length would
    /// throw bad_alloc (or thrash) instead of just dropping the connection.
    static constexpr uint32_t kMaxControlPayload = 64 * 1024;

    /// A socket that has not sent an accepted HELLO within this many seconds
    /// is dropped, and at most kMaxPending such sockets exist on top of
    /// --max-clients, so idle connections can't starve the real headset.
    static constexpr int      kHelloTimeoutS = 5;
    static constexpr uint32_t kMaxPending = 8;

    bool start(const ServerConfig& config) override {
        if (running_) return false;
        config_ = config;
        monitor_count_ = config.monitor_count;

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

        // The UDP socket is SEND-ONLY: the host transmits video to
        // <client>:udp_port and audio to <client>:audio_port, and never
        // recvfrom()s on it. Binding it to the fixed udp_port is therefore
        // unnecessary and actively harmful — when the host and the VR client
        // run on the same machine (local testing) the host would squat
        // udp_port, leaving the client unable to bind it to RECEIVE video.
        // Audio keeps working because it uses a different port, producing the
        // exact "audio plays but the screen stays black" symptom. Bind to an
        // ephemeral port (0) so the client always owns udp_port for receiving.
        struct sockaddr_in udp_addr = {};
        udp_addr.sin_family = AF_INET;
        udp_addr.sin_addr.s_addr = INADDR_ANY;
        udp_addr.sin_port = htons(0);

        if (bind(udp_socket_, reinterpret_cast<struct sockaddr*>(&udp_addr),
                 sizeof(udp_addr)) < 0) {
            std::cerr << "[Server] UDP bind failed\n";
            closesocket(tcp_socket_);
            closesocket(udp_socket_);
            return false;
        }

        // LAN discovery: answer DiscoveryRequest broadcasts on UDP <tcp_port>.
        // Optional — without it clients can still type the IP.
        host_name_ = local_host_name();
        discovery_socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        struct sockaddr_in disc_addr = {};
        disc_addr.sin_family = AF_INET;
        disc_addr.sin_addr.s_addr = INADDR_ANY;
        disc_addr.sin_port = htons(config_.tcp_port);
        if (discovery_socket_ != INVALID_SOCK &&
            bind(discovery_socket_, reinterpret_cast<struct sockaddr*>(&disc_addr),
                 sizeof(disc_addr)) < 0) {
            std::cerr << "[Server] LAN discovery unavailable (UDP " << config_.tcp_port
                      << " busy); clients must enter this PC's IP\n";
            closesocket(discovery_socket_);
            discovery_socket_ = INVALID_SOCK;
        }

        running_ = true;

        // Start TCP accept thread
        tcp_thread_ = std::thread([this]() { tcp_accept_loop(); });
        if (discovery_socket_ != INVALID_SOCK)
            discovery_thread_ = std::thread([this]() { discovery_loop(); });

        std::cout << "[Server] Started on TCP:" << config_.tcp_port
                  << " UDP:" << config_.udp_port << "\n";
        return true;
    }

    void stop() override {
        if (!running_) return;
        running_ = false;

        // The accept loop polls running_ every 200 ms, so join it BEFORE
        // closing the listening socket: closing it underneath the loop was a
        // data race on tcp_socket_ and could hand FD_SET() a -1 (a fortified
        // glibc aborts on that).
        if (tcp_thread_.joinable()) tcp_thread_.join();
        closesocket(tcp_socket_);
        tcp_socket_ = INVALID_SOCK;
        if (discovery_thread_.joinable()) discovery_thread_.join();
        if (discovery_socket_ != INVALID_SOCK) closesocket(discovery_socket_);
        discovery_socket_ = INVALID_SOCK;

        // shutdown() (not closesocket()) so each handler thread's blocking
        // recv() returns while its descriptor stays valid — the thread closes
        // and erases its own entry. Closing here instead would let the OS
        // recycle the descriptor number under a thread still using it.
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            for (auto& [id, client] : clients_) {
                shutdown(client.tcp_socket, SHUTDOWN_BOTH);
            }
        }

        // Join the handler threads before returning: they invoke the
        // disconnect callback, which captures objects owned by main(). A
        // detached thread firing that callback after main() unwound was a
        // use-after-free on every shutdown.
        // Move them out first: a finishing handler thread takes threads_mutex_
        // on its way out, so joining while holding it would deadlock.
        std::vector<std::thread> pending;
        {
            std::lock_guard<std::mutex> lock(threads_mutex_);
            pending.swap(client_threads_);
            finished_threads_.clear();
        }
        for (auto& t : pending) {
            if (t.joinable()) t.join();
        }

        closesocket(udp_socket_);
        udp_socket_ = INVALID_SOCK;

        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            clients_.clear();
        }

#ifdef _WIN32
        WSACleanup();
#endif

        std::cout << "[Server] Stopped\n";
    }

    void send_monitor_list(uint32_t client_id,
                           const std::vector<protocol::MonitorInfo>& monitors,
                           const std::vector<uint8_t>& flags) override {
        // count, the records, then one MONITOR_FLAG_* byte per record
        // (older clients stop after the records).
        const size_t count = std::min<size_t>(monitors.size(), 255);
        std::vector<uint8_t> msg(sizeof(protocol::ControlHeader) + 1 +
                                 count * (sizeof(protocol::MonitorInfo) + 1));
        protocol::ControlHeader header;
        header.type = static_cast<uint8_t>(protocol::MessageType::MONITOR_LIST);
        header.length = static_cast<uint32_t>(msg.size() - sizeof(header));
        std::memcpy(msg.data(), &header, sizeof(header));
        uint8_t* p = msg.data() + sizeof(header);
        *p++ = static_cast<uint8_t>(count);
        std::memcpy(p, monitors.data(), count * sizeof(protocol::MonitorInfo));
        p += count * sizeof(protocol::MonitorInfo);
        for (size_t i = 0; i < count; ++i) *p++ = i < flags.size() ? flags[i] : 0;

        std::lock_guard<std::mutex> lock(clients_mutex_);
        for (auto& [id, client] : clients_) {
            if (client_id ? id != client_id : !client.authed) continue;
            if (!send_tcp(client.tcp_socket, msg.data(), msg.size()))
                shutdown(client.tcp_socket, SHUTDOWN_BOTH);
        }
    }

    void set_monitor_count(uint8_t count) override { monitor_count_ = count; }

    void send_stream_start(uint32_t client_id,
                           const protocol::StreamStart& info) override {
        {
            // A new stream numbers its frames from info.first_frame: forget
            // the previous stream's acknowledgements.
            std::lock_guard<std::mutex> lock(clients_mutex_);
            auto it = clients_.find(client_id);
            if (it != clients_.end()) it->second.flow_state.erase(info.monitor_id);
        }
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
        // Flow-control bookkeeping needs the client map; the sendto() burst
        // does not. One 1080p frame is ~100-200 chunks, so holding
        // clients_mutex_ across the whole burst serialised every monitor's
        // worker (and the ACK handler) behind one stream. Take the lock only
        // long enough to copy the destination out.
        struct sockaddr_in dest;
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            auto it = clients_.find(client_id);
            if (it == clients_.end() || !it->second.udp_addr_set) return;
            dest = it->second.udp_addr;

            if (it->second.tcp_media) {
                // ponytail: the whole frame is written under clients_mutex_,
                // serialising every monitor (they share this one socket anyway).
                // SO_SNDTIMEO bounds the hold; a per-client send lock if it shows.
                protocol::VideoFrameHeader vfh{monitor_id, frame_number};
                send_media_locked(it->second, protocol::MessageType::VIDEO_FRAME,
                                  &vfh, sizeof(vfh), data, size);
                return;
            }

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
                    // The client has fallen behind (slow decode or Wi-Fi chunk
                    // loss). Do NOT stop sending: catching up requires frames
                    // we'd be refusing to send, so a `return` here deadlocks
                    // the stream into a permanent black screen (the client can
                    // never ACK, so last_ack stays frozen and every future
                    // frame is dropped). Instead resync the flow window to the
                    // present and keep streaming the freshest frame.
                    auto now = std::chrono::steady_clock::now();
                    if (flow.last_log.time_since_epoch().count() == 0 ||
                        std::chrono::duration_cast<std::chrono::milliseconds>(now - flow.last_log).count() > 500) {
                        std::cout << "[Server] Client " << client_id
                                  << " monitor " << static_cast<int>(monitor_id)
                                  << " lagging (backlog " << backlog << " > "
                                  << kMaxInFlightFrames << "), resyncing flow window\n";
                        flow.last_log = now;
                    }
                    flow.last_ack = frame_number;
                }
            }
        }

        const uint16_t chunk_count = protocol::compute_chunk_count(size);

        // One reusable packet buffer per sending thread (each monitor has its
        // own worker), instead of a heap allocation per chunk — ~150 malloc/free
        // pairs per frame, per monitor, at up to 60 fps.
        thread_local std::vector<uint8_t> packet;
        packet.resize(sizeof(protocol::VideoPacketHeader) + protocol::MAX_UDP_PAYLOAD);

        protocol::VideoPacketHeader vph;
        vph.monitor_id   = monitor_id;
        vph.frame_number = frame_number;
        vph.chunk_count  = chunk_count;

        for (uint16_t i = 0; i < chunk_count; ++i) {
            const uint32_t offset = static_cast<uint32_t>(i) * protocol::MAX_UDP_PAYLOAD;
            const uint32_t chunk_size = std::min(
                static_cast<uint32_t>(protocol::MAX_UDP_PAYLOAD),
                size - offset);

            vph.chunk_index = i;
            std::memcpy(packet.data(), &vph, sizeof(vph));
            std::memcpy(packet.data() + sizeof(vph), data + offset, chunk_size);

            sendto(udp_socket_,
                   reinterpret_cast<const char*>(packet.data()),
                   static_cast<int>(sizeof(vph) + chunk_size), 0,
                   reinterpret_cast<struct sockaddr*>(&dest),
                   sizeof(dest));
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

        if (!send_tcp(it->second.tcp_socket, &header, sizeof(header)) ||
            (payload_size > 0 && payload &&
             !send_tcp(it->second.tcp_socket, payload, payload_size))) {
            // A timed-out (SO_SNDTIMEO) write can stop mid-message; anything
            // sent after it would be parsed out of frame. Drop the connection
            // like send_media_locked does; the handler thread cleans it up.
            shutdown(it->second.tcp_socket, SHUTDOWN_BOTH);
            return false;
        }
        return true;
    }

    void broadcast_udp(const uint8_t* data,
                       size_t size,
                       uint16_t port) override {
        if (!data || size == 0) return;
        std::lock_guard<std::mutex> lock(clients_mutex_);
        for (auto& [id, client] : clients_) {
            if (!client.authed) continue;  // no audio before the PIN is checked
            if (client.tcp_media) {
                send_media_locked(client, protocol::MessageType::AUDIO_DATA,
                                  nullptr, 0, data, size);
                continue;
            }
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

    void set_on_multi_monitor_select(MultiMonitorSelectCallback cb) override {
        on_multi_monitor_select_ = std::move(cb);
    }

    void set_on_stream_config(StreamConfigCallback cb) override {
        on_stream_config_ = std::move(cb);
    }

    void set_on_input_mouse(InputMouseCallback cb) override {
        on_input_mouse_ = std::move(cb);
    }

    void set_on_input_keyboard(InputKeyboardCallback cb) override {
        on_input_keyboard_ = std::move(cb);
    }

    void set_on_request_keyframe(RequestKeyframeCallback cb) override {
        on_request_keyframe_ = std::move(cb);
    }

    void set_on_virtual_display_create(VirtualDisplayCreateCallback cb) override {
        on_vdisplay_create_ = std::move(cb);
    }

    void set_on_virtual_display_remove(VirtualDisplayRemoveCallback cb) override {
        on_vdisplay_remove_ = std::move(cb);
    }

    bool is_running() const override { return running_; }

    uint32_t client_count() const override {
        std::lock_guard<std::mutex> lock(clients_mutex_);
        return static_cast<uint32_t>(clients_.size());
    }

private:
    void tcp_accept_loop() {
        while (running_) {
            // Wait for a pending connection with a timeout instead of blocking
            // in accept(). Closing the listening socket from stop() does NOT
            // wake a thread already blocked in accept() (Linux leaves it parked
            // in inet_csk_accept), so the join in stop() hung forever and the
            // host never exited on Ctrl+C. Polling means stop() is noticed
            // within one tick, whatever the platform does with the descriptor.
            fd_set readable;
            FD_ZERO(&readable);
            FD_SET(tcp_socket_, &readable);
            struct timeval tv;
            tv.tv_sec  = 0;
            tv.tv_usec = 200000;  // 200 ms

            int ready = select(static_cast<int>(tcp_socket_) + 1,
                               &readable, nullptr, nullptr, &tv);
            if (!running_) break;
            if (ready == 0) continue;           // nothing pending, re-check running_
            if (ready < 0) {
                std::cerr << "[Server] Accept wait failed\n";
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                continue;
            }

            struct sockaddr_in client_addr;
            socklen_t addr_len = sizeof(client_addr);

            SocketType client_sock = accept(tcp_socket_,
                reinterpret_cast<struct sockaddr*>(&client_addr), &addr_len);

            if (client_sock == INVALID_SOCK) {
                if (!running_) break;
                // A persistent failure (descriptor exhaustion, for instance)
                // would otherwise spin this loop at 100% CPU forever.
                std::cerr << "[Server] Accept failed\n";
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                continue;
            }

            // --max-clients counts paired clients (checked on HELLO), so idle
            // sockets that never say hello can't lock the headset out. This
            // cap only bounds the handler threads; pending sockets time out
            // after kHelloTimeoutS anyway.
            {
                std::lock_guard<std::mutex> lock(clients_mutex_);
                if (clients_.size() >= config_.max_clients + kMaxPending) {
                    std::cerr << "[Server] Rejecting connection from "
                              << inet_ntoa(client_addr.sin_addr)
                              << ": client limit (" << config_.max_clients
                              << ") reached\n";
                    // Say why, so the headset shows it instead of retrying blind.
                    send_reject(client_sock, protocol::REJECT_SERVER_FULL);
                    closesocket(client_sock);
                    continue;
                }
            }

            // Reap handler threads of clients that already went away, so the
            // vector doesn't grow for the lifetime of the process.
            {
                std::lock_guard<std::mutex> lock(threads_mutex_);
                for (auto it = client_threads_.begin(); it != client_threads_.end();) {
                    if (it->joinable() && finished_threads_.count(it->get_id())) {
                        finished_threads_.erase(it->get_id());
                        it->join();
                        it = client_threads_.erase(it);
                    } else {
                        ++it;
                    }
                }
            }

            suppress_sigpipe(client_sock);
            enable_keepalive(client_sock);
            set_recv_timeout(client_sock, kHelloTimeoutS);  // cleared once HELLO passes
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

            // Tracked (not detached) so stop() can join it — see stop().
            {
                std::lock_guard<std::mutex> lock(threads_mutex_);
                client_threads_.emplace_back([this, client_id]() {
                    handle_client(client_id);
                    std::lock_guard<std::mutex> l(threads_mutex_);
                    finished_threads_.insert(std::this_thread::get_id());
                });
            }
        }
    }

    void handle_client(uint32_t client_id) {
        SocketType sock;
        struct in_addr peer;
        bool authed = false;
        bool rejected = false;
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            auto it = clients_.find(client_id);
            if (it == clients_.end()) return;
            sock = it->second.tcp_socket;
            peer = it->second.udp_addr.sin_addr;
        }

        while (running_) {
            protocol::ControlHeader header;
            if (!recv_exact(sock, &header, sizeof(header))) break;

            if (header.length > kMaxControlPayload) {
                std::cerr << "[Server] Client " << client_id
                          << " sent an oversized control message ("
                          << header.length << " bytes), dropping connection\n";
                break;
            }

            // Read payload
            std::vector<uint8_t> payload(header.length);
            if (header.length > 0) {
                if (!recv_exact(sock, payload.data(), header.length)) break;
            }

            // Dispatch by message type
            auto msg_type = static_cast<protocol::MessageType>(header.type);
            if (!authed && msg_type != protocol::MessageType::HELLO) {
                // Input, monitor selection, everything waits for a HELLO
                // that passed the PIN check.
                std::cerr << "[Server] Client " << client_id
                          << " sent a request before HELLO, dropping connection\n";
                break;
            }
            if (authed && msg_type == protocol::MessageType::HELLO) continue;
            switch (msg_type) {
            case protocol::MessageType::HELLO: {
                // Clients older than the flags byte send one byte less.
                if (payload.size() >= offsetof(protocol::Hello, flags)) {
                    protocol::Hello hello{};
                    std::memcpy(&hello, payload.data(),
                                std::min(payload.size(), sizeof(hello)));
                    const bool tcp_media = (hello.flags & protocol::HELLO_FLAG_TCP_MEDIA) != 0;
                    std::cout << "[Server] Client " << client_id << " says hello: "
                              << std::string(hello.client_name,
                                             strnlen(hello.client_name, sizeof(hello.client_name)))
                              << (tcp_media ? " (video/audio over TCP)" : "") << "\n";

                    const uint8_t reject = check_pin(peer, hello.pin);
                    if (reject) {
                        std::cerr << "[Server] Client " << client_id << " refused: "
                                  << (reject == protocol::REJECT_PIN_REQUIRED ? "no PIN"
                                      : reject == protocol::REJECT_WRONG_PIN ? "wrong PIN"
                                      : "too many wrong PINs, locked out for a minute")
                                  << " (the PIN is shown in this window)\n";
                        send_reject(sock, reject);
                        rejected = true;
                        break;
                    }
                    {
                        std::lock_guard<std::mutex> lock(clients_mutex_);
                        uint32_t paired = 0;
                        for (const auto& [id, c] : clients_) paired += c.authed ? 1 : 0;
                        if (paired >= config_.max_clients) {
                            std::cerr << "[Server] Client " << client_id
                                      << " refused: client limit (" << config_.max_clients
                                      << ") reached\n";
                            send_reject(sock, protocol::REJECT_SERVER_FULL);
                            rejected = true;
                            break;
                        }
                        auto it = clients_.find(client_id);
                        if (it != clients_.end()) it->second.authed = true;
                    }
                    authed = true;
                    set_recv_timeout(sock, 0);  // paired: idle is fine now (keepalive covers dead peers)
                    if (tcp_media) {
                        // A client that stops reading must not wedge the
                        // sender (and clients_mutex_) forever: a timed-out
                        // send drops the connection instead.
                        set_send_timeout(sock, 3);
                        std::lock_guard<std::mutex> lock(clients_mutex_);
                        auto it = clients_.find(client_id);
                        if (it != clients_.end()) it->second.tcp_media = true;
                    }

                    protocol::HelloAck ack{};
                    ack.protocol_version = protocol::PROTOCOL_VERSION;
                    ack.udp_port = config_.udp_port;
                    ack.monitor_count = monitor_count_;
                    ack.flags = config_.host_flags;
                    std::strncpy(ack.host_name, host_name_.c_str(), sizeof(ack.host_name) - 1);

                    send_control_message(client_id, protocol::MessageType::HELLO_ACK, &ack, sizeof(ack));
                    // Monitor list and audio announcement follow the ACK.
                    if (on_connected_) on_connected_(client_id);
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

                    std::vector<uint8_t> ids;
                    for (uint8_t i = 0; i < sel.monitor_count && i < 3; ++i) {
                        if (sel.monitor_ids[i] != 0xFF) {
                            ids.push_back(sel.monitor_ids[i]);
                        }
                    }

                    if (on_multi_monitor_select_) {
                        on_multi_monitor_select_(client_id, ids);
                    } else if (on_monitor_select_) {
                        // Legacy fallback: forward each id individually
                        for (uint8_t id : ids) {
                            on_monitor_select_(client_id, id);
                        }
                    }
                }
                break;
            }
            case protocol::MessageType::STREAM_CONFIG: {
                if (payload.size() >= sizeof(protocol::StreamConfig)) {
                    protocol::StreamConfig cfg;
                    std::memcpy(&cfg, payload.data(), sizeof(cfg));
                    std::cout << "[Server] Client " << client_id
                              << " stream config: codec=" << (int)cfg.codec
                              << " bitrate=" << cfg.bitrate_kbps
                              << " jpegq=" << (int)cfg.jpeg_quality
                              << " max_width=" << cfg.max_width
                              << " max_fps=" << (int)cfg.max_fps << "\n";
                    if (on_stream_config_) {
                        on_stream_config_(client_id, cfg);
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
            case protocol::MessageType::REQUEST_KEYFRAME: {
                if (payload.size() >= sizeof(protocol::RequestKeyframe)) {
                    protocol::RequestKeyframe req;
                    std::memcpy(&req, payload.data(), sizeof(req));
                    if (on_request_keyframe_) {
                        on_request_keyframe_(client_id, req.monitor_id);
                    }
                }
                break;
            }
            case protocol::MessageType::VIRTUAL_DISPLAY_CREATE: {
                if (payload.size() >= sizeof(protocol::VirtualDisplayCreate) && on_vdisplay_create_) {
                    protocol::VirtualDisplayCreate req;
                    std::memcpy(&req, payload.data(), sizeof(req));
                    on_vdisplay_create_(client_id, req);
                }
                break;
            }
            case protocol::MessageType::VIRTUAL_DISPLAY_REMOVE: {
                if (payload.size() >= sizeof(protocol::VirtualDisplayRemove) && on_vdisplay_remove_) {
                    on_vdisplay_remove_(client_id, payload[0]);
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
                          << std::hex << (int)header.type << std::dec << "\n";
                break;
            }
            if (rejected) break;
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

    /// 0 when a HELLO carrying `pin` from `peer` may proceed, else the
    /// REJECT_* reason. 127.0.0.1 is trusted: it is a process on this PC or a
    /// headset on the USB cable (`adb reverse`, which the headset authorised).
    /// Five wrong PINs from one address lock it out for a minute, and every
    /// wrong answer costs half a second, so the 900 000 PINs can't be walked.
    uint8_t check_pin(struct in_addr peer, uint32_t pin) {
        if (config_.pin == 0 || peer.s_addr == htonl(INADDR_LOOPBACK)) return 0;
        const auto now = std::chrono::steady_clock::now();
        {
            std::lock_guard<std::mutex> lock(auth_mutex_);
            auto& st = auth_failures_[peer.s_addr];
            if (now < st.locked_until) return protocol::REJECT_LOCKED_OUT;
            if (pin == config_.pin) { st.failures = 0; return 0; }
            if (pin == 0) return protocol::REJECT_PIN_REQUIRED;
            if (++st.failures >= 5) {
                st.failures = 0;
                st.locked_until = now + std::chrono::seconds(60);
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        return protocol::REJECT_WRONG_PIN;
    }

    /// Write one HELLO_REJECT straight to a socket (no client entry needed).
    static void send_reject(SocketType sock, uint8_t reason) {
        protocol::ControlHeader header{static_cast<uint8_t>(protocol::MessageType::HELLO_REJECT), 1};
        uint8_t msg[sizeof(header) + 1];
        std::memcpy(msg, &header, sizeof(header));
        msg[sizeof(header)] = reason;
        send_tcp(sock, msg, sizeof(msg));
    }

    /// Answer LAN discovery broadcasts until stop(). Polls like the accept
    /// loop so stop() is noticed within 200 ms.
    void discovery_loop() {
        while (running_) {
            fd_set readable;
            FD_ZERO(&readable);
            FD_SET(discovery_socket_, &readable);
            struct timeval tv{0, 200000};
            if (select(static_cast<int>(discovery_socket_) + 1, &readable,
                       nullptr, nullptr, &tv) <= 0) continue;

            protocol::DiscoveryRequest req{};
            struct sockaddr_in from{};
            socklen_t from_len = sizeof(from);
            const int n = recvfrom(discovery_socket_, reinterpret_cast<char*>(&req), sizeof(req), 0,
                                   reinterpret_cast<struct sockaddr*>(&from), &from_len);
            if (n < static_cast<int>(sizeof(req)) ||
                req.magic != protocol::DISCOVERY_REQUEST_MAGIC) continue;

            protocol::DiscoveryReply reply{};
            reply.magic            = protocol::DISCOVERY_REPLY_MAGIC;
            reply.protocol_version = protocol::PROTOCOL_VERSION;
            reply.tcp_port         = config_.tcp_port;
            reply.monitor_count    = monitor_count_;
            reply.flags            = (config_.pin ? protocol::DISCOVERY_FLAG_PIN : 0) |
                                     ((config_.host_flags & protocol::HOST_FLAG_VIEW_ONLY)
                                          ? protocol::DISCOVERY_FLAG_VIEW_ONLY : 0);
            std::strncpy(reply.host_name, host_name_.c_str(), sizeof(reply.host_name) - 1);
            sendto(discovery_socket_, reinterpret_cast<const char*>(&reply), sizeof(reply), 0,
                   reinterpret_cast<struct sockaddr*>(&from), from_len);
        }
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
            int sent = send(sock, ptr, static_cast<int>(remaining), SEND_FLAGS);
            if (sent <= 0) return false;
            ptr += sent;
            remaining -= static_cast<size_t>(sent);
        }
        return true;
    }

    /// Send one host → client media message (header + optional prefix + data)
    /// on the control socket. Caller holds clients_mutex_, which is what keeps
    /// it from interleaving with other control messages. A failed or timed-out
    /// write leaves a half-sent message on the stream, so the connection is
    /// shut down; its handler thread then cleans it up as a normal disconnect.
    static void send_media_locked(ClientState& client, protocol::MessageType type,
                                  const void* prefix, size_t prefix_size,
                                  const uint8_t* data, size_t size) {
        protocol::ControlHeader header;
        header.type   = static_cast<uint8_t>(type);
        header.length = static_cast<uint32_t>(prefix_size + size);
        if (!send_tcp(client.tcp_socket, &header, sizeof(header)) ||
            (prefix_size && !send_tcp(client.tcp_socket, prefix, prefix_size)) ||
            !send_tcp(client.tcp_socket, data, size)) {
            std::cerr << "[Server] Client " << client.id
                      << " media send failed, dropping connection\n";
            client.tcp_media = false;  // stop writing to a dead stream
            client.udp_addr_set = false;
            shutdown(client.tcp_socket, SHUTDOWN_BOTH);
        }
    }

    static void set_send_timeout(SocketType sock, int seconds) {
        set_timeout(sock, SO_SNDTIMEO, seconds);
    }

    /// 0 = block forever.
    static void set_recv_timeout(SocketType sock, int seconds) {
        set_timeout(sock, SO_RCVTIMEO, seconds);
    }

    static void set_timeout(SocketType sock, int option, int seconds) {
#ifdef _WIN32
        DWORD ms = static_cast<DWORD>(seconds) * 1000;
        setsockopt(sock, SOL_SOCKET, option,
                   reinterpret_cast<const char*>(&ms), sizeof(ms));
#else
        struct timeval tv{seconds, 0};
        setsockopt(sock, SOL_SOCKET, option, &tv, sizeof(tv));
#endif
    }

    /// Per-socket SIGPIPE suppression for platforms without MSG_NOSIGNAL
    /// (macOS/BSD). No-op elsewhere.
    static void suppress_sigpipe(SocketType sock) {
#if defined(SO_NOSIGPIPE)
        int on = 1;
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#else
        (void)sock;
#endif
    }

    /// A headset that powers off or drops off Wi-Fi never sends a FIN, so its
    /// handler thread sat in recv() forever: the ghost kept a --max-clients
    /// slot (after a few drops every reconnect was refused until the host was
    /// restarted) and, if it was streaming, kept the monitors busy. Keepalive
    /// probes a silent peer after 5 s and drops it ~6 s later.
    static void enable_keepalive(SocketType sock) {
        int on = 1;
        setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE,
                   reinterpret_cast<const char*>(&on), sizeof(on));
#if defined(TCP_KEEPIDLE) && defined(TCP_KEEPINTVL) && defined(TCP_KEEPCNT)
        // Linux, and Windows 10 1709+ (older Windows ignores these and keeps
        // its default 2 h idle, which is no worse than before).
        int idle = 5, interval = 2, count = 3;
        setsockopt(sock, IPPROTO_TCP, TCP_KEEPIDLE,
                   reinterpret_cast<const char*>(&idle), sizeof(idle));
        setsockopt(sock, IPPROTO_TCP, TCP_KEEPINTVL,
                   reinterpret_cast<const char*>(&interval), sizeof(interval));
        setsockopt(sock, IPPROTO_TCP, TCP_KEEPCNT,
                   reinterpret_cast<const char*>(&count), sizeof(count));
#elif defined(TCP_KEEPALIVE)  // macOS: idle time only
        int idle = 5;
        setsockopt(sock, IPPROTO_TCP, TCP_KEEPALIVE,
                   reinterpret_cast<const char*>(&idle), sizeof(idle));
#endif
    }

    ServerConfig config_;
    std::atomic<bool> running_{false};
    uint32_t next_client_id_ = 1;

    SocketType tcp_socket_ = INVALID_SOCK;
    SocketType udp_socket_ = INVALID_SOCK;
    SocketType discovery_socket_ = INVALID_SOCK;
    std::string host_name_;

    std::thread tcp_thread_;
    std::thread discovery_thread_;

    struct AuthState {
        int failures = 0;
        std::chrono::steady_clock::time_point locked_until{};
    };
    std::mutex auth_mutex_;
    std::unordered_map<uint32_t, AuthState> auth_failures_;  ///< by peer IPv4

    // Per-client handler threads, joined in stop(). finished_threads_ marks the
    // ones that have run to completion so the accept loop can reap them.
    std::mutex                    threads_mutex_;
    std::vector<std::thread>      client_threads_;
    std::set<std::thread::id>     finished_threads_;

    mutable std::mutex clients_mutex_;
    std::unordered_map<uint32_t, ClientState> clients_;

    ClientConnectedCallback      on_connected_;
    ClientDisconnectedCallback   on_disconnected_;
    MonitorSelectCallback        on_monitor_select_;
    MultiMonitorSelectCallback   on_multi_monitor_select_;
    StreamConfigCallback         on_stream_config_;
    InputMouseCallback           on_input_mouse_;
    InputKeyboardCallback        on_input_keyboard_;
    RequestKeyframeCallback      on_request_keyframe_;
    VirtualDisplayCreateCallback on_vdisplay_create_;
    VirtualDisplayRemoveCallback on_vdisplay_remove_;
    std::atomic<uint8_t>         monitor_count_{0};
};

std::unique_ptr<INetworkServer> create_network_server() {
    return std::make_unique<NetworkServer>();
}

std::string local_host_name() {
    char name[256] = {};
    if (gethostname(name, sizeof(name) - 1) != 0 || !name[0]) return "Immersive-2 host";
    return name;
}

std::string primary_ipv4() {
    // connect() on a UDP socket sends nothing; it only picks the route, and
    // getsockname() then reports the source address of that route.
    SocketType s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCK) return "";
    struct sockaddr_in to = {};
    to.sin_family = AF_INET;
    to.sin_port = htons(53);
    inet_pton(AF_INET, "192.0.2.1", &to.sin_addr);  // TEST-NET-1, never answered
    std::string ip;
    struct sockaddr_in me = {};
    socklen_t len = sizeof(me);
    if (connect(s, reinterpret_cast<struct sockaddr*>(&to), sizeof(to)) == 0 &&
        getsockname(s, reinterpret_cast<struct sockaddr*>(&me), &len) == 0) {
        char buf[INET_ADDRSTRLEN] = {};
        if (inet_ntop(AF_INET, &me.sin_addr, buf, sizeof(buf))) ip = buf;
    }
    closesocket(s);
    return ip == "0.0.0.0" ? "" : ip;
}

}  // namespace immersive
