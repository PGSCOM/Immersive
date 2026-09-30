#pragma once

/// Virtual displays (and, on Windows, IDD driver detection).

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace immersive {

/// Configuration for a virtual display
struct VirtualDisplayConfig {
    uint16_t    width        = 1920;
    uint16_t    height       = 1080;
    uint8_t     refresh_rate = 60;
    std::string name         = "Immersive-2 Virtual Display";
};

/// Virtual displays: extra monitors that exist only to be shown in VR.
/// The base class is the "not supported here" manager; each OS overrides it
/// (X11 RandR, GNOME/Mutter, macOS CGVirtualDisplay, the --stub fakes).
/// Created displays get ids protocol::VIRTUAL_MONITOR_ID_BASE + n, and the
/// capture backend of that OS reports and captures them under that id.
/// Called with main.cpp's ops_mutex held: implementations need no locking
/// of their own against each other.
class IVirtualDisplayManager {
public:
    virtual ~IVirtualDisplayManager() = default;

    /// Check if the IDD driver is installed (Windows only)
    virtual bool is_driver_installed() const { return false; }

    /// True when create_display() can work on this machine.
    virtual bool can_create_displays() const { return false; }

    /// Create a virtual display with the given configuration.
    /// Returns its monitor id, or 0 on failure.
    virtual uint8_t create_display(const VirtualDisplayConfig& /*config*/) { return 0; }

    /// Remove a virtual display
    virtual bool remove_display(uint8_t /*display_id*/) { return false; }

    /// Remove all virtual displays
    virtual void remove_all_displays() {}

    /// Get the list of active virtual display IDs
    virtual std::vector<uint8_t> get_active_displays() const { return {}; }
};

/// The virtual-display manager for this OS and session (never nullptr; the
/// base class when this desktop cannot make virtual displays).
std::unique_ptr<IVirtualDisplayManager> create_virtual_display_manager();

/// Fake virtual displays for --stub (solid grey, see stub_capture.cpp).
std::unique_ptr<IVirtualDisplayManager> create_stub_virtual_display_manager();

/// Generate (if absent) a self-signed code-signing certificate and add it to
/// the machine's Root and TrustedPublisher stores, so an unsigned community IDD
/// driver can be installed without enabling Windows test-signing.
///
/// This permanently weakens the machine's trust configuration: anything signed
/// with that key becomes trusted. It therefore happens ONLY when the user asks
/// for it (`--install-idd-cert`), never as a side effect of checking whether a
/// driver is present. Requires an elevated process; no-op off Windows.
void install_idd_signing_certificate();

}  // namespace immersive
