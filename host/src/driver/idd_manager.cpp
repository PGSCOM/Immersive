/// IDD Virtual Display Manager implementation.
///
/// Manages virtual displays created via the Windows Indirect Display Driver (IDD)
/// framework.
///
/// This module detects whether the itsmikethetech Virtual-Display-Driver
/// (https://github.com/itsmikethetech/Virtual-Display-Driver) is installed
/// by searching the SetupAPI device list for a device matching the
/// hardware ID prefix "Root\VID_IDD" or the friendly name "Virtual Display".
///
/// If the driver is present, future versions of Immersive-2 will communicate
/// with the driver via DeviceIoControl to create/destroy virtual monitors.
/// Until then, this module acts as a detection stub.

#include "driver/idd_manager.h"
#include <algorithm>
#include <iostream>

#ifdef _WIN32
#include <windows.h>
#include <setupapi.h>
#include <devguid.h>
#pragma comment(lib, "setupapi.lib")
#endif

namespace immersive {

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

#ifdef _WIN32
/// Returns true if a device matching the given hardware-ID prefix is installed.
static bool device_present_by_hwid(const wchar_t* hwid_prefix) {
    HDEVINFO dev_info = SetupDiGetClassDevsW(
        nullptr, nullptr, nullptr,
        DIGCF_ALLCLASSES | DIGCF_PRESENT);

    if (dev_info == INVALID_HANDLE_VALUE) return false;

    SP_DEVINFO_DATA dev_data = {};
    dev_data.cbSize = sizeof(dev_data);

    bool found = false;
    for (DWORD i = 0; SetupDiEnumDeviceInfo(dev_info, i, &dev_data); ++i) {
        wchar_t hw_buf[512] = {};
        if (!SetupDiGetDeviceRegistryPropertyW(dev_info, &dev_data,
                SPDRP_HARDWAREID, nullptr,
                reinterpret_cast<PBYTE>(hw_buf), sizeof(hw_buf) - 2, nullptr)) {
            continue;
        }

        // hw_buf is a REG_MULTI_SZ — iterate the null-terminated strings
        const wchar_t* p = hw_buf;
        while (*p != L'\0') {
            if (wcsncmp(p, hwid_prefix, wcslen(hwid_prefix)) == 0) {
                found = true;
                break;
            }
            p += wcslen(p) + 1;
        }
        if (found) break;
    }

    SetupDiDestroyDeviceInfoList(dev_info);
    return found;
}

/// Returns true if a device with "Virtual Display" in its friendly name is present.
static bool virtual_display_by_friendly_name() {
    HDEVINFO dev_info = SetupDiGetClassDevsW(
        &GUID_DEVCLASS_MONITOR, nullptr, nullptr,
        DIGCF_PRESENT);

    if (dev_info == INVALID_HANDLE_VALUE) return false;

    SP_DEVINFO_DATA dev_data = {};
    dev_data.cbSize = sizeof(dev_data);

    bool found = false;
    for (DWORD i = 0; SetupDiEnumDeviceInfo(dev_info, i, &dev_data); ++i) {
        wchar_t name_buf[256] = {};
        if (!SetupDiGetDeviceRegistryPropertyW(dev_info, &dev_data,
                SPDRP_FRIENDLYNAME, nullptr,
                reinterpret_cast<PBYTE>(name_buf), sizeof(name_buf) - 2, nullptr)) {
            continue;
        }

        // Case-insensitive search for "virtual"
        wchar_t lower[256] = {};
        for (int j = 0; j < 255 && name_buf[j]; ++j)
            lower[j] = towlower(name_buf[j]);

        if (wcsstr(lower, L"virtual") != nullptr) {
            found = true;
            break;
        }
    }

    SetupDiDestroyDeviceInfoList(dev_info);
    return found;
}
#endif  // _WIN32

// ---------------------------------------------------------------------------
// VirtualDisplayManagerImpl
// ---------------------------------------------------------------------------

class VirtualDisplayManagerImpl : public IVirtualDisplayManager {
public:
    bool is_driver_installed() const override {
#ifdef _WIN32
        // 1. Check for the itsmikethetech VDD hardware ID prefix
        if (device_present_by_hwid(L"Root\\VID_IDD")) {
            std::cout << "[IDDManager] Detected itsmikethetech Virtual-Display-Driver\n";
            return true;
        }

        // 2. Broader check: any installed device whose friendly name contains "virtual"
        //    in the Monitor device class (catches other VDD variants)
        if (virtual_display_by_friendly_name()) {
            std::cout << "[IDDManager] Detected a virtual display device via friendly name\n";
            return true;
        }

        std::cout << "[IDDManager] No IDD virtual display driver detected\n"
                  << "             See docs/IDD_DRIVER.md for installation instructions\n";
        return false;
#else
        std::cout << "[IDDManager] IDD driver check only supported on Windows\n";
        return false;
#endif
    }

    uint8_t create_display(const VirtualDisplayConfig& config) override {
        if (!is_driver_installed()) {
            std::cerr << "[IDDManager] IDD driver not installed. "
                      << "Virtual displays are not available.\n"
                      << "Tip: See docs/IDD_DRIVER.md for installation instructions.\n";
            return 0;
        }

        // TODO: Communicate with the IDD driver to create a virtual display.
        // This will use DeviceIoControl or a custom user-mode interface
        // to the kernel-mode IDD driver.

        uint8_t id = next_id_++;
        active_displays_.push_back(id);

        std::cout << "[IDDManager] Created virtual display " << (int)id
                  << " (" << config.width << "x" << config.height
                  << " @ " << (int)config.refresh_rate << " Hz)\n";

        return id;
    }

    bool remove_display(uint8_t display_id) override {
        auto it = std::find(active_displays_.begin(), active_displays_.end(), display_id);
        if (it == active_displays_.end()) return false;

        // TODO: Tell the IDD driver to remove this display
        active_displays_.erase(it);

        std::cout << "[IDDManager] Removed virtual display " << (int)display_id << "\n";
        return true;
    }

    void remove_all_displays() override {
        for (auto id : active_displays_) {
            std::cout << "[IDDManager] Removing virtual display " << (int)id << "\n";
        }
        active_displays_.clear();
    }

    std::vector<uint8_t> get_active_displays() const override {
        return active_displays_;
    }

private:
    uint8_t              next_id_ = 1;
    std::vector<uint8_t> active_displays_;
};

std::unique_ptr<IVirtualDisplayManager> create_virtual_display_manager() {
    return std::make_unique<VirtualDisplayManagerImpl>();
}

}  // namespace immersive
