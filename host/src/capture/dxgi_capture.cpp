/// DXGI Desktop Duplication screen capture implementation.
///
/// Uses the Windows Desktop Duplication API (IDXGIOutputDuplication)
/// to capture monitor contents with minimal CPU overhead.

#include "capture/dxgi_capture.h"

#include <iostream>
#include <chrono>

#ifdef _WIN32
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
using Microsoft::WRL::ComPtr;
#endif

namespace immersive {

class DxgiCapture : public IScreenCapture {
public:
    DxgiCapture() = default;
    ~DxgiCapture() override { stop_capture(); }

    std::vector<DisplayInfo> enumerate_displays() override {
        std::vector<DisplayInfo> displays;

#ifdef _WIN32
        ComPtr<IDXGIFactory1> factory;
        if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
            std::cerr << "[DxgiCapture] Failed to create DXGI factory\n";
            return displays;
        }

        ComPtr<IDXGIAdapter1> adapter;
        for (UINT adapter_idx = 0;
             factory->EnumAdapters1(adapter_idx, &adapter) != DXGI_ERROR_NOT_FOUND;
             ++adapter_idx) {

            ComPtr<IDXGIOutput> output;
            for (UINT output_idx = 0;
                 adapter->EnumOutputs(output_idx, &output) != DXGI_ERROR_NOT_FOUND;
                 ++output_idx) {

                DXGI_OUTPUT_DESC desc;
                output->GetDesc(&desc);

                DisplayInfo info;
                info.id = static_cast<uint8_t>(displays.size());
                info.width = static_cast<uint16_t>(
                    desc.DesktopCoordinates.right - desc.DesktopCoordinates.left);
                info.height = static_cast<uint16_t>(
                    desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top);
                info.refresh_rate = 60;  // Default; can query via mode enumeration
                info.origin_x = static_cast<int32_t>(desc.DesktopCoordinates.left);
                info.origin_y = static_cast<int32_t>(desc.DesktopCoordinates.top);
                info.is_primary = (desc.DesktopCoordinates.left == 0 &&
                                   desc.DesktopCoordinates.top == 0);

                // Convert wide name to UTF-8
                char name_buf[128] = {};
                WideCharToMultiByte(CP_UTF8, 0, desc.DeviceName, -1,
                                    name_buf, sizeof(name_buf), nullptr, nullptr);
                info.name = name_buf;

                displays.push_back(std::move(info));
            }
        }
#else
        // Stub for non-Windows platforms (development only)
        DisplayInfo stub;
        stub.id = 0;
        stub.width = 1920;
        stub.height = 1080;
        stub.refresh_rate = 60;
        stub.origin_x = 0;
        stub.origin_y = 0;
        stub.name = "Stub Display (non-Windows)";
        stub.is_primary = true;
        displays.push_back(stub);
#endif

        return displays;
    }

    bool start_capture(uint8_t display_id) override {
        if (capturing_) {
            stop_capture();
        }

        target_display_id_ = display_id;
        capturing_ = true;

#ifdef _WIN32
        // Create D3D11 device
        D3D_FEATURE_LEVEL feature_level;
        HRESULT hr = D3D11CreateDevice(
            nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
            0, nullptr, 0, D3D11_SDK_VERSION,
            &d3d_device_, &feature_level, &d3d_context_);

        if (FAILED(hr)) {
            std::cerr << "[DxgiCapture] Failed to create D3D11 device\n";
            capturing_ = false;
            return false;
        }

        // Get the DXGI output for the target display
        ComPtr<IDXGIDevice> dxgi_device;
        d3d_device_.As(&dxgi_device);

        ComPtr<IDXGIAdapter> adapter;
        dxgi_device->GetAdapter(&adapter);

        ComPtr<IDXGIOutput> output;
        ComPtr<IDXGIOutput1> output1;

        UINT current_id = 0;
        bool found = false;
        for (UINT i = 0; adapter->EnumOutputs(i, &output) != DXGI_ERROR_NOT_FOUND; ++i) {
            if (current_id == display_id) {
                output.As(&output1);
                found = true;
                break;
            }
            current_id++;
        }

        if (!found || !output1) {
            std::cerr << "[DxgiCapture] Display " << (int)display_id << " not found\n";
            capturing_ = false;
            return false;
        }

        hr = output1->DuplicateOutput(d3d_device_.Get(), &duplication_);
        if (FAILED(hr)) {
            std::cerr << "[DxgiCapture] Failed to duplicate output (0x"
                      << std::hex << hr << ")\n";
            capturing_ = false;
            return false;
        }

        DXGI_OUTPUT_DESC desc;
        output->GetDesc(&desc);
        capture_width_ = desc.DesktopCoordinates.right - desc.DesktopCoordinates.left;
        capture_height_ = desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top;
#endif

        std::cout << "[DxgiCapture] Started capture on display " << (int)display_id << "\n";
        return true;
    }

    void stop_capture() override {
        if (!capturing_) return;
        capturing_ = false;

#ifdef _WIN32
        duplication_.Reset();
        d3d_context_.Reset();
        d3d_device_.Reset();
#endif

        std::cout << "[DxgiCapture] Stopped capture\n";
    }

    std::unique_ptr<CapturedFrame> acquire_frame(uint32_t timeout_ms) override {
        if (!capturing_) return nullptr;

#ifdef _WIN32
        if (!duplication_) return nullptr;

        ComPtr<IDXGIResource> desktop_resource;
        DXGI_OUTDUPL_FRAME_INFO frame_info;

        HRESULT hr = duplication_->AcquireNextFrame(
            timeout_ms, &frame_info, &desktop_resource);

        if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
            return nullptr;
        }
        if (FAILED(hr)) {
            // Output may have been reconfigured; try to reinitialize
            std::cerr << "[DxgiCapture] AcquireNextFrame failed (0x"
                      << std::hex << hr << "), reinitializing\n";
            stop_capture();
            start_capture(target_display_id_);
            return nullptr;
        }

        // Map the desktop texture to CPU-accessible memory
        ComPtr<ID3D11Texture2D> desktop_texture;
        desktop_resource.As(&desktop_texture);

        D3D11_TEXTURE2D_DESC tex_desc;
        desktop_texture->GetDesc(&tex_desc);

        // Create a staging texture for CPU read
        tex_desc.Usage = D3D11_USAGE_STAGING;
        tex_desc.BindFlags = 0;
        tex_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        tex_desc.MiscFlags = 0;

        ComPtr<ID3D11Texture2D> staging;
        d3d_device_->CreateTexture2D(&tex_desc, nullptr, &staging);
        d3d_context_->CopyResource(staging.Get(), desktop_texture.Get());

        D3D11_MAPPED_SUBRESOURCE mapped;
        hr = d3d_context_->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);

        if (FAILED(hr)) {
            duplication_->ReleaseFrame();
            return nullptr;
        }

        auto frame = std::make_unique<CapturedFrame>();
        frame->monitor_id = target_display_id_;
        frame->width = tex_desc.Width;
        frame->height = tex_desc.Height;
        frame->pitch = mapped.RowPitch;

        // Copy pixel data
        uint32_t data_size = mapped.RowPitch * tex_desc.Height;
        frame->pixels.resize(data_size);
        std::memcpy(frame->pixels.data(), mapped.pData, data_size);

        auto now = std::chrono::steady_clock::now();
        frame->timestamp_us = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                now.time_since_epoch()).count());

        d3d_context_->Unmap(staging.Get(), 0);
        duplication_->ReleaseFrame();

        return frame;
#else
        // Non-Windows stub: generate a solid-color test frame
        auto frame = std::make_unique<CapturedFrame>();
        frame->monitor_id = target_display_id_;
        frame->width = 1920;
        frame->height = 1080;
        frame->pitch = frame->width * 4;
        frame->pixels.resize(frame->pitch * frame->height, 128);

        auto now = std::chrono::steady_clock::now();
        frame->timestamp_us = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                now.time_since_epoch()).count());
        return frame;
#endif
    }

    bool is_capturing() const override { return capturing_; }

private:
    bool    capturing_ = false;
    uint8_t target_display_id_ = 0;

#ifdef _WIN32
    ComPtr<ID3D11Device>          d3d_device_;
    ComPtr<ID3D11DeviceContext>   d3d_context_;
    ComPtr<IDXGIOutputDuplication> duplication_;
#endif
    uint32_t capture_width_ = 0;
    uint32_t capture_height_ = 0;
};

std::unique_ptr<IScreenCapture> create_dxgi_capture() {
    return std::make_unique<DxgiCapture>();
}

}  // namespace immersive
