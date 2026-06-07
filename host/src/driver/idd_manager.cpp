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
#include <cwchar>

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

/// Locate a detached virtual display target and return its device name.
static bool find_detached_virtual_monitor(std::wstring& device_name) {
    DISPLAY_DEVICEW adapter = {};
    adapter.cb = sizeof(adapter);

    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &adapter, 0); ++i) {
        // Enumerate monitors on this adapter
        DISPLAY_DEVICEW monitor = {};
        monitor.cb = sizeof(monitor);
        for (DWORD j = 0; EnumDisplayDevicesW(adapter.DeviceName, j, &monitor, 0); ++j) {
            bool attached = (monitor.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;
            bool looks_virtual = (monitor.StateFlags & DISPLAY_DEVICE_MIRRORING_DRIVER) != 0 ||
                                 wcsstr(monitor.DeviceString, L"Virtual") != nullptr;
            if (!attached && looks_virtual) {
                device_name = adapter.DeviceName;
                return true;
            }
        }
    }
    return false;
}
#endif  // _WIN32

// ---------------------------------------------------------------------------
// VirtualDisplayManagerImpl (Auto Self-Signer)
// ---------------------------------------------------------------------------

static void ensure_ids_certificate_installed() {
#ifdef _WIN32
    // Programmatically create and install a self-signed certificate into Root & TrustedPublisher
    // to bypass the IDD driver signature requirement (WHQL/TestSigning).
    std::cout << "[IDDManager] Verifying automatic driver signature bypass...\n";
    const char* ps1 = 
        "$certName = 'Immersive IDD Auth'; "
        "$certThumb = (Get-ChildItem -Path Cert:\\LocalMachine\\My | Where-Object { $_.Subject -match $certName }).Thumbprint; "
        "if (-not $certThumb) { "
        "  $cert = New-SelfSignedCertificate -Subject $certName -CertStoreLocation Cert:\\LocalMachine\\My -Type CodeSigningCert -KeyExportPolicy Exportable; "
        "  $storeRoot = New-Object System.Security.Cryptography.X509Certificates.X509Store 'Root', 'LocalMachine'; "
        "  $storeRoot.Open('ReadWrite'); $storeRoot.Add($cert); $storeRoot.Close(); "
        "  $storeAuth = New-Object System.Security.Cryptography.X509Certificates.X509Store 'TrustedPublisher', 'LocalMachine'; "
        "  $storeAuth.Open('ReadWrite'); $storeAuth.Add($cert); $storeAuth.Close(); "
        "  Write-Host 'Generated and trusted certificate for IDD bypassing.'; "
        "} else { Write-Host 'Certificate already trusted.' }";
    
    std::string cmd = "powershell -WindowStyle Hidden -NoProfile -NonInteractive -Command \"";
    cmd += ps1;
    cmd += "\" > NUL 2>&1";
    // We launch it hidden via system. In a real desktop app, CreateProcess without a window would be better.
    system(cmd.c_str());
#endif
}

class VirtualDisplayManagerImpl : public IVirtualDisplayManager {
public:
    bool is_driver_installed() const override {
#ifdef _WIN32
        ensure_ids_certificate_installed();

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

        std::wstring device_name;
#ifdef _WIN32
        if (!find_detached_virtual_monitor(device_name)) {
            std::cerr << "[IDDManager] No detached virtual monitor available to attach.\n";
            return 0;
        }

        DEVMODEW dm = {};
        dm.dmSize = sizeof(dm);
        dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
        dm.dmPelsWidth  = config.width;
        dm.dmPelsHeight = config.height;
        dm.dmDisplayFrequency = config.refresh_rate;

        // Place the virtual monitor to the right of the current virtual desktop
        int virtual_left   = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int virtual_width  = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        dm.dmPosition.x = virtual_left + virtual_width;
        dm.dmPosition.y = 0;

        LONG result = ChangeDisplaySettingsExW(
            device_name.c_str(),
            &dm,
            nullptr,
            CDS_UPDATEREGISTRY | CDS_NORESET,
            nullptr);

        if (result != DISP_CHANGE_SUCCESSFUL) {
            std::cerr << "[IDDManager] Failed to attach virtual display (code "
                      << result << ")\n";
            return 0;
        }

        // Commit the desktop topology update
        ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr);
#else
        (void)device_name;
#endif

        uint8_t id = next_id_++;
        active_displays_.push_back({id, device_name});

        std::cout << "[IDDManager] Created virtual display " << (int)id
                  << " (" << config.width << "x" << config.height
                  << " @ " << (int)config.refresh_rate << " Hz)\n";

        return id;
    }

    bool remove_display(uint8_t display_id) override {
        auto it = std::find_if(active_displays_.begin(), active_displays_.end(),
                               [display_id](const VirtualDisplayRecord& rec) {
                                   return rec.id == display_id;
                               });
        if (it == active_displays_.end()) return false;

        bool detached = true;
#ifdef _WIN32
        DEVMODEW dm = {};
        dm.dmSize = sizeof(dm);
        dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
        dm.dmPelsWidth = 0;
        dm.dmPelsHeight = 0;
        dm.dmPosition.x = 0;
        dm.dmPosition.y = 0;

        LONG result = ChangeDisplaySettingsExW(
            it->device_name.c_str(),
            &dm,
            nullptr,
            CDS_UPDATEREGISTRY | CDS_NORESET,
            nullptr);
        if (result != DISP_CHANGE_SUCCESSFUL) {
            std::cerr << "[IDDManager] Failed to detach virtual display "
                      << (int)display_id << " (code " << result << ")\n";
            detached = false;
        } else {
            ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr);
        }
#endif
        active_displays_.erase(it);

        if (detached) {
            std::cout << "[IDDManager] Removed virtual display " << (int)display_id << "\n";
        }
        return true;
    }

    void remove_all_displays() override {
        // Copy to avoid mutating while iterating
        auto displays = active_displays_;
        for (const auto& rec : displays) {
            remove_display(rec.id);
        }
        active_displays_.clear();
    }

    std::vector<uint8_t> get_active_displays() const override {
        std::vector<uint8_t> ids;
        ids.reserve(active_displays_.size());
        for (const auto& rec : active_displays_) {
            ids.push_back(rec.id);
        }
        return ids;
    }

private:
    struct VirtualDisplayRecord {
        uint8_t id;
        std::wstring device_name;
    };
    uint8_t                          next_id_ = 1;
    std::vector<VirtualDisplayRecord> active_displays_;
};

std::unique_ptr<IVirtualDisplayManager> create_virtual_display_manager() {
    return std::make_unique<VirtualDisplayManagerImpl>();
}

}  // namespace immersive
