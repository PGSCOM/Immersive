/// DXGI Desktop Duplication screen capture implementation.
///
/// Uses the Windows Desktop Duplication API (IDXGIOutputDuplication)
/// to capture monitor contents with minimal CPU overhead.

#include "capture/dxgi_capture.h"

#include <iostream>
#include <chrono>
#include <cstring>

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

        // Track the hardware cursor so we can composite it onto the frame.
        // DXGI Desktop Duplication delivers the desktop *without* the cursor;
        // the pointer position/shape arrive separately and only when they
        // change, so we cache them between frames.
        update_cursor_state(frame_info);

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

        // Draw the cached cursor on top of the captured desktop.
        composite_cursor(*frame);

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

    // Cached hardware-cursor state (Desktop Duplication reports it separately
    // from the desktop image and only when it changes).
    POINT                            cursor_pos_ = {0, 0};
    bool                             cursor_visible_ = false;
    DXGI_OUTDUPL_POINTER_SHAPE_INFO  cursor_info_ = {};
    std::vector<uint8_t>             cursor_shape_;

    /// Refresh the cached cursor position/visibility and shape from the frame
    /// info returned by AcquireNextFrame. Must be called while the frame is held.
    void update_cursor_state(const DXGI_OUTDUPL_FRAME_INFO& frame_info) {
        if (frame_info.LastMouseUpdateTime.QuadPart != 0) {
            cursor_visible_ = frame_info.PointerPosition.Visible != FALSE;
            cursor_pos_     = frame_info.PointerPosition.Position;
        }

        if (frame_info.PointerShapeBufferSize != 0) {
            cursor_shape_.resize(frame_info.PointerShapeBufferSize);
            UINT required = 0;
            HRESULT hr = duplication_->GetFramePointerShape(
                static_cast<UINT>(cursor_shape_.size()),
                cursor_shape_.data(), &required, &cursor_info_);
            if (FAILED(hr)) {
                cursor_shape_.clear();
            }
        }
    }

    /// Alpha-blend / mask the cached cursor onto a captured BGRA frame.
    void composite_cursor(CapturedFrame& frame) {
        if (!cursor_visible_ || cursor_shape_.empty())
            return;

        const int dst_w = static_cast<int>(frame.width);
        const int dst_h = static_cast<int>(frame.height);
        const int cur_w = static_cast<int>(cursor_info_.Width);
        const int cur_h = static_cast<int>(cursor_info_.Height);
        const int ox    = cursor_pos_.x;
        const int oy    = cursor_pos_.y;
        uint8_t* dst    = frame.pixels.data();
        const uint32_t pitch = frame.pitch;

        if (cursor_info_.Type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR) {
            for (int cy = 0; cy < cur_h; ++cy) {
                const int sy = oy + cy;
                if (sy < 0 || sy >= dst_h) continue;
                const uint8_t* src_row = cursor_shape_.data() + cy * cursor_info_.Pitch;
                for (int cx = 0; cx < cur_w; ++cx) {
                    const int sx = ox + cx;
                    if (sx < 0 || sx >= dst_w) continue;
                    const uint8_t* s = src_row + cx * 4;  // BGRA
                    const int a = s[3];
                    if (a == 0) continue;
                    uint8_t* d = dst + sy * pitch + sx * 4;
                    d[0] = static_cast<uint8_t>((s[0] * a + d[0] * (255 - a)) / 255);
                    d[1] = static_cast<uint8_t>((s[1] * a + d[1] * (255 - a)) / 255);
                    d[2] = static_cast<uint8_t>((s[2] * a + d[2] * (255 - a)) / 255);
                    d[3] = 255;
                }
            }
        } else if (cursor_info_.Type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR) {
            // 32-bit pixels; alpha byte selects copy (0x00) vs XOR with screen (0xFF).
            for (int cy = 0; cy < cur_h; ++cy) {
                const int sy = oy + cy;
                if (sy < 0 || sy >= dst_h) continue;
                const uint8_t* src_row = cursor_shape_.data() + cy * cursor_info_.Pitch;
                for (int cx = 0; cx < cur_w; ++cx) {
                    const int sx = ox + cx;
                    if (sx < 0 || sx >= dst_w) continue;
                    const uint8_t* s = src_row + cx * 4;
                    uint8_t* d = dst + sy * pitch + sx * 4;
                    if (s[3] == 0) {
                        d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 255;
                    } else {
                        d[0] ^= s[0]; d[1] ^= s[1]; d[2] ^= s[2]; d[3] = 255;
                    }
                }
            }
        } else if (cursor_info_.Type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME) {
            // Two stacked 1-bpp masks: top = AND, bottom = XOR. Real height is half.
            const int real_h = cur_h / 2;
            const uint32_t mask_pitch = cursor_info_.Pitch;
            const uint8_t* and_mask = cursor_shape_.data();
            const uint8_t* xor_mask = cursor_shape_.data() + real_h * mask_pitch;
            for (int cy = 0; cy < real_h; ++cy) {
                const int sy = oy + cy;
                if (sy < 0 || sy >= dst_h) continue;
                for (int cx = 0; cx < cur_w; ++cx) {
                    const int sx = ox + cx;
                    if (sx < 0 || sx >= dst_w) continue;
                    const uint8_t and_bit =
                        (and_mask[cy * mask_pitch + (cx / 8)] >> (7 - (cx % 8))) & 1;
                    const uint8_t xor_bit =
                        (xor_mask[cy * mask_pitch + (cx / 8)] >> (7 - (cx % 8))) & 1;
                    uint8_t* d = dst + sy * pitch + sx * 4;
                    if (and_bit == 0) {
                        const uint8_t c = xor_bit ? 255 : 0;  // white / black
                        d[0] = c; d[1] = c; d[2] = c; d[3] = 255;
                    } else if (xor_bit) {
                        d[0] = static_cast<uint8_t>(~d[0]);
                        d[1] = static_cast<uint8_t>(~d[1]);
                        d[2] = static_cast<uint8_t>(~d[2]);
                        d[3] = 255;
                    }
                    // and_bit==1 && xor_bit==0 -> transparent (leave dst)
                }
            }
        }
    }
#endif
    uint32_t capture_width_ = 0;
    uint32_t capture_height_ = 0;
};

std::unique_ptr<IScreenCapture> create_dxgi_capture() {
    return std::make_unique<DxgiCapture>();
}

}  // namespace immersive
