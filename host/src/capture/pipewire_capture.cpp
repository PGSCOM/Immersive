/// Wayland capture: one xdg-desktop-portal ScreenCast stream per monitor
/// (portal_session.cpp), consumed with a PipeWire stream on its own
/// pw_thread_loop. Only shared-memory buffers are negotiated (no DMA-BUF),
/// so every frame is a plain mmap'd copy into the BGRA mailbox.
///
/// Virtual screens (ids 100+, GNOME only, mutter_virtual.cpp) are not portal
/// streams: their PipeWire consumer lives as long as the screen does, and a
/// capture of one just reads frames from it.

#include "capture/linux_backends.h"
#include "capture/mutter_virtual.h"
#include "capture/portal_session.h"
#include "protocol.h"

#include <pipewire/pipewire.h>
#include <spa/buffer/meta.h>
#include <spa/param/video/format-utils.h>
#include <spa/pod/builder.h>

#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <iostream>
#include <mutex>

namespace immersive {

namespace {

using namespace std::chrono_literals;

class PortalCapture final : public IScreenCapture {
public:
    PortalCapture() {
        static std::once_flag once;
        std::call_once(once, [] { pw_init(nullptr, nullptr); });
    }
    ~PortalCapture() override { stop_capture(); }

    /// A consumer of `node` on the default PipeWire daemon, asking for
    /// exactly `width` x `height` (a Mutter virtual monitor takes that size).
    bool connect_direct(uint32_t node, uint32_t width, uint32_t height) {
        fixed_w_ = width;
        fixed_h_ = height;
        return connect(0, node);
    }

    std::vector<DisplayInfo> enumerate_displays() override {
        const portal::Snapshot s = portal::ensure_session();
        const std::vector<DisplayInfo> virt = mutter::displays();
        std::vector<DisplayInfo> out;
        for (size_t i = 0; i < s.streams.size() && i < 255; ++i) {
            const portal::Stream& st = s.streams[i];
            DisplayInfo d{};
            d.id = static_cast<uint8_t>(i);
            // The portal always sends a size for monitor streams; if one ever
            // lacks it, main rescales whatever frames arrive to this guess.
            d.width  = static_cast<uint16_t>(st.width  > 0 ? std::min(st.width, 65535) : 1920);
            d.height = static_cast<uint16_t>(st.height > 0 ? std::min(st.height, 65535) : 1080);
            d.refresh_rate = 60;
            d.origin_x = st.x;
            d.origin_y = st.y;
            d.name = "Wayland Monitor " + std::to_string(i + 1);
            d.is_primary = (i == 0);
            d.native_id = st.node_id;
            out.push_back(d);
        }
        out.insert(out.end(), virt.begin(), virt.end());
        return out;
    }

    bool start_capture(uint8_t display_id) override {
        stop_capture();
        if (display_id >= protocol::VIRTUAL_MONITOR_ID_BASE) {
            if (!mutter::exists(display_id)) return false;
            virtual_id_ = display_id;
            return true;
        }
        const portal::Snapshot s = portal::ensure_session();
        if (s.generation == 0) return false;
        if (display_id >= s.streams.size()) {
            std::cerr << "[Capture] Monitor " << (int)display_id
                      << " is not shared in the current portal session\n";
            return false;
        }
        if (s.generation != fail_gen_) { fail_gen_ = s.generation; failures_ = 0; }

        if (connect(s.generation, s.streams[display_id].node_id)) {
            failures_ = 0;
            return true;
        }
        stop_capture();
        // A session whose nodes keep failing is dead even if the portal never
        // said so (e.g. its backend crashed): make the next attempt start over.
        if (++failures_ >= 3) {
            portal::invalidate(s.generation);
            failures_ = 0;
        }
        return false;
    }

    void stop_capture() override {
        virtual_id_ = 0;
        capturing_ = false;
        if (loop_) {
            pw_thread_loop_lock(loop_);
            if (stream_) {
                spa_hook_remove(&stream_listener_);
                pw_stream_disconnect(stream_);
                pw_stream_destroy(stream_);
                stream_ = nullptr;
            }
            if (core_) {
                spa_hook_remove(&core_listener_);
                pw_core_disconnect(core_);
                core_ = nullptr;
            }
            pw_thread_loop_unlock(loop_);
            pw_thread_loop_stop(loop_);
        }
        if (context_) { pw_context_destroy(context_); context_ = nullptr; }
        if (loop_)    { pw_thread_loop_destroy(loop_); loop_ = nullptr; }
        std::lock_guard<std::mutex> lock(mutex_);
        latest_.reset();
        streaming_ = false;
        failed_ = false;
    }

    std::unique_ptr<CapturedFrame> acquire_frame(uint32_t timeout_ms) override {
        if (virtual_id_) return mutter::acquire(virtual_id_, timeout_ms);
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                     [&] { return latest_ || failed_; });
        return std::move(latest_);
    }

    bool is_capturing() const override {
        if (virtual_id_) return mutter::exists(virtual_id_);
        return capturing_ && !failed_ && (gen_ == 0 || portal::live_generation() == gen_);
    }

private:
    /// gen 0: the default PipeWire daemon (a virtual screen), else the
    /// portal session's remote.
    bool connect(uint64_t gen, uint32_t node) {
        const int fd = gen ? portal::open_pipewire_remote(gen) : -1;
        if (gen && fd < 0) return false;

        node_ = node;
        loop_ = pw_thread_loop_new("im2-capture", nullptr);
        context_ = loop_ ? pw_context_new(pw_thread_loop_get_loop(loop_), nullptr, 0) : nullptr;
        if (!context_ || pw_thread_loop_start(loop_) < 0) {
            if (fd >= 0) close(fd);
            std::cerr << "[Capture] Cannot start a PipeWire loop\n";
            return false;
        }

        pw_thread_loop_lock(loop_);
        core_ = fd >= 0 ? pw_context_connect_fd(context_, fd, nullptr, 0)  // owns fd now
                        : pw_context_connect(context_, nullptr, 0);
        bool ok = core_ != nullptr;
        if (ok) {
            pw_core_add_listener(core_, &core_listener_, &kCoreEvents, this);
            stream_ = pw_stream_new(core_, "Immersive-2 capture", pw_properties_new(
                PW_KEY_MEDIA_TYPE, "Video",
                PW_KEY_MEDIA_CATEGORY, "Capture",
                PW_KEY_MEDIA_ROLE, "Screen",
                PW_KEY_NODE_DONT_RECONNECT, "true",
                "node.dont-fallback", "true",  // never another monitor instead
                nullptr));
            ok = stream_ != nullptr;
        }
        if (ok) {
            pw_stream_add_listener(stream_, &stream_listener_, &kStreamEvents, this);

            // Raw 32-bit formats only; no SPA_FORMAT_VIDEO_modifier, so the
            // compositor offers shared memory and never DMA-BUF.
            uint8_t buf[1024];
            spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof(buf));
            // A fixed size (min = max) for a virtual screen: the compositor
            // makes the monitor the size the consumer asks for.
            spa_rectangle size_def{fixed_w_ ? fixed_w_ : 1920, fixed_h_ ? fixed_h_ : 1080};
            spa_rectangle size_min{fixed_w_ ? fixed_w_ : 1, fixed_h_ ? fixed_h_ : 1};
            spa_rectangle size_max{fixed_w_ ? fixed_w_ : 16384, fixed_h_ ? fixed_h_ : 16384};
            spa_fraction rate_def{60, 1}, rate_min{0, 1}, rate_max{1000, 1};
            const spa_pod* params[1] = {static_cast<const spa_pod*>(spa_pod_builder_add_object(&b,
                SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
                SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
                SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
                SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(5,
                    SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRA,
                    SPA_VIDEO_FORMAT_RGBx, SPA_VIDEO_FORMAT_RGBA),
                SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&size_def, &size_min, &size_max),
                SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&rate_def, &rate_min, &rate_max)))};
            ok = pw_stream_connect(stream_, PW_DIRECTION_INPUT, node,
                                   static_cast<pw_stream_flags>(PW_STREAM_FLAG_AUTOCONNECT |
                                                                PW_STREAM_FLAG_MAP_BUFFERS |
                                                                PW_STREAM_FLAG_DONT_RECONNECT),
                                   params, 1) == 0;
        }
        pw_thread_loop_unlock(loop_);
        if (!ok) {
            std::cerr << "[Capture] Cannot connect to PipeWire node " << node << "\n";
            return false;
        }

        std::unique_lock<std::mutex> lock(mutex_);
        const bool started = cv_.wait_for(lock, 5s, [&] { return streaming_ || failed_; }) &&
                             !failed_;
        if (!started) {
            std::cerr << "[Capture] PipeWire node " << node << " did not start streaming\n";
            return false;
        }
        gen_ = gen;
        capturing_ = true;
        return true;
    }

    void fail() {
        std::lock_guard<std::mutex> lock(mutex_);
        failed_ = true;
        cv_.notify_all();
    }

    // ---- PipeWire callbacks (pw_thread_loop thread) --------------------------

    static void on_core_error(void* data, uint32_t id, int /*seq*/, int res, const char* message) {
        // Errors on the stream's own node also reach on_state_changed.
        if (id != PW_ID_CORE) return;
        auto* self = static_cast<PortalCapture*>(data);
        std::cerr << "[Capture] PipeWire connection error: " << (message ? message : "") << "\n";
        if (res == -EPIPE) self->fail();
    }

    static void on_state_changed(void* data, pw_stream_state /*old*/, pw_stream_state state,
                                 const char* error) {
        auto* self = static_cast<PortalCapture*>(data);
        if (state == PW_STREAM_STATE_ERROR || state == PW_STREAM_STATE_UNCONNECTED) {
            if (self->failed_) return;  // ERROR is followed by UNCONNECTED
            std::cerr << "[Capture] PipeWire stream for node " << self->node_ << " "
                      << (state == PW_STREAM_STATE_ERROR ? "failed: " : "ended (sharing stopped?)")
                      << (error ? error : "") << "\n";
            self->fail();
        } else if (state == PW_STREAM_STATE_STREAMING) {
            std::lock_guard<std::mutex> lock(self->mutex_);
            self->streaming_ = true;
            self->cv_.notify_all();
        }
    }

    static void on_param_changed(void* data, uint32_t id, const spa_pod* param) {
        auto* self = static_cast<PortalCapture*>(data);
        if (!param || id != SPA_PARAM_Format) return;
        uint32_t media_type = 0, media_subtype = 0;
        spa_video_info_raw info{};
        if (spa_format_parse(param, &media_type, &media_subtype) < 0 ||
            media_type != SPA_MEDIA_TYPE_video || media_subtype != SPA_MEDIA_SUBTYPE_raw ||
            spa_format_video_raw_parse(param, &info) < 0 ||
            info.size.width == 0 || info.size.height == 0) {
            return;
        }
        self->format_ = info.format;
        self->width_  = info.size.width;
        self->height_ = info.size.height;
        portal::set_frame_size(self->node_, info.size.width, info.size.height);
        std::cout << "[Capture] Wayland node " << self->node_ << ": " << info.size.width
                  << "x" << info.size.height << "\n";

        uint8_t buf[1024];
        spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof(buf));
        const spa_pod* params[3];
        params[0] = static_cast<const spa_pod*>(spa_pod_builder_add_object(&b,
            SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
            SPA_PARAM_BUFFERS_dataType,
            SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr))));
        params[1] = static_cast<const spa_pod*>(spa_pod_builder_add_object(&b,
            SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
            SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
            SPA_PARAM_META_size, SPA_POD_Int(sizeof(spa_meta_header))));
        params[2] = static_cast<const spa_pod*>(spa_pod_builder_add_object(&b,
            SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
            SPA_PARAM_META_type, SPA_POD_Id(SPA_META_VideoCrop),
            SPA_PARAM_META_size, SPA_POD_Int(sizeof(spa_meta_region))));
        pw_stream_update_params(self->stream_, params, 3);
    }

    static void on_process(void* data) {
        auto* self = static_cast<PortalCapture*>(data);
        // Keep only the newest buffer: we are a screen, not a recorder.
        pw_buffer* b = nullptr;
        while (pw_buffer* next = pw_stream_dequeue_buffer(self->stream_)) {
            if (b) pw_stream_queue_buffer(self->stream_, b);
            b = next;
        }
        if (!b) return;
        auto frame = self->convert(b->buffer);
        pw_stream_queue_buffer(self->stream_, b);
        if (!frame) return;
        std::lock_guard<std::mutex> lock(self->mutex_);
        self->latest_ = std::move(frame);
        self->cv_.notify_all();
    }

    std::unique_ptr<CapturedFrame> convert(const spa_buffer* buf) const {
        const auto* header = static_cast<const spa_meta_header*>(
            spa_buffer_find_meta_data(buf, SPA_META_Header, sizeof(spa_meta_header)));
        if (header && (header->flags & SPA_META_HEADER_FLAG_CORRUPTED)) return nullptr;
        if (buf->n_datas < 1 || width_ == 0) return nullptr;
        const spa_data& d = buf->datas[0];
        if ((d.type != SPA_DATA_MemFd && d.type != SPA_DATA_MemPtr) || !d.data || !d.chunk ||
            d.chunk->size == 0 || (d.chunk->flags & SPA_CHUNK_FLAG_CORRUPTED)) {
            return nullptr;  // e.g. a cursor-only update with no picture
        }

        uint32_t x0 = 0, y0 = 0, w = width_, h = height_;
        const auto* crop = static_cast<const spa_meta_region*>(
            spa_buffer_find_meta_data(buf, SPA_META_VideoCrop, sizeof(spa_meta_region)));
        if (crop && spa_meta_region_is_valid(crop) && crop->region.position.x >= 0 &&
            crop->region.position.y >= 0 &&
            crop->region.position.x + crop->region.size.width <= width_ &&
            crop->region.position.y + crop->region.size.height <= height_) {
            x0 = crop->region.position.x;
            y0 = crop->region.position.y;
            w  = crop->region.size.width;
            h  = crop->region.size.height;
        }

        const uint64_t stride = d.chunk->stride > 0 ? static_cast<uint64_t>(d.chunk->stride)
                                                    : uint64_t{width_} * 4;
        const uint64_t offset = d.maxsize ? d.chunk->offset % d.maxsize : 0;
        const uint64_t first = offset + y0 * stride + uint64_t{x0} * 4;
        if (stride < uint64_t{width_} * 4 || first + (h - 1) * stride + uint64_t{w} * 4 > d.maxsize)
            return nullptr;  // would read past the buffer

        auto frame = std::make_unique<CapturedFrame>();
        frame->width  = w;
        frame->height = h;
        frame->pitch  = w * 4;
        frame->timestamp_us = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
        frame->pixels.resize(size_t{frame->pitch} * h);
        const auto* src = static_cast<const uint8_t*>(d.data) + first;
        uint8_t* dst = frame->pixels.data();
        const bool swap_rb = format_ == SPA_VIDEO_FORMAT_RGBx || format_ == SPA_VIDEO_FORMAT_RGBA;
        for (uint32_t y = 0; y < h; ++y, src += stride, dst += frame->pitch) {
            if (!swap_rb) {
                std::memcpy(dst, src, frame->pitch);
                continue;
            }
            for (uint32_t x = 0; x < w * 4; x += 4) {
                dst[x] = src[x + 2];
                dst[x + 1] = src[x + 1];
                dst[x + 2] = src[x];
                dst[x + 3] = src[x + 3];
            }
        }
        return frame;
    }

    static inline const pw_core_events kCoreEvents = [] {
        pw_core_events e{};
        e.version = PW_VERSION_CORE_EVENTS;
        e.error = on_core_error;
        return e;
    }();
    static inline const pw_stream_events kStreamEvents = [] {
        pw_stream_events e{};
        e.version = PW_VERSION_STREAM_EVENTS;
        e.state_changed = on_state_changed;
        e.param_changed = on_param_changed;
        e.process = on_process;
        return e;
    }();

    pw_thread_loop* loop_ = nullptr;
    pw_context* context_ = nullptr;
    pw_core* core_ = nullptr;
    pw_stream* stream_ = nullptr;
    spa_hook core_listener_{};
    spa_hook stream_listener_{};

    // Written on the PipeWire thread before the first frame, read by convert().
    uint32_t node_ = 0;
    uint32_t format_ = SPA_VIDEO_FORMAT_UNKNOWN;
    uint32_t width_ = 0, height_ = 0;

    std::mutex mutex_;
    std::condition_variable cv_;
    std::unique_ptr<CapturedFrame> latest_;  // mailbox: newest frame only
    bool streaming_ = false;
    std::atomic<bool> failed_{false};
    std::atomic<bool> capturing_{false};
    uint64_t gen_ = 0;

    uint64_t fail_gen_ = 0;  // start_capture failure count for this session
    int failures_ = 0;

    uint8_t virtual_id_ = 0;              // capturing a virtual screen (reads its consumer)
    uint32_t fixed_w_ = 0, fixed_h_ = 0;  // connect_direct(): the size to ask for
};

}  // namespace

std::unique_ptr<IScreenCapture> create_portal_capture() {
    return std::make_unique<PortalCapture>();
}

std::unique_ptr<IScreenCapture> create_pipewire_node_capture(uint32_t node, uint32_t width,
                                                             uint32_t height) {
    auto cap = std::make_unique<PortalCapture>();
    if (!cap->connect_direct(node, width, height)) return nullptr;
    return cap;
}

}  // namespace immersive
