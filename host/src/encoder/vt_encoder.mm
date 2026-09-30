/// macOS hardware H.264 / HEVC encoder on VideoToolbox.
///
/// One VTCompressionSession per stream. encode() copies the BGRA frame into
/// an IOSurface buffer from the session's pool (VideoToolbox converts it to
/// YUV on the GPU) and then completes the frame, so the call returns that
/// frame's access unit with no added latency. VideoToolbox emits
/// length-prefixed NAL units with the parameter sets kept in the format
/// description; they are converted to Annex-B with VPS/SPS/PPS prepended on
/// every keyframe (see the output contract in encoder.h).
///
/// H.264 prefers Apple's low-latency rate control (the FaceTime mode). A
/// session that dies (sleep/wake, GPU switch) is rebuilt on the next frame,
/// which then starts with an IDR. Apple silicon has no AV1 encoder.

#include "encoder/encoder.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <iostream>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr uint8_t kStartCode[4] = {0, 0, 0, 1};

void append_nal(std::vector<uint8_t>& out, const uint8_t* nal, size_t size) {
    out.insert(out.end(), kStartCode, kStartCode + 4);
    out.insert(out.end(), nal, nal + size);
}

/// Appends length-prefixed NAL units (AVCC/HVCC, big-endian lengths of
/// `len_size` bytes) to `out` as Annex-B. False if the buffer is malformed.
bool append_annexb(const uint8_t* src, size_t size, int len_size,
                   std::vector<uint8_t>& out) {
    if (len_size < 1 || len_size > 4) return false;
    size_t pos = 0;
    while (pos < size) {
        if (size - pos < static_cast<size_t>(len_size)) return false;
        size_t n = 0;
        for (int i = 0; i < len_size; ++i) n = (n << 8) | src[pos++];
        if (n > size - pos) return false;
        if (n > 0) append_nal(out, src + pos, n);
        pos += n;
    }
    return true;
}

}  // namespace

namespace immersive {
namespace {

constexpr auto kReopenInterval = std::chrono::seconds(1);
constexpr const char* kLowLatency = "hardware, low-latency";
constexpr const char* kHardware   = "hardware";
constexpr const char* kSoftware   = "software";

const char* codec_label(VideoCodec c) {
    switch (c) {
    case VideoCodec::H264: return "H.264";
    case VideoCodec::H265: return "HEVC";
    case VideoCodec::AV1:  return "AV1";
    }
    return "?";
}

bool is_sync_sample(CMSampleBufferRef sample) {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (!attachments || CFArrayGetCount(attachments) < 1) return true;
    NSDictionary* info = (__bridge NSDictionary*)CFArrayGetValueAtIndex(attachments, 0);
    return ![info[(__bridge NSString*)kCMSampleAttachmentKey_NotSync] boolValue];
}

OSStatus parameter_set(CMFormatDescriptionRef fmt, bool hevc, size_t index,
                       const uint8_t** ptr, size_t* size, size_t* count,
                       int* len_size) {
    return hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                      fmt, index, ptr, size, count, len_size)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                      fmt, index, ptr, size, count, len_size);
}

/// Hardware with low-latency rate control, then plain hardware, then (H.264
/// only) Apple's software encoder. `mode` says which one succeeded.
VTCompressionSessionRef create_session(const EncoderConfig& cfg,
                                       VTCompressionOutputCallback callback,
                                       void* refcon, const char** mode) {
    if (cfg.codec == VideoCodec::AV1) return nullptr;
    const CMVideoCodecType type =
        cfg.codec == VideoCodec::H265 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;

    NSString* require_hw =
        (__bridge NSString*)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder;
    NSString* low_latency =
        (__bridge NSString*)kVTVideoEncoderSpecification_EnableLowLatencyRateControl;
    NSString* enable_hw =
        (__bridge NSString*)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder;
    struct Attempt { NSDictionary* spec; const char* mode; };
    const Attempt attempts[] = {
        {@{require_hw : @YES, low_latency : @YES}, kLowLatency},
        {@{require_hw : @YES}, kHardware},
        {@{enable_hw : @NO}, kSoftware},
    };
    NSDictionary* source = @{
        (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (__bridge NSString*)kCVPixelBufferWidthKey : @(cfg.width),
        (__bridge NSString*)kCVPixelBufferHeightKey : @(cfg.height),
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };

    for (const Attempt& a : attempts) {
        if (a.mode == kSoftware && cfg.codec != VideoCodec::H264) break;
        VTCompressionSessionRef session = nullptr;
        const OSStatus st = VTCompressionSessionCreate(
            nullptr, static_cast<int32_t>(cfg.width), static_cast<int32_t>(cfg.height),
            type, (__bridge CFDictionaryRef)a.spec, (__bridge CFDictionaryRef)source,
            nullptr, callback, refcon, &session);
        if (st == noErr && session) {
            if (mode) *mode = a.mode;
            return session;
        }
    }
    return nullptr;
}

class VtEncoder : public IVideoEncoder {
public:
    ~VtEncoder() override { close_session(); }

    bool initialize(const EncoderConfig& cfg) override {
        close_session();
        config_ = cfg;
        if (cfg.codec == VideoCodec::AV1) {
            std::cerr << "[VtEncoder] AV1 encoding is not available on macOS\n";
            return false;
        }
        bool opened = false;
        @autoreleasepool { opened = open_session(); }
        if (!opened) {
            std::cerr << "[VtEncoder] No " << codec_label(cfg.codec)
                      << " encoder for " << cfg.width << "x" << cfg.height << "\n";
            return false;
        }
        std::cout << "[VtEncoder] Initialized " << codec_label(cfg.codec) << ": "
                  << cfg.width << "x" << cfg.height << " @ " << cfg.fps << " fps"
                  << " bitrate=" << cfg.bitrate_kbps << " kbps [" << mode_ << "]\n";
        return true;
    }

    std::vector<EncodedPacket> encode(const uint8_t* bgra, uint32_t width, uint32_t height,
                                      uint32_t pitch, uint64_t timestamp_us) override {
        // main.cpp scales to the stream size first, since scales_input() is false.
        if (!bgra || width != config_.width || height != config_.height) return {};

        std::vector<EncodedPacket> out;
        @autoreleasepool {
            for (int attempt = 0; attempt < 2; ++attempt) {
                if (!session_) {
                    const auto now = std::chrono::steady_clock::now();
                    if (now < reopen_at_) break;
                    reopen_at_ = now + kReopenInterval;
                    if (!open_session()) {
                        std::cerr << "[VtEncoder] Could not recreate the "
                                  << codec_label(config_.codec) << " session\n";
                        break;
                    }
                    std::cout << "[VtEncoder] Session recreated [" << mode_ << "]\n";
                }
                const OSStatus st = encode_frame(bgra, pitch, timestamp_us, out);
                if (st == noErr) break;
                // kVTInvalidSessionErr after sleep/wake or a GPU switch, or
                // an encoder malfunction: rebuild it and resend this frame.
                std::cerr << "[VtEncoder] Encode failed (" << st
                          << "), recreating the session\n";
                close_session();
                out.clear();
            }
        }
        return out;
    }

    std::vector<EncodedPacket> flush() override { return {}; }  // encode() never holds frames

    void request_keyframe() override { force_keyframe_ = true; }

    // There is no VideoToolbox value; only hardware-vs-software matters.
    EncoderBackend backend() const override {
        return mode_ == kSoftware ? EncoderBackend::SOFTWARE : EncoderBackend::NVENC;
    }

    std::string name() const override {
        return std::string("VideoToolbox ") + codec_label(config_.codec) + " (" + mode_ + ")";
    }

private:
    EncoderConfig           config_;
    VTCompressionSessionRef session_ = nullptr;
    const char*             mode_    = "none";
    std::atomic<bool>       force_keyframe_{true};
    uint64_t                last_pts_us_ = 0;
    std::chrono::steady_clock::time_point reopen_at_{};

    // Filled by the output callback, which may run on a VideoToolbox thread.
    std::mutex                 output_mutex_;
    std::vector<EncodedPacket> output_;
    OSStatus                   output_status_ = noErr;

    bool open_session() {
        session_ = create_session(config_, &VtEncoder::on_output, this, &mode_);
        if (!session_) return false;

        const bool hevc = config_.codec == VideoCodec::H265;
        const bool low_latency = mode_ == kLowLatency;
        const double fps = std::max<uint32_t>(1, config_.fps);
        const double bps = static_cast<double>(config_.bitrate_kbps) * 1000.0;
        // Same small VBV as mf_encoder.cpp (~50 ms, at most 600 kbit), as a
        // leaky bucket over one frame: an IDR stays a few dozen UDP chunks.
        const double vbv_bits = std::min(bps * 0.05, 600000.0);
        NSArray* data_rate_limits =
            @[ @(static_cast<int64_t>((vbv_bits + bps / fps) / 8.0)), @(1.0 / fps) ];

        auto set = [&](CFStringRef key, id value) {
            const OSStatus st = VTSessionSetProperty(session_, key, (__bridge CFTypeRef)value);
            if (st != noErr) {
                std::cerr << "[VtEncoder] " << ((__bridge NSString*)key).UTF8String
                          << " not applied (" << st << ")\n";
            }
            return st == noErr;
        };
        set(kVTCompressionPropertyKey_RealTime, @YES);
        // Low-latency mode never reorders; elsewhere B-frames would break the
        // one-encode-one-access-unit contract, so this one is mandatory.
        if (!set(kVTCompressionPropertyKey_AllowFrameReordering, @NO) && !low_latency) {
            close_session();
            return false;
        }
        set(kVTCompressionPropertyKey_ProfileLevel,
            (__bridge NSString*)(hevc ? kVTProfileLevel_HEVC_Main_AutoLevel
                                      : kVTProfileLevel_H264_High_AutoLevel));
        set(kVTCompressionPropertyKey_AverageBitRate, @(static_cast<int32_t>(bps)));
        set(kVTCompressionPropertyKey_DataRateLimits, data_rate_limits);
        set(kVTCompressionPropertyKey_ExpectedFrameRate, @(fps));
        // Low-latency mode is an infinite GOP driven by ForceKeyFrame and may
        // refuse this; main.cpp requests an IDR every second anyway.
        if (!low_latency) {
            set(kVTCompressionPropertyKey_MaxKeyFrameInterval,
                @(std::max<uint32_t>(1, config_.gop_size)));
        }
        // BT.601 limited range, like the other encoders: the matrix drives
        // the RGB->YUV conversion and all three end up in the VUI.
        NSString* bt601 = (__bridge NSString*)kCVImageBufferYCbCrMatrix_ITU_R_601_4;
        set(kVTCompressionPropertyKey_YCbCrMatrix, bt601);
        set(kVTCompressionPropertyKey_ColorPrimaries,
            (__bridge NSString*)kCVImageBufferColorPrimaries_SMPTE_C);
        set(kVTCompressionPropertyKey_TransferFunction,
            (__bridge NSString*)kCVImageBufferTransferFunction_ITU_R_709_2);
        set(kVTCompressionPropertyKey_PixelTransferProperties,
            @{(__bridge NSString*)kVTPixelTransferPropertyKey_DestinationYCbCrMatrix : bt601});

        VTCompressionSessionPrepareToEncodeFrames(session_);
        force_keyframe_ = true;
        return true;
    }

    void close_session() {
        if (!session_) return;
        VTCompressionSessionInvalidate(session_);
        CFRelease(session_);
        session_ = nullptr;
    }

    OSStatus encode_frame(const uint8_t* bgra, uint32_t pitch, uint64_t timestamp_us,
                          std::vector<EncodedPacket>& out) {
        // The pool goes away with an invalidated session.
        CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(session_);
        if (!pool) return kVTInvalidSessionErr;
        CVPixelBufferRef pb = nullptr;
        if (CVPixelBufferPoolCreatePixelBuffer(nullptr, pool, &pb) != kCVReturnSuccess || !pb) {
            return kVTAllocationFailedErr;
        }
        if (CVPixelBufferLockBaseAddress(pb, 0) != kCVReturnSuccess) {
            CFRelease(pb);
            return kVTAllocationFailedErr;
        }
        auto*        dst     = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pb));
        const size_t dst_bpr = CVPixelBufferGetBytesPerRow(pb);
        const size_t row     = static_cast<size_t>(config_.width) * 4;
        for (uint32_t y = 0; dst && y < config_.height; ++y) {
            std::memcpy(dst + y * dst_bpr, bgra + static_cast<size_t>(y) * pitch, row);
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);
        if (!dst) {
            CFRelease(pb);
            return kVTAllocationFailedErr;
        }

        // Presentation timestamps must strictly increase within a session.
        last_pts_us_ = std::max(timestamp_us, last_pts_us_ + 1);
        const bool idr = force_keyframe_.exchange(false);
        NSDictionary* props =
            idr ? @{(__bridge NSString*)kVTEncodeFrameOptionKey_ForceKeyFrame : @YES} : nil;
        {
            std::lock_guard<std::mutex> lock(output_mutex_);
            output_.clear();
            output_status_ = noErr;
        }
        OSStatus st = VTCompressionSessionEncodeFrame(
            session_, pb, CMTimeMake(static_cast<int64_t>(last_pts_us_), 1000000),
            kCMTimeInvalid, (__bridge CFDictionaryRef)props, nullptr, nullptr);
        CFRelease(pb);
        if (st == noErr) st = VTCompressionSessionCompleteFrames(session_, kCMTimeInvalid);
        {
            std::lock_guard<std::mutex> lock(output_mutex_);
            if (st == noErr) st = output_status_;
            out.swap(output_);
        }
        for (auto& pkt : out) pkt.timestamp_us = timestamp_us;
        // A dropped or failed frame must not swallow a requested IDR.
        if (idr && (out.empty() || !out.front().is_keyframe)) force_keyframe_ = true;
        return st;
    }

    static void on_output(void* refcon, void*, OSStatus status, VTEncodeInfoFlags flags,
                          CMSampleBufferRef sample) {
        auto* self = static_cast<VtEncoder*>(refcon);
        if (!self) return;
        EncodedPacket pkt{};
        bool ok = false;
        if (status == noErr && sample && !(flags & kVTEncodeInfo_FrameDropped)) {
            @autoreleasepool { ok = self->to_annexb(sample, pkt); }
        }
        std::lock_guard<std::mutex> lock(self->output_mutex_);
        if (status != noErr) self->output_status_ = status;
        if (ok) self->output_.push_back(std::move(pkt));
    }

    bool to_annexb(CMSampleBufferRef sample, EncodedPacket& pkt) const {
        CMBlockBufferRef       block = CMSampleBufferGetDataBuffer(sample);
        CMFormatDescriptionRef fmt   = CMSampleBufferGetFormatDescription(sample);
        if (!block || !fmt) return false;

        const bool hevc     = config_.codec == VideoCodec::H265;
        size_t     count    = 0;
        int        len_size = 4;
        if (parameter_set(fmt, hevc, 0, nullptr, nullptr, &count, &len_size) != noErr) {
            return false;
        }
        pkt.is_keyframe = is_sync_sample(sample);
        if (pkt.is_keyframe) {
            for (size_t i = 0; i < count; ++i) {
                const uint8_t* ps = nullptr;
                size_t         ps_size = 0;
                if (parameter_set(fmt, hevc, i, &ps, &ps_size, nullptr, nullptr) != noErr ||
                    !ps) {
                    return false;
                }
                append_nal(pkt.data, ps, ps_size);
            }
        }

        std::vector<uint8_t> raw(CMBlockBufferGetDataLength(block));
        if (raw.empty() ||
            CMBlockBufferCopyDataBytes(block, 0, raw.size(), raw.data()) != kCMBlockBufferNoErr) {
            return false;
        }
        return append_annexb(raw.data(), raw.size(), len_size, pkt.data);
    }
};

}  // namespace

std::unique_ptr<IVideoEncoder> create_hw_encoder() {
    return std::make_unique<VtEncoder>();
}

bool hw_encoder_available(VideoCodec codec) {
    static std::mutex mutex;
    static std::map<VideoCodec, bool> cache;
    std::lock_guard<std::mutex> lock(mutex);
    auto it = cache.find(codec);
    if (it != cache.end()) return it->second;

    EncoderConfig probe;
    probe.codec  = codec;
    probe.width  = 640;
    probe.height = 360;
    bool ok = false;
    @autoreleasepool {
        if (VTCompressionSessionRef s = create_session(probe, nullptr, nullptr, nullptr)) {
            VTCompressionSessionInvalidate(s);
            CFRelease(s);
            ok = true;
        }
    }
    return cache[codec] = ok;
}

}  // namespace immersive
