/// Windows notification-area icon (Shell_NotifyIcon) on its own thread with
/// a hidden window. Left click opens the settings panel; right click shows
/// the menu. Re-added when Explorer restarts (TaskbarCreated).

#include "ui/host_ui.h"

#include <windows.h>
#include <shellapi.h>
#include <objbase.h>

#include <condition_variable>
#include <mutex>
#include <thread>

namespace immersive::ui {

namespace {

constexpr UINT kTrayMsg = WM_APP + 1;
constexpr UINT kRefresh = WM_APP + 2;
constexpr UINT_PTR kTimer = 1;
enum : UINT { kCmdOpen = 1, kCmdQuit = 2 };

std::wstring widen(const std::string& s) {
    if (s.empty()) return L"";
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
    return w;
}

/// Dark ink on a light taskbar, bone ink on a dark one.
uint32_t taskbar_ink() {
    DWORD light = 0, size = sizeof(light);
    RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                 L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size);
    return light ? 0xFF13110F : 0xFFECE6DC;
}

HICON make_icon(bool live) {
    const int size = GetSystemMetrics(SM_CXSMICON) > 0 ? GetSystemMetrics(SM_CXSMICON) : 16;
    const auto px = tray_icon_pixels(size, taskbar_ink(), live);
    BITMAPV5HEADER bi{};
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = size;
    bi.bV5Height = -size;  // top-down
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;
    void* bits = nullptr;
    HDC dc = GetDC(nullptr);
    HBITMAP color = CreateDIBSection(dc, reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS, &bits, nullptr, 0);
    ReleaseDC(nullptr, dc);
    if (!color || !bits) return nullptr;
    // Premultiplied BGRA.
    auto* out = static_cast<uint32_t*>(bits);
    for (size_t i = 0; i < px.size(); ++i) {
        const uint32_t a = px[i] >> 24;
        const uint32_t r = ((px[i] >> 16) & 0xFF) * a / 255, g = ((px[i] >> 8) & 0xFF) * a / 255,
                       b = (px[i] & 0xFF) * a / 255;
        out[i] = (a << 24) | (r << 16) | (g << 8) | b;
    }
    HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
    ICONINFO ii{};
    ii.fIcon = TRUE;
    ii.hbmColor = color;
    ii.hbmMask = mask;
    HICON icon = CreateIconIndirect(&ii);
    DeleteObject(color);
    DeleteObject(mask);
    return icon;
}

class WinTray : public Tray {
public:
    explicit WinTray(TrayModel model) : m_(std::move(model)) {}

    ~WinTray() override {
        if (hwnd_) PostMessageW(hwnd_, WM_CLOSE, 0, 0);
        if (thread_.joinable()) thread_.join();
    }

    bool init() {
        thread_ = std::thread([this] { run(); });
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait_for(lock, std::chrono::seconds(3), [this] { return started_; });
        return visible_;
    }

    bool visible() const override { return visible_; }
    void pump(std::chrono::milliseconds wait) override { std::this_thread::sleep_for(wait); }

private:
    void run() {
        // ShellExecute (opening the panel from a click) wants COM on its thread.
        CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
        const HINSTANCE inst = GetModuleHandleW(nullptr);
        WNDCLASSW wc{};
        wc.lpfnWndProc = &WinTray::proc;
        wc.hInstance = inst;
        wc.lpszClassName = L"Immersive2Tray";
        RegisterClassW(&wc);
        taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
        hwnd_ = CreateWindowExW(0, wc.lpszClassName, L"Immersive-2", WS_OVERLAPPED, 0, 0, 0, 0,
                                nullptr, nullptr, inst, this);
        if (hwnd_) {
            visible_ = add_icon();
            SetTimer(hwnd_, kTimer, 1000, nullptr);
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            started_ = true;
        }
        cv_.notify_all();
        if (!hwnd_) return;
        MSG msg;
        while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    void fill(NOTIFYICONDATAW& nid) {
        nid.cbSize = sizeof(nid);
        nid.hWnd = hwnd_;
        nid.uID = 1;
        nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
        nid.uCallbackMessage = kTrayMsg;
        live_ = m_.live();
        if (icon_) DestroyIcon(icon_);
        icon_ = make_icon(live_);
        nid.hIcon = icon_;
        tip_ = "Immersive-2: " + m_.status();
        wcsncpy_s(nid.szTip, widen(tip_).c_str(), _TRUNCATE);
    }

    bool add_icon() {
        NOTIFYICONDATAW nid{};
        fill(nid);
        if (!Shell_NotifyIconW(NIM_ADD, &nid)) return false;
        nid.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, &nid);
        return true;
    }

    void refresh() {
        if (m_.live() == live_ && "Immersive-2: " + m_.status() == tip_) return;
        NOTIFYICONDATAW nid{};
        fill(nid);
        Shell_NotifyIconW(NIM_MODIFY, &nid);
    }

    void show_menu() {
        HMENU menu = CreatePopupMenu();
        AppendMenuW(menu, MF_STRING, kCmdOpen, L"Open Immersive-2");
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, widen(m_.status()).c_str());
        AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, widen(m_.pin_line()).c_str());
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(menu, MF_STRING, kCmdQuit, L"Quit");
        SetMenuDefaultItem(menu, kCmdOpen, FALSE);
        POINT pt;
        GetCursorPos(&pt);
        SetForegroundWindow(hwnd_);  // or the menu never closes on an outside click
        const UINT cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,
                                        pt.x, pt.y, 0, hwnd_, nullptr);
        DestroyMenu(menu);
        if (cmd == kCmdOpen) m_.open();
        else if (cmd == kCmdQuit) m_.quit();
    }

    static LRESULT CALLBACK proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
        if (msg == WM_NCCREATE) {
            SetWindowLongPtrW(h, GWLP_USERDATA,
                              reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams));
        }
        auto* self = reinterpret_cast<WinTray*>(GetWindowLongPtrW(h, GWLP_USERDATA));
        if (!self) return DefWindowProcW(h, msg, wp, lp);
        if (msg == self->taskbar_created_) {  // Explorer restarted
            self->visible_ = self->add_icon();
            return 0;
        }
        switch (msg) {
        case kTrayMsg:
            // NOTIFYICON_VERSION_4: the event is in LOWORD(lParam); a click
            // arrives as NIN_SELECT (plus raw button messages, ignored here
            // so one click does not act twice).
            switch (LOWORD(lp)) {
            case NIN_SELECT:
            case NIN_KEYSELECT: self->m_.open(); break;
            case WM_CONTEXTMENU: self->show_menu(); break;
            }
            return 0;
        case WM_TIMER:
            self->refresh();
            return 0;
        case WM_CLOSE: {
            KillTimer(h, kTimer);
            NOTIFYICONDATAW nid{};
            nid.cbSize = sizeof(nid);
            nid.hWnd = h;
            nid.uID = 1;
            Shell_NotifyIconW(NIM_DELETE, &nid);
            if (self->icon_) DestroyIcon(self->icon_);
            self->icon_ = nullptr;
            DestroyWindow(h);
            return 0;
        }
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        }
        return DefWindowProcW(h, msg, wp, lp);
    }

    TrayModel m_;
    std::thread thread_;
    std::mutex mutex_;
    std::condition_variable cv_;
    bool started_ = false;
    std::atomic<bool> visible_{false};
    HWND hwnd_ = nullptr;
    HICON icon_ = nullptr;
    UINT taskbar_created_ = 0;
    bool live_ = false;
    std::string tip_;
};

}  // namespace

std::unique_ptr<Tray> create_tray(TrayModel model) {
    auto t = std::make_unique<WinTray>(std::move(model));
    t->init();  // visible() tells whether the icon made it
    return t;
}

}  // namespace immersive::ui
