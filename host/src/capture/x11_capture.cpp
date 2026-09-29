/// X11 screen capture: RandR monitors, MIT-SHM grabs of the root window,
/// XFixes cursor composited on top.
///
/// Each instance owns its own Display connection (the stream workers run one
/// capture per thread), so no Xlib locking is shared between monitors.

#include "capture/linux_backends.h"

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#include <X11/extensions/Xfixes.h>
#include <X11/extensions/Xrandr.h>
#include <sys/ipc.h>
#include <sys/shm.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <thread>

namespace immersive {

namespace {

/// Xlib's default error handler exits the process. A monitor unplugged
/// between enumerate and grab (BadMatch) must fail one grab, not kill the
/// host, so errors are only logged.
int on_x_error(Display* dpy, XErrorEvent* ev) {
    char text[128] = {};
    XGetErrorText(dpy, ev->error_code, text, sizeof(text));
    std::cerr << "[X11] Error: " << text << " (request " << (int)ev->request_code << ")\n";
    return 0;
}

}  // namespace

void init_xlib_once() {
    static std::once_flag once;
    std::call_once(once, [] {
        XInitThreads();
        XSetErrorHandler(on_x_error);
    });
}

namespace {

struct Rect { int x, y, w, h; };

/// Monitors in RandR order, primary flagged. Falls back to the whole root
/// window when RandR has nothing (Xvfb without outputs, old servers).
std::vector<DisplayInfo> query_monitors(Display* dpy) {
    std::vector<DisplayInfo> out;
    const Window root = DefaultRootWindow(dpy);

    int ev_base = 0, err_base = 0, count = 0;
    XRRMonitorInfo* mons = nullptr;
    if (XRRQueryExtension(dpy, &ev_base, &err_base)) {
        mons = XRRGetMonitors(dpy, root, True, &count);
    }
    for (int i = 0; mons && i < count && out.size() < 255; ++i) {
        DisplayInfo d;
        d.id           = static_cast<uint8_t>(out.size());
        d.width        = static_cast<uint16_t>(mons[i].width);
        d.height       = static_cast<uint16_t>(mons[i].height);
        d.refresh_rate = 60;
        d.origin_x     = mons[i].x;
        d.origin_y     = mons[i].y;
        d.is_primary   = mons[i].primary != 0;
        d.native_id    = static_cast<uint32_t>(i);
        char* name = mons[i].name ? XGetAtomName(dpy, mons[i].name) : nullptr;
        d.name = name ? name : "X11 Monitor " + std::to_string(i);
        if (name) XFree(name);
        if (d.width > 0 && d.height > 0) out.push_back(d);
    }
    if (mons) XRRFreeMonitors(mons);

    if (out.empty()) {
        XWindowAttributes attr{};
        XGetWindowAttributes(dpy, root, &attr);
        DisplayInfo d;
        d.id = 0; d.width = static_cast<uint16_t>(attr.width);
        d.height = static_cast<uint16_t>(attr.height);
        d.refresh_rate = 60; d.origin_x = 0; d.origin_y = 0;
        d.is_primary = true; d.name = "X11 Screen";
        out.push_back(d);
    }
    return out;
}

uint64_t now_us() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

class X11Capture : public IScreenCapture {
public:
    explicit X11Capture(Display* dpy) : dpy_(dpy) {}

    ~X11Capture() override {
        stop_capture();
        XCloseDisplay(dpy_);
    }

    std::vector<DisplayInfo> enumerate_displays() override {
        return query_monitors(dpy_);
    }

    bool start_capture(uint8_t display_id) override {
        stop_capture();

        // Re-query: the layout may have changed since startup (and this is
        // also the restart path after a failed grab).
        auto displays = query_monitors(dpy_);
        if (display_id >= displays.size()) {
            std::cerr << "[X11Capture] Display " << (int)display_id << " not found\n";
            return false;
        }
        const auto& d = displays[display_id];
        rect_ = {d.origin_x, d.origin_y, d.width, d.height};
        display_id_ = display_id;

        const int screen = DefaultScreen(dpy_);
        Visual* visual = DefaultVisual(dpy_, screen);
        const int depth = DefaultDepth(dpy_, screen);
        // Byte order B,G,R,X in memory is what CapturedFrame wants; that is
        // the 24/32-bit TrueColor layout on every little-endian server.
        if ((depth != 24 && depth != 32) || visual->red_mask != 0xFF0000 ||
            visual->green_mask != 0x00FF00 || visual->blue_mask != 0x0000FF) {
            std::cerr << "[X11Capture] Unsupported visual (depth " << depth
                      << "), need 24/32-bit BGRX\n";
            return false;
        }

        use_shm_ = XShmQueryExtension(dpy_);
        if (use_shm_) {
            image_ = XShmCreateImage(dpy_, visual, depth, ZPixmap, nullptr, &shm_,
                                     rect_.w, rect_.h);
            if (image_) {
                shm_.shmid = shmget(IPC_PRIVATE,
                                    static_cast<size_t>(image_->bytes_per_line) * image_->height,
                                    IPC_CREAT | 0600);
                shm_.shmaddr = image_->data =
                    (shm_.shmid >= 0) ? static_cast<char*>(shmat(shm_.shmid, nullptr, 0))
                                      : reinterpret_cast<char*>(-1);
                shm_.readOnly = False;
                // Attach can fail on a remote display (ssh -X): no shared
                // memory there, fall back to XGetImage.
                if (shm_.shmaddr != reinterpret_cast<char*>(-1) && XShmAttach(dpy_, &shm_)) {
                    XSync(dpy_, False);
                    // Marked for removal now so the segment cannot leak if
                    // the host is killed; it lives until the last detach.
                    shmctl(shm_.shmid, IPC_RMID, nullptr);
                    shm_attached_ = true;
                } else {
                    release_shm();
                    use_shm_ = false;
                }
            } else {
                use_shm_ = false;
            }
        }

        int ev = 0, err = 0;
        has_xfixes_ = XFixesQueryExtension(dpy_, &ev, &err);

        capturing_ = true;
        failures_ = 0;
        last_grab_ = {};
        std::cout << "[X11Capture] Started capture on display " << (int)display_id
                  << " (" << rect_.w << "x" << rect_.h << " at " << rect_.x << ","
                  << rect_.y << (use_shm_ ? ", MIT-SHM" : ", XGetImage") << ")\n";
        return true;
    }

    void stop_capture() override {
        if (!capturing_ && !image_) return;
        capturing_ = false;
        release_shm();
    }

    std::unique_ptr<CapturedFrame> acquire_frame(uint32_t timeout_ms) override {
        if (!capturing_) return nullptr;

        // X11 has no "new frame" event: grab at most once per timeout_ms
        // instead of as fast as the caller loops.
        // ponytail: fixed-rate polling; XDamage could skip unchanged frames.
        const auto interval = std::chrono::milliseconds(std::max(1u, timeout_ms));
        const auto now = std::chrono::steady_clock::now();
        if (now - last_grab_ < interval) {
            std::this_thread::sleep_for(interval - (now - last_grab_));
        }
        last_grab_ = std::chrono::steady_clock::now();

        const Window root = DefaultRootWindow(dpy_);
        XImage* img = nullptr;
        bool ok;
        if (use_shm_) {
            ok = XShmGetImage(dpy_, root, image_, rect_.x, rect_.y, AllPlanes);
            img = image_;
        } else {
            img = XGetImage(dpy_, root, rect_.x, rect_.y, rect_.w, rect_.h,
                            AllPlanes, ZPixmap);
            ok = img != nullptr;
        }
        if (!ok || img->bits_per_pixel != 32) {
            if (img && img != image_) XDestroyImage(img);
            // A grab outside the root (monitor unplugged, resolution
            // lowered) fails every time: stop so main.cpp restarts us with
            // the new layout instead of retrying forever.
            if (++failures_ >= 10) {
                std::cerr << "[X11Capture] Grab keeps failing, restarting capture\n";
                stop_capture();
            }
            return nullptr;
        }
        failures_ = 0;

        auto frame = std::make_unique<CapturedFrame>();
        frame->monitor_id   = display_id_;
        frame->width        = static_cast<uint32_t>(img->width);
        frame->height       = static_cast<uint32_t>(img->height);
        frame->pitch        = static_cast<uint32_t>(img->bytes_per_line);
        frame->timestamp_us = now_us();
        frame->pixels.assign(img->data,
                             img->data + static_cast<size_t>(img->bytes_per_line) * img->height);
        if (img != image_) XDestroyImage(img);

        if (has_xfixes_) composite_cursor(*frame);
        return frame;
    }

    bool is_capturing() const override { return capturing_; }

private:
    void release_shm() {
        if (shm_attached_) {
            XShmDetach(dpy_, &shm_);
            XSync(dpy_, False);
            shm_attached_ = false;
        }
        if (shm_.shmaddr && shm_.shmaddr != reinterpret_cast<char*>(-1)) {
            shmdt(shm_.shmaddr);
        }
        if (shm_.shmid >= 0) {
            shmctl(shm_.shmid, IPC_RMID, nullptr);  // no-op if already removed
        }
        shm_ = {};
        shm_.shmid = -1;
        if (image_) {
            image_->data = nullptr;  // shm memory, not malloc'd
            XDestroyImage(image_);
            image_ = nullptr;
        }
    }

    /// The root-window grab does not include the pointer; XFixes gives its
    /// image (premultiplied ARGB in `unsigned long`s) and position.
    void composite_cursor(CapturedFrame& frame) {
        XFixesCursorImage* cur = XFixesGetCursorImage(dpy_);
        if (!cur) return;
        const int ox = cur->x - cur->xhot - rect_.x;
        const int oy = cur->y - cur->yhot - rect_.y;
        for (int cy = 0; cy < cur->height; ++cy) {
            const int y = oy + cy;
            if (y < 0 || y >= static_cast<int>(frame.height)) continue;
            uint8_t* row = frame.pixels.data() + static_cast<size_t>(y) * frame.pitch;
            for (int cx = 0; cx < cur->width; ++cx) {
                const int x = ox + cx;
                if (x < 0 || x >= static_cast<int>(frame.width)) continue;
                const uint32_t p = static_cast<uint32_t>(cur->pixels[cy * cur->width + cx]);
                const uint32_t a = p >> 24;
                if (a == 0) continue;
                uint8_t* d = row + x * 4;
                // Premultiplied: out = src + dst * (1 - a)
                d[0] = static_cast<uint8_t>((p & 0xFF) + d[0] * (255 - a) / 255);
                d[1] = static_cast<uint8_t>(((p >> 8) & 0xFF) + d[1] * (255 - a) / 255);
                d[2] = static_cast<uint8_t>(((p >> 16) & 0xFF) + d[2] * (255 - a) / 255);
            }
        }
        XFree(cur);
    }

    Display*        dpy_;
    Rect            rect_{};
    uint8_t         display_id_ = 0;
    bool            capturing_ = false;
    bool            use_shm_ = false;
    bool            shm_attached_ = false;
    bool            has_xfixes_ = false;
    int             failures_ = 0;
    XImage*         image_ = nullptr;
    XShmSegmentInfo shm_{0, -1, nullptr, False};
    std::chrono::steady_clock::time_point last_grab_{};
};

}  // namespace

std::unique_ptr<IScreenCapture> create_x11_capture() {
    init_xlib_once();
    Display* dpy = XOpenDisplay(nullptr);
    if (!dpy) {
        std::cerr << "[X11Capture] Cannot open X display \""
                  << (std::getenv("DISPLAY") ? std::getenv("DISPLAY") : "") << "\"\n";
        return nullptr;
    }
    return std::make_unique<X11Capture>(dpy);
}

}  // namespace immersive
