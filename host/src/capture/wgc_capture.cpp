/// Windows Graphics Capture backend.
///
/// Uses the Windows.Graphics.Capture WinRT API (Win10 1803+) which allows
/// concurrent capture from multiple processes — no E_ACCESSDENIED, no
/// exclusivity, works alongside AnyDesk/RustDesk/Sunshine/GlideX.
///
/// Falls back gracefully to DXGI Desktop Duplication via create_dxgi_capture()
/// if WGC is not available at runtime.

#include "capture/dxgi_capture.h"

#ifdef _WIN32

// Suppress "include winrt before windows.h" warning from MSVC headers
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

// C++/WinRT
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

// WGC interop (monitor handle → GraphicsCaptureItem)
#include <Windows.Graphics.Capture.Interop.h>

// D3D11 ↔ WinRT interop (ID3D11Device → IDirect3DDevice)
#include <windows.graphics.directx.direct3d11.interop.h>

#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <iostream>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <cstring>
#include <vector>
#include <atomic>

#pragma comment(lib, "windowsapp")

using Microsoft::WRL::ComPtr;
namespace wgc  = winrt::Windows::Graphics::Capture;
namespace wgd  = winrt::Windows::Graphics::DirectX;
namespace wgdd = winrt::Windows::Graphics::DirectX::Direct3D11;
namespace wf   = winrt::Windows::Foundation;

namespace immersive {

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Wrap a raw ID3D11Device in the WinRT IDirect3DDevice interface.
static wgdd::IDirect3DDevice create_winrt_device(ID3D11Device* d3d_device) {
    ComPtr<IDXGIDevice> dxgi_device;
    d3d_device->QueryInterface(IID_PPV_ARGS(&dxgi_device));

    winrt::com_ptr<IInspectable> inspectable;
    HRESULT hr = CreateDirect3D11DeviceFromDXGIDevice(
        dxgi_device.Get(), inspectable.put());
    if (FAILED(hr)) {
        winrt::throw_hresult(hr);
    }
    return inspectable.as<wgdd::IDirect3DDevice>();
}

/// Get the raw ID3D11Texture2D from a WinRT IDirect3DSurface.
static ComPtr<ID3D11Texture2D> get_texture(wgdd::IDirect3DSurface const& surface) {
    auto access = surface.as<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    ComPtr<ID3D11Texture2D> tex;
    winrt::check_hresult(access->GetInterface(IID_PPV_ARGS(&tex)));
    return tex;
}

// ---------------------------------------------------------------------------
// WgcCapture
// ---------------------------------------------------------------------------

class WgcCapture : public IScreenCapture {
public:
    WgcCapture() = default;
    ~WgcCapture() override { stop_capture(); }

    // ------------------------------------------------------------------
    // enumerate_displays — identical to DXGI path, also stores HMONITORs
    // ------------------------------------------------------------------
    std::vector<DisplayInfo> enumerate_displays() override {
        std::vector<DisplayInfo> displays;
        monitors_.clear();

        ComPtr<IDXGIFactory1> factory;
        if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return displays;

        ComPtr<IDXGIAdapter1> adapter;
        for (UINT ai = 0;
             factory->EnumAdapters1(ai, &adapter) != DXGI_ERROR_NOT_FOUND;
             ++ai) {
            ComPtr<IDXGIOutput> output;
            for (UINT oi = 0;
                 adapter->EnumOutputs(oi, &output) != DXGI_ERROR_NOT_FOUND;
                 ++oi) {
                DXGI_OUTPUT_DESC desc;
                output->GetDesc(&desc);

                DisplayInfo info;
                info.id     = static_cast<uint8_t>(displays.size());
                info.width  = static_cast<uint16_t>(
                    desc.DesktopCoordinates.right - desc.DesktopCoordinates.left);
                info.height = static_cast<uint16_t>(
                    desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top);
                info.refresh_rate = 60;
                info.origin_x  = desc.DesktopCoordinates.left;
                info.origin_y  = desc.DesktopCoordinates.top;
                info.is_primary = (desc.DesktopCoordinates.left == 0 &&
                                   desc.DesktopCoordinates.top  == 0);
                char name_buf[128] = {};
                WideCharToMultiByte(CP_UTF8, 0, desc.DeviceName, -1,
                                    name_buf, sizeof(name_buf), nullptr, nullptr);
                info.name = name_buf;

                displays.push_back(std::move(info));
                monitors_.push_back(desc.Monitor);
            }
        }
        return displays;
    }

    // ------------------------------------------------------------------
    // start_capture
    // ------------------------------------------------------------------
    bool start_capture(uint8_t display_id) override {
        if (capturing_) stop_capture();

        // Populate monitors_ if enumerate_displays hasn't been called yet.
        if (monitors_.empty()) enumerate_displays();

        if (display_id >= monitors_.size() || monitors_[display_id] == nullptr) {
            std::cerr << "[WgcCapture] Display " << (int)display_id << " not found\n";
            return false;
        }

        target_display_id_ = display_id;
        HMONITOR hmon = monitors_[display_id];

        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
        } catch (winrt::hresult_error const& e) {
            // Already initialized on this thread — that's fine.
            if (e.code() != static_cast<winrt::hresult>(RPC_E_CHANGED_MODE)) {
                std::cerr << "[WgcCapture] init_apartment failed: "
                          << winrt::to_string(e.message()) << "\n";
                return false;
            }
        }

        // Check WGC is supported at runtime (Win10 1803 / build 17134).
        if (!wgc::GraphicsCaptureSession::IsSupported()) {
            std::cerr << "[WgcCapture] Windows.Graphics.Capture not supported on this OS\n";
            return false;
        }

        try {
            // ---- D3D11 device (default adapter is fine for WGC — the
            //      runtime composites across adapters internally) ----
            D3D_FEATURE_LEVEL feature_level;
            HRESULT hr = D3D11CreateDevice(
                nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,   // required by WGC
                nullptr, 0, D3D11_SDK_VERSION,
                &d3d_device_, &feature_level, &d3d_context_);
            if (FAILED(hr)) {
                std::cerr << "[WgcCapture] D3D11CreateDevice failed (0x"
                          << std::hex << hr << ")\n";
                return false;
            }

            winrt_device_ = create_winrt_device(d3d_device_.Get());

            // ---- GraphicsCaptureItem for the target monitor ----
            auto interop = winrt::get_activation_factory<
                wgc::GraphicsCaptureItem,
                IGraphicsCaptureItemInterop>();

            winrt::check_hresult(interop->CreateForMonitor(
                hmon,
                winrt::guid_of<wgc::GraphicsCaptureItem>(),
                winrt::put_abi(item_)));

            capture_width_  = static_cast<uint32_t>(item_.Size().Width);
            capture_height_ = static_cast<uint32_t>(item_.Size().Height);

            // ---- Frame pool (2 slots, BGRA8, monitor resolution) ----
            // CreateFreeThreaded dispatches FrameArrived on a background thread
            // without requiring a CoreDispatcher or DispatcherQueue — mandatory
            // for plain std::thread workers that have no message pump.
            frame_pool_ = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
                winrt_device_,
                wgd::DirectXPixelFormat::B8G8R8A8UIntNormalized,
                2,
                item_.Size());

            // ---- Notify acquire_frame when a new frame arrives ----
            frame_arrived_revoker_ = frame_pool_.FrameArrived(
                winrt::auto_revoke,
                [this](auto&&, auto&&) {
                    {
                        std::lock_guard lock(frame_mutex_);
                        frame_pending_ = true;
                    }
                    frame_cv_.notify_one();
                });

            // ---- Session ----
            session_ = frame_pool_.CreateCaptureSession(item_);

            // WGC includes the hardware cursor in the captured frames by default,
            // which is what we want (Immersed-style experience shows cursor in VR).

            capturing_ = true;
            session_.StartCapture();

        } catch (winrt::hresult_error const& e) {
            std::cerr << "[WgcCapture] start_capture failed: "
                      << winrt::to_string(e.message()) << "\n";
            stop_capture();
            return false;
        }

        std::cout << "[WgcCapture] Started capture on display "
                  << (int)display_id << " ("
                  << capture_width_ << "x" << capture_height_ << ")\n";
        return true;
    }

    // ------------------------------------------------------------------
    // stop_capture
    // ------------------------------------------------------------------
    void stop_capture() override {
        if (!capturing_) return;
        capturing_ = false;

        frame_arrived_revoker_ = {};

        try { if (session_) session_.Close(); } catch (...) {}
        session_ = nullptr;

        try { if (frame_pool_) frame_pool_.Close(); } catch (...) {}
        frame_pool_ = nullptr;

        item_         = nullptr;
        winrt_device_ = nullptr;
        d3d_context_.Reset();
        d3d_device_.Reset();

        std::cout << "[WgcCapture] Stopped capture\n";
    }

    // ------------------------------------------------------------------
    // acquire_frame
    // ------------------------------------------------------------------
    std::unique_ptr<CapturedFrame> acquire_frame(uint32_t timeout_ms) override {
        if (!capturing_) return nullptr;

        // Wait for a frame signal from the FrameArrived callback.
        {
            std::unique_lock lock(frame_mutex_);
            if (!frame_cv_.wait_for(lock,
                    std::chrono::milliseconds(timeout_ms),
                    [this] { return frame_pending_ || !capturing_; })) {
                return nullptr;  // timeout
            }
            if (!capturing_) return nullptr;
            frame_pending_ = false;
        }

        wgc::Direct3D11CaptureFrame wgc_frame{nullptr};
        try {
            wgc_frame = frame_pool_.TryGetNextFrame();
        } catch (...) {}

        if (!wgc_frame) return nullptr;

        try {
            auto surface = wgc_frame.Surface();
            ComPtr<ID3D11Texture2D> src_tex = get_texture(surface);

            D3D11_TEXTURE2D_DESC src_desc;
            src_tex->GetDesc(&src_desc);

            // Staging texture for CPU readback.
            D3D11_TEXTURE2D_DESC staging_desc = src_desc;
            staging_desc.Usage          = D3D11_USAGE_STAGING;
            staging_desc.BindFlags      = 0;
            staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            staging_desc.MiscFlags      = 0;

            ComPtr<ID3D11Texture2D> staging;
            HRESULT hr = d3d_device_->CreateTexture2D(&staging_desc, nullptr, &staging);
            if (FAILED(hr)) return nullptr;

            d3d_context_->CopyResource(staging.Get(), src_tex.Get());

            D3D11_MAPPED_SUBRESOURCE mapped;
            hr = d3d_context_->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
            if (FAILED(hr)) return nullptr;

            auto frame          = std::make_unique<CapturedFrame>();
            frame->monitor_id   = target_display_id_;
            frame->width        = src_desc.Width;
            frame->height       = src_desc.Height;
            frame->pitch        = mapped.RowPitch;
            frame->timestamp_us = static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now().time_since_epoch()).count());

            const uint32_t copy_size = mapped.RowPitch * src_desc.Height;
            frame->pixels.resize(copy_size);
            std::memcpy(frame->pixels.data(), mapped.pData, copy_size);

            d3d_context_->Unmap(staging.Get(), 0);
            wgc_frame.Close();

            return frame;

        } catch (winrt::hresult_error const& e) {
            std::cerr << "[WgcCapture] acquire_frame error: "
                      << winrt::to_string(e.message()) << "\n";
            wgc_frame.Close();
            return nullptr;
        }
    }

    bool is_capturing() const override { return capturing_; }

private:
    bool    capturing_ = false;
    uint8_t target_display_id_ = 0;

    std::vector<HMONITOR> monitors_;

    ComPtr<ID3D11Device>        d3d_device_;
    ComPtr<ID3D11DeviceContext> d3d_context_;
    wgdd::IDirect3DDevice       winrt_device_{nullptr};

    wgc::GraphicsCaptureItem                          item_{nullptr};
    wgc::Direct3D11CaptureFramePool                   frame_pool_{nullptr};
    wgc::GraphicsCaptureSession                       session_{nullptr};
    wgc::Direct3D11CaptureFramePool::FrameArrived_revoker frame_arrived_revoker_;

    std::mutex              frame_mutex_;
    std::condition_variable frame_cv_;
    bool                    frame_pending_ = false;

    uint32_t capture_width_  = 0;
    uint32_t capture_height_ = 0;
};

// ---------------------------------------------------------------------------
// Factory with DXGI fallback
// ---------------------------------------------------------------------------

std::unique_ptr<IScreenCapture> create_wgc_capture() {
    return std::make_unique<WgcCapture>();
}

}  // namespace immersive

#else  // !_WIN32

namespace immersive {
std::unique_ptr<IScreenCapture> create_wgc_capture() {
    return create_dxgi_capture();  // stub: use DXGI stub on non-Windows
}
}

#endif
