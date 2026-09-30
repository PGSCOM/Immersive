/// Linux H.264 / HEVC / AV1 encoder on FFmpeg's libavcodec.
///
/// Tries, in order: NVENC (NVIDIA), VAAPI (Intel / AMD), then libx264 for
/// H.264 only (software, but fine on any recent laptop CPU at 1080p60 with
/// the zero-latency tune). Every backend is configured the way a VR desktop
/// streamer needs it (see the contract in encoder.h): no B-frames, no
/// lookahead, one packet per frame, small VBV, parameter sets on every IDR.
///
/// Input BGRA of any size is scaled and converted to NV12 in one libswscale
/// pass (SIMD), so main.cpp never runs its scalar CPU downscaler for us.

#include "encoder/encoder.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
}

#include <algorithm>
#include <chrono>
#include <cstring>
#include <iostream>
#include <map>
#include <mutex>
#include <string>

namespace immersive {

namespace {

const char* codec_label(VideoCodec c) {
    switch (c) {
    case VideoCodec::H264: return "H.264";
    case VideoCodec::H265: return "HEVC";
    case VideoCodec::AV1:  return "AV1";
    }
    return "?";
}

/// Encoders to try for a codec, best first.
std::vector<std::string> candidates(VideoCodec c) {
    switch (c) {
    case VideoCodec::H264: return {"h264_nvenc", "h264_vaapi", "libx264"};
    case VideoCodec::H265: return {"hevc_nvenc", "hevc_vaapi"};
    case VideoCodec::AV1:  return {"av1_nvenc", "av1_vaapi"};
    }
    return {};
}

std::string av_error(int err) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {};
    av_strerror(err, buf, sizeof(buf));
    return buf;
}

// --- Parameter-set safety net ------------------------------------------------
// Every backend we use already repeats VPS/SPS/PPS (or the AV1 sequence header)
// on each IDR — checked for x264 and VAAPI. This keeps the contract even if a
// driver does not: a keyframe without them leaves a client that joined late,
// or lost the first IDR, decoding nothing.

/// Split an Annex-B buffer into NAL units (without start codes).
std::vector<std::pair<const uint8_t*, size_t>> split_annexb(const uint8_t* d, size_t n) {
    std::vector<std::pair<const uint8_t*, size_t>> nals;
    size_t i = 0, start = SIZE_MAX;
    while (i + 3 <= n) {
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
            if (start != SIZE_MAX) {
                size_t end = i;
                if (end > start && d[end - 1] == 0) --end;  // 4-byte start code
                nals.emplace_back(d + start, end - start);
            }
            i += 3;
            start = i;
        } else {
            ++i;
        }
    }
    if (start != SIZE_MAX && start < n) nals.emplace_back(d + start, n - start);
    return nals;
}

bool is_parameter_set(VideoCodec c, const uint8_t* nal) {
    if (c == VideoCodec::H264) {
        const int t = nal[0] & 0x1F;
        return t == 7 || t == 8;               // SPS, PPS
    }
    const int t = (nal[0] >> 1) & 0x3F;
    return t >= 32 && t <= 34;                 // VPS, SPS, PPS
}

/// AV1: walk the OBUs (all carry a size field in libavcodec output).
bool av1_has_sequence_header(const uint8_t* d, size_t n, std::vector<uint8_t>* out_seq) {
    size_t i = 0;
    while (i < n) {
        const size_t obu_start = i;
        const uint8_t h = d[i++];
        const int type = (h >> 3) & 0xF;
        if (h & 0x04) ++i;                     // extension header
        if (!(h & 0x02)) return false;         // no size field: cannot walk
        uint64_t size = 0;
        for (int s = 0; i < n; s += 7) {
            const uint8_t b = d[i++];
            size |= static_cast<uint64_t>(b & 0x7F) << s;
            if (!(b & 0x80)) break;
        }
        if (i + size > n) return false;
        if (type == 1) {
            if (out_seq) out_seq->assign(d + obu_start, d + i + size);
            return true;
        }
        i += size;
    }
    return false;
}

class FfmpegEncoder : public IVideoEncoder {
public:
    explicit FfmpegEncoder(bool verbose = true) : verbose_(verbose) {}
    ~FfmpegEncoder() override { close(); }

    bool initialize(const EncoderConfig& config) override {
        close();
        config_ = config;
        for (const auto& name : candidates(config.codec)) {
            if (open(name)) {
                if (verbose_) std::cout << "[FfmpegEncoder] " << codec_label(config.codec) << " via "
                          << name << " " << config.width << "x" << config.height << " @"
                          << config.fps << " fps, " << config.bitrate_kbps << " kbps\n";
                return true;
            }
        }
        if (verbose_) {
            std::cerr << "[FfmpegEncoder] No working " << codec_label(config.codec)
                      << " encoder on this machine\n";
        }
        return false;
    }

    std::vector<EncodedPacket> encode(const uint8_t* bgra, uint32_t width, uint32_t height,
                                      uint32_t pitch, uint64_t timestamp_us) override {
        if (!ctx_ && !reopen()) return {};

        // BGRA (any size) → NV12 at the stream size, BT.601 limited range.
        sws_ = sws_getCachedContext(sws_, static_cast<int>(width), static_cast<int>(height),
                                    AV_PIX_FMT_BGRA, ctx_->width, ctx_->height, AV_PIX_FMT_NV12,
                                    SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (!sws_) return {};
        const int* coef = sws_getCoefficients(SWS_CS_ITU601);
        sws_setColorspaceDetails(sws_, coef, 1, coef, 0, 0, 1 << 16, 1 << 16);

        if (av_frame_make_writable(sw_frame_) < 0) return {};
        const uint8_t* src[1] = {bgra};
        const int src_stride[1] = {static_cast<int>(pitch)};
        sws_scale(sws_, src, src_stride, 0, static_cast<int>(height),
                  sw_frame_->data, sw_frame_->linesize);

        AVFrame* frame = sw_frame_;
        if (hw_frames_) {
            av_frame_unref(hw_frame_);
            if (av_hwframe_get_buffer(hw_frames_, hw_frame_, 0) < 0 ||
                av_hwframe_transfer_data(hw_frame_, sw_frame_, 0) < 0) {
                return fail("GPU upload failed");
            }
            frame = hw_frame_;
        }

        frame->pts = pts_++;
        const bool key = force_keyframe_;
        force_keyframe_ = false;
        frame->pict_type = key ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
        if (key) frame->flags |= AV_FRAME_FLAG_KEY;
        else     frame->flags &= ~AV_FRAME_FLAG_KEY;

        int err = avcodec_send_frame(ctx_, frame);
        if (err < 0) return fail("send_frame: " + av_error(err));

        std::vector<EncodedPacket> out;
        while ((err = avcodec_receive_packet(ctx_, pkt_)) >= 0) {
            EncodedPacket p;
            p.is_keyframe  = (pkt_->flags & AV_PKT_FLAG_KEY) != 0;
            p.timestamp_us = timestamp_us;
            p.data.assign(pkt_->data, pkt_->data + pkt_->size);
            av_packet_unref(pkt_);
            if (p.is_keyframe) ensure_parameter_sets(p.data);
            if (config_.codec == VideoCodec::AV1 && !p.data.empty() &&
                ((p.data[0] >> 3) & 0xF) != 2) {
                // libavcodec's AV1 packets have no temporal delimiter; a
                // low-overhead AV1 stream is TD-separated temporal units,
                // and decoders (ffmpeg's obu parser, MediaCodec) expect it.
                static const uint8_t kTemporalDelimiter[2] = {0x12, 0x00};
                p.data.insert(p.data.begin(), kTemporalDelimiter, kTemporalDelimiter + 2);
            }
            out.push_back(std::move(p));
        }
        if (err != AVERROR(EAGAIN) && err != AVERROR_EOF) {
            return fail("receive_packet: " + av_error(err));
        }
        failures_ = 0;
        return out;
    }

    std::vector<EncodedPacket> flush() override { return {}; }

    void request_keyframe() override { force_keyframe_ = true; }

    bool reconfigure(const EncoderConfig& config) override {
        if (config.width != config_.width || config.height != config_.height ||
            config.codec != config_.codec) {
            return false;
        }
        config_ = config;
        if (!ctx_) return true;  // failed session: reopen() picks the new config up
        // libx264 and NVENC take a new bitrate between frames (libavcodec
        // re-reads bit_rate / rc_max_rate / rc_buffer_size on every frame),
        // and set_rate() folds a new frame rate into it.
        if (name_.find("vaapi") == std::string::npos) {
            set_rate();
            return true;
        }
        // VAAPI fixes rate control at open: re-open at the same size. The
        // next frame is an IDR with its parameter sets, which the client's
        // decoder takes mid-stream.
        const std::string name = name_;
        close();
        if (!open(name)) fail("re-open with the new settings failed");
        return true;
    }

    EncoderBackend backend() const override {
        return name_ == "libx264" ? EncoderBackend::SOFTWARE
             : name_.find("vaapi") != std::string::npos ? EncoderBackend::QSV
             : EncoderBackend::NVENC;
    }

    std::string name() const override { return "FFmpeg " + name_; }

    bool scales_input() const override { return true; }

private:
    bool open(const std::string& name) {
        const AVCodec* codec = avcodec_find_encoder_by_name(name.c_str());
        if (!codec) return false;
        const bool vaapi = name.find("vaapi") != std::string::npos;

        ctx_ = avcodec_alloc_context3(codec);
        const int fps = static_cast<int>(std::max(1u, config_.fps));
        ctx_->width        = static_cast<int>(config_.width);
        ctx_->height       = static_cast<int>(config_.height);
        open_fps_          = static_cast<uint32_t>(fps);
        ctx_->time_base    = {1, fps};
        ctx_->framerate    = {fps, 1};
        ctx_->gop_size     = static_cast<int>(config_.gop_size);
        ctx_->max_b_frames = 0;
        set_rate();
        ctx_->color_range     = AVCOL_RANGE_MPEG;
        ctx_->colorspace      = AVCOL_SPC_SMPTE170M;
        ctx_->color_primaries = AVCOL_PRI_SMPTE170M;
        ctx_->color_trc       = AVCOL_TRC_SMPTE170M;
        ctx_->flags          |= AV_CODEC_FLAG_LOW_DELAY;
        ctx_->pix_fmt         = vaapi ? AV_PIX_FMT_VAAPI : AV_PIX_FMT_NV12;

        AVDictionary* opts = nullptr;
        if (name == "libx264") {
            av_dict_set(&opts, "preset", "superfast", 0);
            av_dict_set(&opts, "tune", "zerolatency", 0);
            av_dict_set(&opts, "forced-idr", "1", 0);
            av_dict_set(&opts, "x264-params", "repeat-headers=1", 0);
        } else if (vaapi) {
            av_dict_set(&opts, "rc_mode", "CBR", 0);
            av_dict_set(&opts, "async_depth", "1", 0);  // no frames in flight
        } else {  // nvenc
            av_dict_set(&opts, "preset", "p4", 0);
            av_dict_set(&opts, "tune", "ull", 0);
            av_dict_set(&opts, "rc", "cbr", 0);
            av_dict_set(&opts, "zerolatency", "1", 0);
            av_dict_set(&opts, "delay", "0", 0);
            av_dict_set(&opts, "forced-idr", "1", 0);
        }

        if (vaapi && !init_vaapi()) {
            close();
            av_dict_free(&opts);
            return false;
        }

        const int err = avcodec_open2(ctx_, codec, &opts);
        av_dict_free(&opts);
        if (err < 0) {
            close();
            return false;
        }

        sw_frame_ = av_frame_alloc();
        sw_frame_->format = AV_PIX_FMT_NV12;
        sw_frame_->width  = ctx_->width;
        sw_frame_->height = ctx_->height;
        if (av_frame_get_buffer(sw_frame_, 0) < 0) {
            close();
            return false;
        }
        sw_frame_->color_range = AVCOL_RANGE_MPEG;
        sw_frame_->colorspace  = AVCOL_SPC_SMPTE170M;
        hw_frame_ = av_frame_alloc();
        pkt_      = av_packet_alloc();
        name_     = name;
        pts_      = 0;
        force_keyframe_ = true;
        return true;
    }

    /// CBR at config_.bitrate_kbps with ~50 ms of VBV, capped at 600 kbit: an
    /// IDR must fit, so it stays a few dozen UDP chunks (same reasoning as
    /// mf_encoder.cpp).
    /// The encoders budget bits per frame from the frame rate they were
    /// opened with (measured: x264 fed 30 fps opened at 60 spends 3.2 of
    /// 8 Mbps), so a lower config_.fps scales the rate they are given up.
    void set_rate() {
        ctx_->bit_rate       = static_cast<int64_t>(config_.bitrate_kbps) * 1000 *
                               open_fps_ / std::max(1u, config_.fps);
        ctx_->rc_max_rate    = ctx_->bit_rate;
        ctx_->rc_buffer_size = static_cast<int>(
            std::min<int64_t>(static_cast<int64_t>(config_.bitrate_kbps) * 50, 600000));
    }

    bool init_vaapi() {
        // NULL device = libva's default render node (/dev/dri/renderD128...).
        if (av_hwdevice_ctx_create(&hw_device_, AV_HWDEVICE_TYPE_VAAPI, nullptr, nullptr, 0) < 0) {
            return false;
        }
        hw_frames_ = av_hwframe_ctx_alloc(hw_device_);
        auto* fc = reinterpret_cast<AVHWFramesContext*>(hw_frames_->data);
        fc->format    = AV_PIX_FMT_VAAPI;
        fc->sw_format = AV_PIX_FMT_NV12;
        fc->width     = ctx_->width;
        fc->height    = ctx_->height;
        fc->initial_pool_size = 4;
        if (av_hwframe_ctx_init(hw_frames_) < 0) return false;
        ctx_->hw_frames_ctx = av_buffer_ref(hw_frames_);
        return ctx_->hw_frames_ctx != nullptr;
    }

    void close() {
        avcodec_free_context(&ctx_);
        av_frame_free(&sw_frame_);
        av_frame_free(&hw_frame_);
        av_packet_free(&pkt_);
        av_buffer_unref(&hw_frames_);
        av_buffer_unref(&hw_device_);
        sws_freeContext(sws_);
        sws_ = nullptr;
    }

    /// A GPU reset or a suspend/resume can kill a hardware session. Drop it
    /// and let the next encode() re-open (backing off), with a fresh IDR.
    std::vector<EncodedPacket> fail(const std::string& why) {
        std::cerr << "[FfmpegEncoder] " << name_ << ": " << why << ", re-opening\n";
        close();
        ++failures_;
        next_reopen_ = std::chrono::steady_clock::now() +
                       std::chrono::milliseconds(std::min(5000, 200 * failures_));
        return {};
    }

    bool reopen() {
        if (std::chrono::steady_clock::now() < next_reopen_) return false;
        for (const auto& name : candidates(config_.codec)) {
            if (open(name)) {
                std::cout << "[FfmpegEncoder] Re-opened " << name << "\n";
                return true;
            }
        }
        next_reopen_ = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        return false;
    }

    void ensure_parameter_sets(std::vector<uint8_t>& au) {
        if (config_.codec == VideoCodec::AV1) {
            std::vector<uint8_t> seq;
            if (av1_has_sequence_header(au.data(), au.size(), &seq)) {
                header_ = std::move(seq);
            } else if (!header_.empty()) {
                // After the temporal delimiter (2 bytes) if there is one.
                const size_t at = (au.size() >= 2 && ((au[0] >> 3) & 0xF) == 2) ? 2 : 0;
                au.insert(au.begin() + at, header_.begin(), header_.end());
            }
            return;
        }
        std::vector<uint8_t> params;
        for (const auto& [nal, len] : split_annexb(au.data(), au.size())) {
            if (len && is_parameter_set(config_.codec, nal)) {
                static const uint8_t sc[4] = {0, 0, 0, 1};
                params.insert(params.end(), sc, sc + 4);
                params.insert(params.end(), nal, nal + len);
            }
        }
        if (!params.empty()) {
            header_ = std::move(params);
        } else if (!header_.empty()) {
            au.insert(au.begin(), header_.begin(), header_.end());
        }
    }

    const bool      verbose_;
    EncoderConfig   config_;
    std::string     name_;
    AVCodecContext* ctx_       = nullptr;
    AVBufferRef*    hw_device_ = nullptr;
    AVBufferRef*    hw_frames_ = nullptr;
    AVFrame*        sw_frame_  = nullptr;
    AVFrame*        hw_frame_  = nullptr;
    AVPacket*       pkt_       = nullptr;
    SwsContext*     sws_       = nullptr;
    int64_t         pts_       = 0;
    uint32_t        open_fps_  = 30;   ///< frame rate the session was opened with
    bool            force_keyframe_ = true;
    int             failures_  = 0;
    std::chrono::steady_clock::time_point next_reopen_{};
    std::vector<uint8_t> header_;  ///< last seen parameter sets / sequence header
};

void quiet_ffmpeg_once() {
    // Probing prints "Cannot load libcuda.so.1" and the like for every
    // backend that is simply absent; our own log says what was picked.
    static std::once_flag once;
    std::call_once(once, [] { av_log_set_level(AV_LOG_FATAL); });
}

}  // namespace

std::unique_ptr<IVideoEncoder> create_hw_encoder() {
    quiet_ffmpeg_once();
    return std::make_unique<FfmpegEncoder>();
}

bool hw_encoder_available(VideoCodec codec) {
    quiet_ffmpeg_once();
    static std::mutex mutex;
    static std::map<VideoCodec, bool> cache;
    std::lock_guard<std::mutex> lock(mutex);
    auto it = cache.find(codec);
    if (it != cache.end()) return it->second;

    EncoderConfig probe;
    probe.codec = codec;
    probe.width = 640;
    probe.height = 360;
    probe.bitrate_kbps = 2000;
    FfmpegEncoder enc(false);
    const bool ok = cache[codec] = enc.initialize(probe);
    if (ok && enc.backend() == EncoderBackend::SOFTWARE) {
        std::cout << "[Host] No GPU video encoder: H.264 runs on the CPU (libx264), about\n"
                     "       30 fps at 1080p on several cores. For the GPU encoder install\n"
                     "       its VA-API driver (Intel: intel-media-va-driver-non-free,\n"
                     "       AMD: mesa-va-drivers) or NVIDIA's driver (NVENC), then restart.\n";
    }
    return ok;
}

}  // namespace immersive
