/// Network server implementation.
///
/// Manages TCP control channel for handshake/configuration/input
/// and UDP channel for video streaming.

#include "network/server.h"
#include "network/tls.h"

#include <algorithm>
#include <array>
#include <iostream>
#include <thread>
#include <atomic>
#include <mutex>
#include <unordered_map>
#include <set>
#include <vector>
#include <cstring>
#include <chrono>
#include <deque>
#include <map>
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
#include <fcntl.h>
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
    /// TCP media: frames sent and not yet acknowledged, per monitor.
    std::unordered_map<uint8_t, std::deque<uint32_t>> tcp_unacked;
    bool                authed = false;     ///< HELLO accepted (PIN checked); nothing else is served before
    /// TLS on the control socket (a client off this PC), and the key of its
    /// UDP video and audio (MEDIA_KEY); both null for a plain connection.
    std::shared_ptr<tls::Session>     tls;
    std::shared_ptr<tls::MediaCipher> cipher;
    /// HELLO_FLAG_WATCH: only gets the frames of the client that set the
    /// watch code (watch_owner_); sends nothing the host acts on but
    /// LATENCY_PROBE and PING (not even REQUEST_KEYFRAME: the owner's
    /// headset asks for those, and a lost frame waits for the next one).
    bool                watcher = false;
    std::string         name;
    struct FlowState {
        uint32_t first_frame = 0;  ///< this stream's first frame; older ACKs are the last stream's
        uint32_t last_sent = 0;
        uint32_t last_ack = 0;
        bool     ack_seen = false;
        std::chrono::steady_clock::time_point last_ack_time{}, last_log{};
        std::array<std::chrono::steady_clock::time_point, 128> sent_at{};  ///< by frame % 128
    };
    std::unordered_map<uint8_t, FlowState> flow_state;

    /// Adaptive bitrate for this client; all its monitors share one link.
    /// Fed by FRAME_ACK (the client acks every frame it completes): frames
    /// skipped over were lost; frames sent while one was in flight mean a
    /// queue filling up on the way; no ACK at all for a while is a stall.
    /// Each cuts the rate at once, a clean spell raises it slowly — the
    /// user's setting is the ceiling.
    struct RateControl {
        float    scale = 0.5f;  ///< share of the configured bitrate; starts at half
        uint32_t sent = 0, lost = 0;  ///< this window
        std::chrono::milliseconds worst_delay{0};  ///< this window: send -> ACK
        bool     stalled = false;                  ///< this window
        std::chrono::steady_clock::time_point window_start{}, last_cut{}, last_ack{};
    } rate;
};

class NetworkServer : public INetworkServer {
public:
    NetworkServer() = default;

    ~NetworkServer() override {
        stop();
    }

    /// Rate control (see ClientState::RateControl). A frame confirmed later
    /// than this after sending sat in a queue: Wi-Fi round trips are tens of
    /// ms, and the small VBV keeps any frame's own transfer near 50-100 ms.
    static constexpr std::chrono::milliseconds kMaxFrameDelay{250};
    static constexpr float kMinRateScale = 0.05f;

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
        pin_ = config.pin;
        host_flags_ = config.host_flags;

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
        no_inherit(tcp_socket_);

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
        no_inherit(udp_socket_);

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
        if (discovery_socket_ != INVALID_SOCK) no_inherit(discovery_socket_);
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
            if (client_id ? id != client_id : !client.authed || client.watcher) continue;
            if (!write_client(client, msg.data(), msg.size()))
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
            if (it != clients_.end()) {
                ClientState::FlowState fresh;
                fresh.first_frame = info.first_frame;
                it->second.flow_state[info.monitor_id] = fresh;
                // A restart pauses the ACKs (no frames, a new decoder): not a stall.
                if (it->second.rate.last_ack.time_since_epoch().count())
                    it->second.rate.last_ack = std::chrono::steady_clock::now();
            }
        }
        send_control_message(client_id, protocol::MessageType::STREAM_START, &info, sizeof(info));
    }

    void send_watch_start(uint32_t owner, const protocol::StreamStart& info) override {
        std::vector<uint32_t> to;
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            stream_starts_[{owner, info.monitor_id}] = info;  // for watchers joining later
            if (owner == watch_owner_) append_watchers_locked(to);
        }
        for (uint32_t id : to)
            send_control_message(id, protocol::MessageType::STREAM_START, &info, sizeof(info));
    }

    /// Every frame of the owner's capture loop asks: no lock (atomics).
    bool has_watchers(uint32_t owner) const override {
        return owner != 0 && owner == watch_owner_.load() && watcher_count_.load() > 0;
    }

    void send_watch_packet(uint32_t owner, uint8_t monitor_id, uint32_t frame_number,
                           const uint8_t* data, uint32_t size) override {
        std::vector<UdpDest> dests;
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            if (owner != watch_owner_) return;
            for (const auto& [id, c] : clients_)
                if (c.watcher && c.udp_addr_set) dests.push_back({c.udp_addr, c.cipher});
        }
        send_udp_frame(dests, monitor_id, frame_number, data, size);
    }

    void send_stream_stop(uint32_t client_id, uint8_t monitor_id) override {
        std::vector<uint32_t> to{client_id};
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            stream_starts_.erase({client_id, monitor_id});
            if (client_id == watch_owner_) append_watchers_locked(to);
        }
        const protocol::StreamStop msg{monitor_id};
        for (uint32_t id : to)
            send_control_message(id, protocol::MessageType::STREAM_STOP, &msg, sizeof(msg));
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
        // long enough to copy the destination out (none when the video goes
        // in-band on TCP).
        std::vector<UdpDest> dests;
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            auto it = clients_.find(client_id);
            if (it != clients_.end() && it->second.udp_addr_set &&
                send_to_client_locked(it->second, monitor_id, frame_number, data, size))
                dests.push_back({it->second.udp_addr, it->second.cipher});
        }
        send_udp_frame(dests, monitor_id, frame_number, data, size);
    }

    /// Where a UDP datagram goes, sealed with that client's key if it has one.
    struct UdpDest {
        struct sockaddr_in addr;
        std::shared_ptr<tls::MediaCipher> cipher;
    };

    /// One datagram to `dest`: as it is, or sealed (tls::MediaCipher).
    void send_datagram(const UdpDest& dest, const uint8_t* data, size_t len) {
        if (dest.cipher) {
            thread_local std::vector<uint8_t> sealed;
            sealed.resize(len + tls::MediaCipher::kOverhead);
            len = dest.cipher->seal(data, len, sealed.data());
            data = sealed.data();
        }
        sendto(udp_socket_, reinterpret_cast<const char*>(data), static_cast<int>(len), 0,
               reinterpret_cast<const struct sockaddr*>(&dest.addr), sizeof(dest.addr));
    }

    /// One frame as UDP chunks plus their FEC parity, to each of `dests`.
    void send_udp_frame(const std::vector<UdpDest>& dests, uint8_t monitor_id,
                        uint32_t frame_number, const uint8_t* data, uint32_t size) {
        if (dests.empty()) return;
        const uint16_t chunk_count = protocol::compute_chunk_count(size);

        // FEC (protocol.h, VideoParityHeader): Wi-Fi drops packets here and
        // there, and without it one lost chunk out of a frame's dozens cost
        // the whole frame and then an IDR. Parity j covers data chunks j,
        // j + p, j + 2p..., sent after them.
        // ponytail: XOR parity rebuilds one loss per group; Reed-Solomon
        // (Sunshine) rebuilds any p, worth it if the loss gets past ~2 %.
        const uint16_t parity_count = chunk_count == 0 ? 0 : static_cast<uint16_t>(std::min<uint32_t>(
            65535u - chunk_count,
            std::max<uint32_t>(1, (chunk_count * protocol::FEC_PERCENT + 99) / 100)));
        const uint32_t parity_len = std::min<uint32_t>(size, protocol::MAX_UDP_PAYLOAD);
        thread_local std::vector<uint8_t> parity;
        parity.assign(static_cast<size_t>(parity_count) * parity_len, 0);

        // One reusable packet buffer per sending thread (each monitor has its
        // own worker), instead of a heap allocation per chunk — ~150 malloc/free
        // pairs per frame, per monitor, at up to 60 fps.
        thread_local std::vector<uint8_t> packet;
        packet.resize(sizeof(protocol::VideoPacketHeader) + sizeof(protocol::VideoParityHeader) +
                      protocol::MAX_UDP_PAYLOAD);

        protocol::VideoPacketHeader vph;
        vph.monitor_id   = monitor_id;
        vph.frame_number = frame_number;
        vph.chunk_count  = chunk_count;

        auto send_packet = [&](size_t len) {
            for (const auto& dest : dests) send_datagram(dest, packet.data(), len);
        };

        for (uint16_t i = 0; i < chunk_count; ++i) {
            const uint32_t offset = static_cast<uint32_t>(i) * protocol::MAX_UDP_PAYLOAD;
            const uint32_t chunk_size = std::min(
                static_cast<uint32_t>(protocol::MAX_UDP_PAYLOAD),
                size - offset);

            vph.chunk_index = i;
            std::memcpy(packet.data(), &vph, sizeof(vph));
            std::memcpy(packet.data() + sizeof(vph), data + offset, chunk_size);
            send_packet(sizeof(vph) + chunk_size);

            if (parity_count) {
                uint8_t* p = parity.data() + static_cast<size_t>(i % parity_count) * parity_len;
                for (uint32_t b = 0; b < chunk_size; ++b) p[b] ^= data[offset + b];
            }
        }

        const protocol::VideoParityHeader ph{size, parity_count};
        for (uint16_t j = 0; j < parity_count; ++j) {
            vph.chunk_index = static_cast<uint16_t>(chunk_count + j);
            uint8_t* out = packet.data();
            std::memcpy(out, &vph, sizeof(vph));
            std::memcpy(out + sizeof(vph), &ph, sizeof(ph));
            std::memcpy(out + sizeof(vph) + sizeof(ph),
                        parity.data() + static_cast<size_t>(j) * parity_len, parity_len);
            send_packet(sizeof(vph) + sizeof(ph) + parity_len);
        }
    }

    /// The flow bookkeeping of one frame for its client and, in TCP media
    /// mode, the frame itself (or nothing, if its queue is too old). Returns
    /// whether the frame still has to go out to it over UDP. Caller holds
    /// clients_mutex_.
    bool send_to_client_locked(ClientState& client, uint8_t monitor_id, uint32_t frame_number,
                               const uint8_t* data, uint32_t size) {
        auto& flow = client.flow_state[monitor_id];
        if (frame_number == 0 || (flow.ack_seen && frame_number < flow.last_ack)) {
            flow.ack_seen = false;
            flow.last_ack = frame_number;
        }
        // A client falling behind is never a reason to stop sending:
        // catching up needs the newest frames, and refusing them froze the
        // stream for good (the client could never ACK again). The rate
        // control sends less instead.
        const auto now = std::chrono::steady_clock::now();
        flow.last_sent = frame_number;
        flow.sent_at[frame_number % flow.sent_at.size()] = now;
        rate_on_sent(client, now);
        if (!client.tcp_media) return true;

        // TCP never loses a frame, it queues it (in adb, the kernels, the
        // headset), and a queue is latency. The client ACKs each frame as it
        // reads it: once the oldest unacknowledged one has waited
        // kMaxTcpQueue, drop whole frames until it catches up. It sees the
        // gap in frame numbers and asks for a keyframe. By age, not count: 4
        // frames (66 ms at 60 fps) already tripped at stream start, and a
        // sharp IDR (up to 1 MB, ~40 ms on the cable) must not make the
        // frames behind it a gap and so another IDR. (A client that never
        // ACKs, or has not yet on this stream, is not limited.)
        constexpr auto kMaxTcpQueue = std::chrono::milliseconds(150);
        auto& unacked = client.tcp_unacked[monitor_id];
        if (!flow.ack_seen) unacked.clear();
        while (!unacked.empty() && unacked.front() <= flow.last_ack) unacked.pop_front();
        if (!unacked.empty() &&
            now - flow.sent_at[unacked.front() % flow.sent_at.size()] > kMaxTcpQueue) {
            if (now - flow.last_log > std::chrono::seconds(2)) {
                std::cout << "[Server] Client " << client.id << " monitor "
                          << static_cast<int>(monitor_id) << ": " << unacked.size()
                          << " frames unacknowledged on TCP for over "
                          << kMaxTcpQueue.count() << " ms, dropping frames\n";
                flow.last_log = now;
            }
            return false;
        }
        // ponytail: the whole frame is written under clients_mutex_,
        // serialising every monitor (they share this one socket anyway).
        // SO_SNDTIMEO bounds the hold; a per-client send lock if it shows.
        protocol::VideoFrameHeader vfh{monitor_id, frame_number};
        send_media_locked(client, protocol::MessageType::VIDEO_FRAME,
                          &vfh, sizeof(vfh), data, size);
        unacked.push_back(frame_number);
        return false;
    }

    /// Caller holds clients_mutex_: append the ids of every watcher.
    void append_watchers_locked(std::vector<uint32_t>& ids) const {
        for (const auto& [id, c] : clients_)
            if (c.watcher) ids.push_back(id);
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

        if (!write_client(it->second, &header, sizeof(header)) ||
            (payload_size > 0 && payload &&
             !write_client(it->second, payload, payload_size))) {
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
            // No audio before the PIN is checked, nor to watchers: theirs is
            // another PC's sound, and this would land in their own PC's.
            if (!client.authed || client.watcher) continue;
            if (client.tcp_media) {
                send_media_locked(client, protocol::MessageType::AUDIO_DATA,
                                  nullptr, 0, data, size);
                continue;
            }
            if (!client.udp_addr_set) continue;
            UdpDest dest{client.udp_addr, client.cipher};
            dest.addr.sin_port = htons(port);
            send_datagram(dest, data, size);
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

    void set_on_pin_requested(PinRequestedCallback cb) override {
        on_pin_requested_ = std::move(cb);
    }
    void set_on_screen_off(ScreenOffCallback cb) override {
        on_screen_off_ = std::move(cb);
    }

    void set_on_virtual_display_remove(VirtualDisplayRemoveCallback cb) override {
        on_vdisplay_remove_ = std::move(cb);
    }

    void set_pin(uint32_t pin) override { pin_ = pin; }

    void set_host_flags(uint8_t flags) override {
        if (host_flags_.exchange(flags) == flags) return;
        const protocol::HelloAck ack = make_ack();
        std::lock_guard<std::mutex> lock(clients_mutex_);
        for (auto& [id, client] : clients_) {
            if (!client.authed) continue;
            protocol::ControlHeader header{static_cast<uint8_t>(protocol::MessageType::HELLO_ACK),
                                           static_cast<uint32_t>(sizeof(ack))};
            if (!write_client(client, &header, sizeof(header)) ||
                !write_client(client, &ack, sizeof(ack)))
                shutdown(client.tcp_socket, SHUTDOWN_BOTH);
        }
    }

    std::vector<ClientInfo> clients() const override {
        std::vector<ClientInfo> out;
        std::lock_guard<std::mutex> lock(clients_mutex_);
        for (const auto& [id, c] : clients_) {
            if (!c.authed) continue;
            char ip[INET_ADDRSTRLEN] = {};
            inet_ntop(AF_INET, &c.udp_addr.sin_addr, ip, sizeof(ip));
            out.push_back({id, c.name, ip, c.tcp_media, c.watcher});
        }
        std::sort(out.begin(), out.end(), [](const auto& a, const auto& b) { return a.id < b.id; });
        return out;
    }

    void disconnect_client(uint32_t client_id) override {
        std::lock_guard<std::mutex> lock(clients_mutex_);
        auto it = clients_.find(client_id);
        if (it == clients_.end()) return;
        {
            std::lock_guard<std::mutex> auth(auth_mutex_);
            kicked_.insert(it->second.udp_addr.sin_addr.s_addr);
        }
        std::cout << "[Server] Client " << client_id << " disconnected from the settings panel\n";
        shutdown(it->second.tcp_socket, SHUTDOWN_BOTH);
    }

    float link_rate_scale(uint32_t client_id) const override {
        std::lock_guard<std::mutex> lock(clients_mutex_);
        auto it = clients_.find(client_id);
        return it == clients_.end() ? 1.0f : it->second.rate.scale;
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
                    send_reject(client_sock, nullptr, protocol::REJECT_SERVER_FULL);
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

            no_inherit(client_sock);
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
        bool watcher = false;
        bool rejected = false;
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            auto it = clients_.find(client_id);
            if (it == clients_.end()) return;
            sock = it->second.tcp_socket;
            peer = it->second.udp_addr.sin_addr;
        }
        // From this PC (127/8, the USB cable's `adb reverse` too) nothing
        // crosses a network: plain TCP is fine there.
        const bool local = (ntohl(peer.s_addr) >> 24) == 127;

        // A TLS ClientHello starts with a handshake record (0x16); a plain
        // client's first byte is HELLO (0x01).
        std::shared_ptr<tls::Session> tls;
        bool ok = true;
        {
            char first = 0;
            if (recv(sock, &first, 1, MSG_PEEK) == 1 && static_cast<uint8_t>(first) == 0x16) {
                std::string error;
                if (config_.identity)
                    tls = tls::Session::accept(*config_.identity, static_cast<std::uintptr_t>(sock),
                                               kHelloTimeoutS, &error);
                else
                    error = "this host has no TLS identity";
                if (tls) {
                    std::lock_guard<std::mutex> lock(clients_mutex_);
                    auto it = clients_.find(client_id);
                    if (it != clients_.end()) {
                        it->second.tls = tls;
                        it->second.cipher = std::make_shared<tls::MediaCipher>();
                    }
                } else {
                    std::cerr << "[Server] Client " << client_id << " TLS handshake failed: " << error << "\n";
                    ok = false;
                }
            }
        }

        while (ok && running_) {
            protocol::ControlHeader header;
            if (!read_exact(sock, tls.get(), &header, sizeof(header))) break;

            if (header.length > kMaxControlPayload) {
                std::cerr << "[Server] Client " << client_id
                          << " sent an oversized control message ("
                          << header.length << " bytes), dropping connection\n";
                break;
            }

            // Read payload
            std::vector<uint8_t> payload(header.length);
            if (header.length > 0) {
                if (!read_exact(sock, tls.get(), payload.data(), header.length)) break;
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
            if (watcher && msg_type != protocol::MessageType::LATENCY_PROBE &&
                msg_type != protocol::MessageType::PING) continue;  // a watcher only watches
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
                              << (tcp_media ? " (video/audio over TCP)" : "")
                              << (tls ? " (encrypted)" : "") << "\n";

                    // Off this PC, the PIN, the input and the screens only
                    // go encrypted (unless --allow-plaintext, for old headsets).
                    if (!tls && !local && !config_.allow_plaintext) {
                        std::cerr << "[Server] Client " << client_id
                                  << " refused: not encrypted (an old version of the app?)\n";
                        send_reject(sock, nullptr, protocol::REJECT_ENCRYPTION_REQUIRED);
                        rejected = true;
                        break;
                    }
                    // Who we are, before the PIN: the headset pins it, and
                    // shows its fingerprint next to the PIN prompt.
                    if (config_.identity && (tls || (hello.flags & protocol::HELLO_FLAG_IDENTITY))) {
                        const std::string& pem = config_.identity->cert_pem();
                        send_control_message(client_id, protocol::MessageType::IDENTITY, pem.data(), pem.size());
                    }

                    bool kicked;  // disconnected from the panel: ask for the PIN once
                    {
                        std::lock_guard<std::mutex> lock(auth_mutex_);
                        kicked = kicked_.erase(peer.s_addr) > 0;
                    }
                    if (hello.flags & protocol::HELLO_FLAG_WATCH) {
                        watcher = !kicked && accept_watcher(client_id, sock, tls.get(), peer, hello);
                        if (kicked) send_reject(sock, tls.get(), protocol::REJECT_PIN_REQUIRED);
                        authed = watcher;
                        rejected = !watcher;
                        break;
                    }
                    const uint8_t reject = kicked ? protocol::REJECT_PIN_REQUIRED
                                                  : check_pin(peer, hello.pin);
                    if (reject) {
                        std::cerr << "[Server] Client " << client_id << " refused: "
                                  << (kicked ? "disconnected from the settings panel, asking for the PIN"
                                      : reject == protocol::REJECT_PIN_REQUIRED ? "no PIN"
                                      : reject == protocol::REJECT_WRONG_PIN ? "wrong PIN"
                                      : "too many wrong PINs, locked out for a minute")
                                  << " (the PIN is shown in this window)\n";
                        send_reject(sock, tls.get(), reject);
                        if (reject != protocol::REJECT_LOCKED_OUT && !kicked && on_pin_requested_)
                            on_pin_requested_(inet_ntoa(peer));
                        rejected = true;
                        break;
                    }
                    {
                        std::lock_guard<std::mutex> lock(clients_mutex_);
                        uint32_t paired = 0;  // watchers come on top
                        for (const auto& [id, c] : clients_) paired += c.authed && !c.watcher ? 1 : 0;
                        if (paired >= config_.max_clients) {
                            std::cerr << "[Server] Client " << client_id
                                      << " refused: client limit (" << config_.max_clients
                                      << ") reached\n";
                            send_reject(sock, tls.get(), protocol::REJECT_SERVER_FULL);
                            rejected = true;
                            break;
                        }
                        auto it = clients_.find(client_id);
                        if (it != clients_.end()) {
                            it->second.authed = true;
                            it->second.name.assign(hello.client_name,
                                                   strnlen(hello.client_name, sizeof(hello.client_name)));
                        }
                    }
                    authed = true;
                    set_recv_timeout(sock, 0);  // paired: idle is fine now (keepalive covers dead peers)
                    if (tls) tls->set_timeout(0);
                    if (tcp_media) {
                        // A client that stops reading must not wedge the
                        // sender (and clients_mutex_) forever: a timed-out
                        // send drops the connection instead.
                        set_send_timeout(sock, 3);
                        // Each frame goes out at once (no Nagle wait for its
                        // tail), into a bounded kernel queue.
                        int on = 1, sndbuf = 1 << 20;
                        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY,
                                   reinterpret_cast<const char*>(&on), sizeof(on));
                        setsockopt(sock, SOL_SOCKET, SO_SNDBUF,
                                   reinterpret_cast<const char*>(&sndbuf), sizeof(sndbuf));
                        std::lock_guard<std::mutex> lock(clients_mutex_);
                        auto it = clients_.find(client_id);
                        // The cable loses nothing and carries far more than
                        // Wi-Fi: the full bitrate at once, not half of it for
                        // the first ~20 s. A queue still cuts it.
                        if (it != clients_.end()) {
                            it->second.tcp_media = true;
                            it->second.rate.scale = 1.0f;
                        }
                    }

                    if (tls && !tcp_media) send_media_key(client_id);
                    const protocol::HelloAck ack = make_ack();
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
                // The client completed a frame. Frame numbers only count sent
                // frames, so the ones skipped over were lost on the way —
                // unless this monitor's last ACK is old: then it was idle (one
                // frame a second) or the link stalled, which is reported
                // already; counted again, the recovery would read as loss.
                // Its send-to-ACK delay is the queue in front of it.
                if (payload.size() >= sizeof(protocol::FrameAck)) {
                    protocol::FrameAck ack;
                    std::memcpy(&ack, payload.data(), sizeof(ack));
                    const auto now = std::chrono::steady_clock::now();
                    std::lock_guard<std::mutex> lock(clients_mutex_);
                    auto it = clients_.find(client_id);
                    if (it != clients_.end()) {
                        auto& flow = it->second.flow_state[ack.monitor_id];
                        auto& rate = it->second.rate;
                        if (ack.frame_number < flow.first_frame) break;  // the previous stream's
                        if (flow.ack_seen && ack.frame_number > flow.last_ack + 1 &&
                            now - flow.last_ack_time < std::chrono::seconds(1)) {
                            rate.lost += ack.frame_number - flow.last_ack - 1;
                        }
                        if (flow.last_sent - ack.frame_number < flow.sent_at.size()) {
                            const auto delay = std::chrono::duration_cast<std::chrono::milliseconds>(
                                now - flow.sent_at[ack.frame_number % flow.sent_at.size()]);
                            rate.worst_delay = std::max(rate.worst_delay, delay);
                            if (delay > kMaxFrameDelay && now - flow.last_log > std::chrono::seconds(2)) {
                                std::cout << "[Server] Client " << client_id << " monitor "
                                          << static_cast<int>(ack.monitor_id) << " lagging ("
                                          << delay.count() << " ms from send to ACK)\n";
                                flow.last_log = now;
                            }
                        }
                        flow.last_ack = flow.ack_seen ? std::max(flow.last_ack, ack.frame_number)
                                                      : ack.frame_number;
                        flow.ack_seen = true;
                        flow.last_ack_time = rate.last_ack = now;
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
            case protocol::MessageType::WATCH_CODE: {
                if (payload.size() >= sizeof(protocol::WatchCode)) {
                    protocol::WatchCode wc;
                    std::memcpy(&wc, payload.data(), sizeof(wc));
                    set_watch_code(client_id, wc.code);
                }
                break;
            }
            case protocol::MessageType::SCREEN_OFF: {
                if (payload.size() >= sizeof(protocol::ScreenOff) && on_screen_off_) {
                    on_screen_off_(client_id, payload[0] != 0);
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
                if (it->second.watcher) --watcher_count_;
                closesocket(it->second.tcp_socket);
                clients_.erase(it);
            }
            for (auto s = stream_starts_.begin(); s != stream_starts_.end();)
                s = s->first.first == client_id ? stream_starts_.erase(s) : std::next(s);
            if (client_id == watch_owner_) {
                std::cout << "[Server] Client " << client_id << " left: its watchers go too\n";
                drop_watchers_locked();
                watch_code_ = watch_owner_ = 0;
            }
        }

        std::cout << "[Server] Client " << client_id << " disconnected\n";
        if (on_disconnected_) on_disconnected_(client_id);
    }

    /// One sent frame for the client's rate control; once a second decide.
    /// Caller holds clients_mutex_.
    /// ponytail: fixed thresholds, no delay-gradient estimator; a queue shows
    /// once it is kMaxFrameDelay deep.
    void rate_on_sent(ClientState& client, std::chrono::steady_clock::time_point now) {
        using namespace std::chrono_literals;
        auto& r = client.rate;
        if (r.window_start.time_since_epoch().count() == 0) r.window_start = r.last_cut = now;
        ++r.sent;
        // Sending, and no ACK for 1.5 s (an idle screen still sends one
        // frame a second): the link or the client has stalled. Clients that
        // never ACK (older ones, the web bridge) are left alone.
        if (r.last_ack.time_since_epoch().count() && now - r.last_ack > 1500ms) r.stalled = true;
        if (now - r.window_start < 1s) return;

        // More than 1 frame in 20 lost costs an IDR request each, and each
        // frame is more UDP chunks that can go missing the higher the rate.
        const bool lossy = r.lost >= 2 && r.lost * 20 > r.sent;
        const bool queued = r.stalled || r.worst_delay > kMaxFrameDelay;
        if ((lossy || queued) && now - r.last_cut >= 1s) {
            r.scale = std::max(kMinRateScale, r.scale * 0.7f);
            r.last_cut = now;
            std::cout << "[Server] Client " << client.id << " link congested ("
                      << r.lost << "/" << r.sent << " frames lost, "
                      << (r.stalled ? std::string("no ACKs")
                                    : std::to_string(r.worst_delay.count()) + " ms to ACK")
                      << "): video bitrate down to "
                      << static_cast<int>(r.scale * 100 + 0.5f) << "%\n";
        } else if (!lossy && !queued && r.sent >= 5 && r.scale < 1.0f && now - r.last_cut >= 4s) {
            r.scale = std::min(1.0f, r.scale * 1.1f + 0.02f);  // floor to full: ~20 s
            if (r.scale == 1.0f)
                std::cout << "[Server] Client " << client.id << " link clean: full video bitrate\n";
        }
        r.window_start = now;
        r.sent = r.lost = 0;
        r.worst_delay = 0ms;
        r.stalled = false;
    }

    /// 0 when a HELLO carrying `pin` from `peer` may proceed, else the
    /// REJECT_* reason. 127.0.0.1 is trusted: it is a process on this PC or a
    /// headset on the USB cable (`adb reverse`, which the headset authorised).
    /// Five wrong PINs from one address lock it out for a minute, and every
    /// wrong answer costs half a second, so the 900 000 PINs can't be walked.
    uint8_t check_pin(struct in_addr peer, uint32_t pin) {
        const uint32_t want = pin_;
        if (want == 0 || peer.s_addr == htonl(INADDR_LOOPBACK)) return 0;
        return check_code(peer, pin, want);
    }

    /// check_pin() without the exceptions: `pin` must be `want`, from any
    /// address, with the same cost and lock-out for wrong ones.
    uint8_t check_code(struct in_addr peer, uint32_t pin, uint32_t want) {
        const auto now = std::chrono::steady_clock::now();
        auto delay = std::chrono::milliseconds(500);
        {
            std::lock_guard<std::mutex> lock(auth_mutex_);
            auto& st = auth_failures_[peer.s_addr];
            if (now < st.locked_until) return protocol::REJECT_LOCKED_OUT;
            if (pin == want) { st.failures = 0; return 0; }
            if (pin == 0) return protocol::REJECT_PIN_REQUIRED;
            if (++st.failures >= 5) {
                st.failures = 0;
                st.locked_until = now + std::chrono::seconds(60);
            }
            // Many addresses guessing at once (one per address stays under
            // the lockout): past kGlobalFailures in a minute, every wrong
            // code is slow. Slow, not locked: a lockout for everyone would
            // let anyone keep the real headset out.
            while (!recent_failures_.empty() && now - recent_failures_.front() > std::chrono::seconds(60))
                recent_failures_.pop_front();
            if (recent_failures_.size() < 4 * kGlobalFailures) recent_failures_.push_back(now);
            if (recent_failures_.size() >= kGlobalFailures) {
                delay = std::chrono::seconds(5);
                if (now >= next_guess_warning_) {
                    next_guess_warning_ = now + std::chrono::minutes(10);
                    std::cerr << "[Server] Over " << kGlobalFailures
                              << " wrong PINs in a minute from this network: someone may be guessing it."
                                 " Each wrong one now takes 5 s. Make a new PIN in the settings if in doubt\n";
                }
            }
        }
        std::this_thread::sleep_for(delay);
        return protocol::REJECT_WRONG_PIN;
    }

    protocol::HelloAck make_ack() const {
        protocol::HelloAck ack{};
        ack.protocol_version = protocol::PROTOCOL_VERSION;
        ack.udp_port = config_.udp_port;
        ack.monitor_count = monitor_count_;
        ack.flags = host_flags_;
        std::strncpy(ack.host_name, host_name_.c_str(), sizeof(ack.host_name) - 1);
        inet_pton(AF_INET, primary_ipv4().c_str(), &ack.lan_ipv4);  // stays 0 when unknown
        return ack;
    }

    /// HELLO_FLAG_WATCH: let the headset in if it shows the current watch
    /// code, then announce the owner's watch streams to it (their next frame
    /// comes with the owner's next one, within a second even on a still
    /// screen). False when refused (it was told).
    bool accept_watcher(uint32_t client_id, SocketType sock, tls::Session* tls, struct in_addr peer,
                        const protocol::Hello& hello) {
        uint32_t want;
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            want = watch_code_;
        }
        uint8_t reject = want ? check_code(peer, hello.pin, want) : protocol::REJECT_PIN_REQUIRED;
        std::vector<protocol::StreamStart> starts;
        uint32_t owner = 0;
        if (!reject) {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            auto it = clients_.find(client_id);
            if (it == clients_.end() || watch_code_ != hello.pin) {
                reject = protocol::REJECT_WRONG_PIN;  // the code changed meanwhile
            } else {
                it->second.authed = it->second.watcher = true;
                ++watcher_count_;
                it->second.name.assign(hello.client_name,
                                       strnlen(hello.client_name, sizeof(hello.client_name)));
                it->second.udp_addr.sin_port = htons(hello.udp_port ? hello.udp_port : config_.udp_port);
                owner = watch_owner_;
                for (const auto& [key, s] : stream_starts_)
                    if (key.first == owner) starts.push_back(s);
            }
        }
        if (reject) {
            std::cerr << "[Server] Client " << client_id << " refused: "
                      << (!want ? "it asked to watch, but nobody shares this PC's screens"
                          : reject == protocol::REJECT_LOCKED_OUT ? "too many wrong watch codes"
                          : "wrong watch code") << "\n";
            send_reject(sock, tls, reject);
            return false;
        }
        set_recv_timeout(sock, 0);
        if (tls) {
            tls->set_timeout(0);
            send_media_key(client_id);
        }
        protocol::HelloAck ack = make_ack();
        ack.flags |= protocol::HOST_FLAG_VIEW_ONLY;
        send_control_message(client_id, protocol::MessageType::HELLO_ACK, &ack, sizeof(ack));
        for (const auto& s : starts)
            send_control_message(client_id, protocol::MessageType::STREAM_START, &s, sizeof(s));
        std::cout << "[Server] Client " << client_id << " watches client " << owner
                  << "'s screens (" << starts.size() << " streaming)\n";
        return true;
    }

    /// WATCH_CODE from `owner`: headsets showing `code` may watch its screens
    /// (0: nobody). Another code drops the watchers of the old one; only the
    /// client that set a code can take it back.
    void set_watch_code(uint32_t owner, uint32_t code) {
        std::lock_guard<std::mutex> lock(clients_mutex_);
        if (code == 0 ? owner != watch_owner_ : code == watch_code_ && owner == watch_owner_) return;
        drop_watchers_locked();
        watch_code_ = code;
        watch_owner_ = code ? owner : 0;
        std::cout << "[Server] Client " << owner << (code ? " shares its screens with its room\n"
                                                           : " stopped sharing its screens\n");
    }

    /// Caller holds clients_mutex_. Their handler threads clean up.
    void drop_watchers_locked() {
        for (auto& [id, c] : clients_)
            if (c.watcher) shutdown(c.tcp_socket, SHUTDOWN_BOTH);
    }

    /// Write one HELLO_REJECT straight to a socket, or its TLS session (no
    /// client entry needed).
    static void send_reject(SocketType sock, tls::Session* tls, uint8_t reason) {
        protocol::ControlHeader header{static_cast<uint8_t>(protocol::MessageType::HELLO_REJECT), 1};
        uint8_t msg[sizeof(header) + 1];
        std::memcpy(msg, &header, sizeof(header));
        msg[sizeof(header)] = reason;
        if (tls) tls->write(msg, sizeof(msg));
        else send_tcp(sock, msg, sizeof(msg));
    }

    /// MEDIA_KEY: the key this client's UDP video and audio are sealed with.
    void send_media_key(uint32_t client_id) {
        std::shared_ptr<tls::MediaCipher> cipher;
        {
            std::lock_guard<std::mutex> lock(clients_mutex_);
            auto it = clients_.find(client_id);
            if (it != clients_.end()) cipher = it->second.cipher;
        }
        if (cipher)
            send_control_message(client_id, protocol::MessageType::MEDIA_KEY, cipher->key(),
                                 tls::MediaCipher::kKeySize);
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
            reply.flags            = (pin_ ? protocol::DISCOVERY_FLAG_PIN : 0) |
                                     ((host_flags_ & protocol::HOST_FLAG_VIEW_ONLY)
                                          ? protocol::DISCOVERY_FLAG_VIEW_ONLY : 0);
            std::strncpy(reply.host_name, host_name_.c_str(), sizeof(reply.host_name) - 1);
            sendto(discovery_socket_, reinterpret_cast<const char*>(&reply), sizeof(reply), 0,
                   reinterpret_cast<struct sockaddr*>(&from), from_len);
        }
    }

    /// Receive exactly `size` bytes from a client: through its TLS session,
    /// or straight from the socket. False on error or disconnect.
    static bool read_exact(SocketType sock, tls::Session* tls, void* buf, size_t size) {
        if (!tls) return recv_exact(sock, buf, size);
        char* ptr = reinterpret_cast<char*>(buf);
        while (size > 0) {
            const int n = tls->read(ptr, size);
            if (n <= 0) return false;
            ptr += n;
            size -= static_cast<size_t>(n);
        }
        return true;
    }

    /// Write to a client: through its TLS session, or straight to the socket.
    static bool write_client(ClientState& client, const void* data, size_t size) {
        return client.tls ? client.tls->write(data, size) : send_tcp(client.tcp_socket, data, size);
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
        if (!write_client(client, &header, sizeof(header)) ||
            (prefix_size && !write_client(client, prefix, prefix_size)) ||
            !write_client(client, data, size)) {
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

    /// Keep a socket out of child processes: an adb daemon that
    /// `adb devices` starts (usb/adb_reverse.cpp) would otherwise hold the
    /// port open after the host exits.
    static void no_inherit(SocketType sock) {
#ifdef _WIN32
        SetHandleInformation(reinterpret_cast<HANDLE>(sock), HANDLE_FLAG_INHERIT, 0);
#else
        fcntl(sock, F_SETFD, FD_CLOEXEC);
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
    std::set<uint32_t> kicked_;  ///< peers disconnected from the panel (auth_mutex_)
    /// Wrong codes from every address in the last minute (auth_mutex_).
    static constexpr size_t kGlobalFailures = 20;
    std::deque<std::chrono::steady_clock::time_point> recent_failures_;
    std::chrono::steady_clock::time_point next_guess_warning_{};
    std::atomic<uint32_t> pin_{0};
    std::atomic<uint8_t>  host_flags_{0};

    // Watching (protocol::WatchCode), all written under clients_mutex_: the
    // code, the client whose screens watchers get, how many watchers there
    // are (the last two atomic: has_watchers() reads them every frame without
    // the lock), and the last watch STREAM_START of each (owner, monitor) for
    // watchers that join later.
    uint32_t watch_code_ = 0;
    std::atomic<uint32_t> watch_owner_{0};
    std::atomic<int> watcher_count_{0};
    std::map<std::pair<uint32_t, uint8_t>, protocol::StreamStart> stream_starts_;

    // Per-client handler threads, joined in stop(). finished_threads_ marks the
    // ones that have run to completion so the accept loop can reap them.
    std::mutex                    threads_mutex_;
    std::vector<std::thread>      client_threads_;
    std::set<std::thread::id>     finished_threads_;

    mutable std::mutex clients_mutex_;
    std::unordered_map<uint32_t, ClientState> clients_;

    ClientConnectedCallback      on_connected_;
    ClientDisconnectedCallback   on_disconnected_;
    ScreenOffCallback            on_screen_off_;
    MonitorSelectCallback        on_monitor_select_;
    MultiMonitorSelectCallback   on_multi_monitor_select_;
    StreamConfigCallback         on_stream_config_;
    InputMouseCallback           on_input_mouse_;
    InputKeyboardCallback        on_input_keyboard_;
    RequestKeyframeCallback      on_request_keyframe_;
    VirtualDisplayCreateCallback on_vdisplay_create_;
    VirtualDisplayRemoveCallback on_vdisplay_remove_;
    PinRequestedCallback on_pin_requested_;
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
