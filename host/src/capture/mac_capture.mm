/// macOS screen capture through ScreenCaptureKit (macOS 12.3+, built for 13+).
///
/// One SCStream per captured display, delivering BGRA frames at the display's
/// pixel size (or at the set_output_size() stream size, scaled on the GPU by
/// ScreenCaptureKit) into a latest-frame mailbox that acquire_frame() waits on.
/// SCStream callbacks only touch a shared FrameMailbox (never `this`), so a
/// late callback after stop_capture()/destruction is harmless.

#include "capture/dxgi_capture.h"
#include "driver/idd_manager.h"
#include "protocol.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <iostream>
#include <map>
#include <mutex>
#include <string>

// CoreGraphics' private virtual-display classes (declarations only; the
// classes are fetched with NSClassFromString, never linked by name).
@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString* name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray* modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor*)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings*)settings;
@end

namespace {

using immersive::CapturedFrame;
using immersive::DisplayInfo;

constexpr int64_t kContentTimeoutSec = 5;
constexpr int64_t kStartTimeoutSec   = 5;
constexpr int64_t kStopTimeoutSec    = 2;

struct FrameMailbox {
    std::mutex                     mutex;
    std::condition_variable        cv;
    std::unique_ptr<CapturedFrame> latest;
    std::atomic<bool>              stopped{false};  // the system ended the stream
    uint8_t                        monitor_id = 0;
};

// Display ids handed to main.cpp are indices into the list from the first
// enumerate_displays(). Each stream worker uses a fresh capture instance, so
// the id → CGDirectDisplayID map is process-wide: a display plugged in later
// must not shift which screen an existing id captures.
std::mutex                     g_registry_mutex;
std::map<uint8_t, DisplayInfo> g_registry;

// Virtual screens made by MacVirtualDisplayManager: CGDirectDisplayID →
// monitor id (VIRTUAL_MONITOR_ID_BASE + n). Locked after g_registry_mutex.
std::mutex                                g_virtual_mutex;
std::map<CGDirectDisplayID, uint8_t>      g_virtual;

CGDirectDisplayID virtual_native_id(uint8_t monitor_id) {
    std::lock_guard<std::mutex> lock(g_virtual_mutex);
    for (const auto& [did, mid] : g_virtual) {
        if (mid == monitor_id) return did;
    }
    return 0;
}

bool wait_signal(dispatch_semaphore_t sem, int64_t seconds) {
    return dispatch_semaphore_wait(
               sem, dispatch_time(DISPATCH_TIME_NOW,
                                  static_cast<int64_t>(seconds * NSEC_PER_SEC))) == 0;
}

std::string describe(NSError* error) {
    const char* text = error ? error.localizedDescription.UTF8String : nullptr;
    return text ? text : "no error details";
}

void mark_stopped(FrameMailbox& mb) {
    {
        std::lock_guard<std::mutex> lock(mb.mutex);
        mb.stopped = true;
    }
    mb.cv.notify_all();
}

/// Current pixel size of a display (Retina backing pixels, not points).
bool display_pixel_size(CGDirectDisplayID did, size_t& w, size_t& h, double& hz) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
    if (!mode) return false;
    w  = CGDisplayModeGetPixelWidth(mode);
    h  = CGDisplayModeGetPixelHeight(mode);
    hz = CGDisplayModeGetRefreshRate(mode);
    CGDisplayModeRelease(mode);
    return w > 0 && h > 0;
}

std::vector<DisplayInfo> list_displays() {
    // Initialises the CoreGraphics connection. ScreenCaptureKit asserts
    // (CGS_REQUIRE_INIT) in a process without NSApplication otherwise.
    CGMainDisplayID();

    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess) return {};

    std::map<CGDirectDisplayID, uint8_t> virtuals;
    {
        std::lock_guard<std::mutex> lock(g_virtual_mutex);
        virtuals = g_virtual;
    }
    std::vector<DisplayInfo> out;
    uint8_t physical = 0;
    for (uint32_t i = 0; i < count; ++i) {
        size_t w = 0, h = 0;
        double hz = 0;
        if (!display_pixel_size(ids[i], w, h, hz)) continue;
        const CGRect bounds = CGDisplayBounds(ids[i]);
        const auto v = virtuals.find(ids[i]);

        DisplayInfo d;
        d.id           = v != virtuals.end() ? v->second : physical++;
        d.width        = static_cast<uint16_t>(std::min<size_t>(w, 65535));
        d.height       = static_cast<uint16_t>(std::min<size_t>(h, 65535));
        d.refresh_rate = static_cast<uint8_t>(hz >= 1.0 ? std::min(hz + 0.5, 255.0) : 60);
        d.origin_x     = static_cast<int32_t>(bounds.origin.x);
        d.origin_y     = static_cast<int32_t>(bounds.origin.y);
        d.name         = v != virtuals.end()
                             ? "Virtual screen " + std::to_string(
                                   v->second - immersive::protocol::VIRTUAL_MONITOR_ID_BASE + 1)
                         : CGDisplayIsBuiltin(ids[i])
                             ? std::string("Built-in Display")
                             : "Display " + std::to_string(physical);
        d.is_primary   = CGDisplayIsMain(ids[i]);
        d.native_id    = ids[i];
        out.push_back(d);
    }
    return out;
}

}  // namespace

@interface Im2CaptureSink : NSObject <SCStreamOutput, SCStreamDelegate>
- (instancetype)initWithMailbox:(std::shared_ptr<FrameMailbox>)mailbox;
@end

@implementation Im2CaptureSink {
    std::shared_ptr<FrameMailbox> _mailbox;
}

- (instancetype)initWithMailbox:(std::shared_ptr<FrameMailbox>)mailbox {
    if ((self = [super init])) _mailbox = std::move(mailbox);
    return self;
}

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sample
                   ofType:(SCStreamOutputType)type {
    @autoreleasepool {
        if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;

        // Only "complete" frames carry new pixels; idle/blank/suspended ones
        // mean the screen did not change.
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
        if (!attachments || CFArrayGetCount(attachments) < 1) return;
        NSDictionary* info = (__bridge NSDictionary*)CFArrayGetValueAtIndex(attachments, 0);
        NSNumber* status = info[SCStreamFrameInfoStatus];
        if (!status || status.integerValue != SCFrameStatusComplete) return;

        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
        if (!pb || CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA) return;
        if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;

        const auto*  base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(pb));
        const size_t w    = CVPixelBufferGetWidth(pb);
        const size_t h    = CVPixelBufferGetHeight(pb);
        const size_t bpr  = CVPixelBufferGetBytesPerRow(pb);
        if (base && w > 0 && h > 0 && bpr >= w * 4) {
            // Reuse the buffer of a frame nobody consumed yet: at 60 fps this
            // saves a multi-megabyte allocation per frame.
            std::unique_ptr<CapturedFrame> frame;
            {
                std::lock_guard<std::mutex> lock(_mailbox->mutex);
                frame = std::move(_mailbox->latest);
            }
            if (!frame) frame = std::make_unique<CapturedFrame>();

            frame->monitor_id = _mailbox->monitor_id;
            frame->width      = static_cast<uint32_t>(w);
            frame->height     = static_cast<uint32_t>(h);
            frame->pitch      = static_cast<uint32_t>(w * 4);
            frame->pixels.resize(w * 4 * h);
            for (size_t y = 0; y < h; ++y) {
                std::memcpy(frame->pixels.data() + y * w * 4, base + y * bpr, w * 4);
            }
            frame->timestamp_us = static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now().time_since_epoch()).count());

            {
                std::lock_guard<std::mutex> lock(_mailbox->mutex);
                _mailbox->latest = std::move(frame);
            }
            _mailbox->cv.notify_one();
        }
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    }  // @autoreleasepool
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    std::cerr << "[MacCapture] Stream on monitor " << (int)_mailbox->monitor_id
              << " stopped: " << describe(error) << "\n";
    mark_stopped(*_mailbox);
}
@end

namespace immersive {

class MacCapture : public IScreenCapture {
public:
    ~MacCapture() override { stop_capture(); }

    std::vector<DisplayInfo> enumerate_displays() override {
        if (!CGPreflightScreenCaptureAccess()) {
            CGRequestScreenCaptureAccess();
            std::cerr << "[MacCapture] Screen Recording permission is not granted.\n"
                      << "[MacCapture] Open System Settings > Privacy & Security > Screen Recording,\n"
                      << "[MacCapture] enable the app running this host (your terminal, or\n"
                      << "[MacCapture] immersive2_host itself), then restart the host.\n";
            return {};
        }
        auto displays = list_displays();
        std::lock_guard<std::mutex> lock(g_registry_mutex);
        if (g_registry.empty()) {
            for (const auto& d : displays) g_registry[d.id] = d;
        }
        return displays;
    }

    bool start_capture(uint8_t display_id) override {
        stop_capture();

        @autoreleasepool {
            CGDirectDisplayID did = virtual_native_id(display_id);
            if (!did) {
                std::lock_guard<std::mutex> lock(g_registry_mutex);
                if (g_registry.empty()) {
                    for (const auto& d : list_displays()) g_registry[d.id] = d;
                }
                auto it = g_registry.find(display_id);
                if (it == g_registry.end()) {
                    std::cerr << "[MacCapture] Display " << (int)display_id << " not found\n";
                    return false;
                }
                did = it->second.native_id;
            }

            CGMainDisplayID();  // see list_displays()
            size_t w = 0, h = 0;
            double hz = 0;
            if (!display_pixel_size(did, w, h, hz)) {
                std::cerr << "[MacCapture] Display " << (int)display_id << " is not connected\n";
                return false;
            }

            __block SCShareableContent* content = nil;
            __block NSError* content_error = nil;
            dispatch_semaphore_t got = dispatch_semaphore_create(0);
            [SCShareableContent getShareableContentWithCompletionHandler:
                ^(SCShareableContent* c, NSError* e) {
                    content = c;
                    content_error = e;
                    dispatch_semaphore_signal(got);
                }];
            if (!wait_signal(got, kContentTimeoutSec) || !content) {
                std::cerr << "[MacCapture] Shareable content unavailable ("
                          << (content_error ? describe(content_error) : "timed out")
                          << "). Is Screen Recording granted?\n";
                return false;
            }

            SCDisplay* target = nil;
            for (SCDisplay* d in content.displays) {
                if (d.displayID == did) { target = d; break; }
            }
            if (!target) {
                std::cerr << "[MacCapture] Display " << (int)display_id
                          << " is not shareable right now\n";
                return false;
            }

            SCContentFilter* filter =
                [[SCContentFilter alloc] initWithDisplay:target excludingWindows:@[]];
            SCStreamConfiguration* config = [[SCStreamConfiguration alloc] init];
            config.width                = out_w_ ? out_w_ : w;
            config.height               = out_h_ ? out_h_ : h;
            config.pixelFormat          = kCVPixelFormatType_32BGRA;
            config.showsCursor          = YES;
            config.minimumFrameInterval = CMTimeMake(1, 60);
            config.queueDepth           = 5;

            auto mailbox        = std::make_shared<FrameMailbox>();
            mailbox->monitor_id = display_id;
            Im2CaptureSink* sink = [[Im2CaptureSink alloc] initWithMailbox:mailbox];
            dispatch_queue_t queue =
                dispatch_queue_create("immersive2.capture", DISPATCH_QUEUE_SERIAL);
            SCStream* stream = [[SCStream alloc] initWithFilter:filter
                                                  configuration:config
                                                       delegate:sink];

            NSError* add_error = nil;
            if (![stream addStreamOutput:sink
                                    type:SCStreamOutputTypeScreen
                      sampleHandlerQueue:queue
                                   error:&add_error]) {
                std::cerr << "[MacCapture] addStreamOutput failed: " << describe(add_error) << "\n";
                return false;
            }

            // From here on stop_capture() owns the cleanup, even if start fails.
            stream_  = stream;
            sink_    = sink;
            queue_   = queue;
            mailbox_ = mailbox;

            __block NSError* start_error = nil;
            dispatch_semaphore_t started = dispatch_semaphore_create(0);
            [stream startCaptureWithCompletionHandler:^(NSError* e) {
                start_error = e;
                dispatch_semaphore_signal(started);
            }];
            if (!wait_signal(started, kStartTimeoutSec) || start_error) {
                std::cerr << "[MacCapture] Could not start capture on display "
                          << (int)display_id << ": "
                          << (start_error ? describe(start_error) : "timed out") << "\n";
                stop_capture();
                return false;
            }

            std::cout << "[MacCapture] Started capture on display " << (int)display_id
                      << " (" << w << "x" << h << " -> " << config.width << "x"
                      << config.height << ")\n";
        }  // @autoreleasepool
        return true;
    }

    void stop_capture() override {
        if (!stream_) return;
        SCStream* stream = stream_;
        stream_ = nil;

        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        [stream stopCaptureWithCompletionHandler:^(NSError* ignored) {
            dispatch_semaphore_signal(stopped);
        }];
        if (!wait_signal(stopped, kStopTimeoutSec)) {
            std::cerr << "[MacCapture] stopCapture timed out\n";
        }
        [stream removeStreamOutput:sink_ type:SCStreamOutputTypeScreen error:nil];

        mark_stopped(*mailbox_);
        sink_  = nil;
        queue_ = nil;
    }

    std::unique_ptr<CapturedFrame> acquire_frame(uint32_t timeout_ms) override {
        if (!mailbox_) return nullptr;
        FrameMailbox& mb = *mailbox_;
        std::unique_lock<std::mutex> lock(mb.mutex);
        mb.cv.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                       [&] { return mb.latest || mb.stopped; });
        return std::move(mb.latest);
    }

    void set_output_size(uint32_t width, uint32_t height) override {
        out_w_ = width;
        out_h_ = height;
    }

    bool is_capturing() const override {
        return stream_ != nil && mailbox_ && !mailbox_->stopped;
    }

private:
    SCStream*                     stream_ = nil;
    Im2CaptureSink*               sink_   = nil;
    dispatch_queue_t              queue_  = nil;
    std::shared_ptr<FrameMailbox> mailbox_;
    uint32_t                      out_w_  = 0;  // 0 = native size
    uint32_t                      out_h_  = 0;
};

std::unique_ptr<IScreenCapture> create_screen_capture() {
    return std::make_unique<MacCapture>();
}

/// Virtual screens through CoreGraphics' private CGVirtualDisplay (macOS 11+,
/// what DeskPad and BetterDisplay use). The classes are looked up at run
/// time, so a macOS without them simply offers no virtual screens. A screen
/// lives as long as its CGVirtualDisplay object (and dies with the process).
class MacVirtualDisplayManager : public IVirtualDisplayManager {
public:
    ~MacVirtualDisplayManager() override { remove_all_displays(); }

    bool can_create_displays() const override {
        return NSClassFromString(@"CGVirtualDisplay") &&
               NSClassFromString(@"CGVirtualDisplayDescriptor") &&
               NSClassFromString(@"CGVirtualDisplaySettings") &&
               NSClassFromString(@"CGVirtualDisplayMode");
    }

    uint8_t create_display(const VirtualDisplayConfig& config) override {
        if (!can_create_displays()) return 0;
        int n = 0;
        while (n < protocol::MAX_VIRTUAL_DISPLAYS && displays_.count(n)) ++n;
        if (n == protocol::MAX_VIRTUAL_DISPLAYS) return 0;

        @autoreleasepool {
            CGMainDisplayID();  // connects to the WindowServer, see list_displays()
            CGVirtualDisplayDescriptor* desc =
                [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
            desc.queue         = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
            desc.name          = [NSString stringWithFormat:@"Immersive-2 Virtual %d", n + 1];
            desc.maxPixelsWide = config.width;
            desc.maxPixelsHigh = config.height;
            // About 110 dpi, so macOS picks a sensible default scale.
            desc.sizeInMillimeters = CGSizeMake(config.width * 25.4 / 110.0,
                                                config.height * 25.4 / 110.0);
            desc.vendorID  = 0x1d6b;
            desc.productID = 0x0100 + n;
            desc.serialNum = n + 1;

            CGVirtualDisplay* display =
                [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:desc];
            CGVirtualDisplayMode* mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                initWithWidth:config.width
                       height:config.height
                  refreshRate:config.refresh_rate];
            CGVirtualDisplaySettings* settings =
                [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
            settings.hiDPI = 0;
            settings.modes = @[ mode ];
            if (!display || display.displayID == 0 || ![display applySettings:settings]) {
                std::cerr << "[MacVirtual] macOS refused a " << config.width << "x"
                          << config.height << " virtual screen\n";
                return 0;
            }

            const uint8_t monitor_id = static_cast<uint8_t>(protocol::VIRTUAL_MONITOR_ID_BASE + n);
            {
                std::lock_guard<std::mutex> lock(g_virtual_mutex);
                g_virtual[display.displayID] = monitor_id;
            }
            displays_[n] = display;
            std::cout << "[MacVirtual] Virtual screen " << n + 1 << ": " << config.width << "x"
                      << config.height << " (display " << display.displayID << ")\n";
            return monitor_id;
        }
    }

    bool remove_display(uint8_t monitor_id) override {
        const auto it = displays_.find(monitor_id - protocol::VIRTUAL_MONITOR_ID_BASE);
        if (it == displays_.end()) return false;
        {
            std::lock_guard<std::mutex> lock(g_virtual_mutex);
            g_virtual.erase(it->second.displayID);
        }
        displays_.erase(it);  // releasing the object removes the screen
        std::cout << "[MacVirtual] Removed virtual screen "
                  << monitor_id - protocol::VIRTUAL_MONITOR_ID_BASE + 1 << "\n";
        return true;
    }

    void remove_all_displays() override {
        while (!displays_.empty()) {
            remove_display(
                static_cast<uint8_t>(protocol::VIRTUAL_MONITOR_ID_BASE + displays_.begin()->first));
        }
    }

    std::vector<uint8_t> get_active_displays() const override {
        std::vector<uint8_t> ids;
        for (const auto& entry : displays_) {
            ids.push_back(static_cast<uint8_t>(protocol::VIRTUAL_MONITOR_ID_BASE + entry.first));
        }
        return ids;
    }

private:
    std::map<int, CGVirtualDisplay*> displays_;  // n → display (strong, ARC)
};

std::unique_ptr<IVirtualDisplayManager> create_virtual_display_manager() {
    return std::make_unique<MacVirtualDisplayManager>();
}

}  // namespace immersive
