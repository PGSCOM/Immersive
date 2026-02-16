#pragma once

/// IDD (Indirect Display Driver) Manager.
/// Creates and manages virtual displays on Windows using the IDD framework.

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

/// Interface for managing IDD virtual displays
class IVirtualDisplayManager {
public:
    virtual ~IVirtualDisplayManager() = default;

    /// Check if the IDD driver is installed
    virtual bool is_driver_installed() const = 0;

    /// Create a virtual display with the given configuration
    /// Returns the display ID, or 0 on failure
    virtual uint8_t create_display(const VirtualDisplayConfig& config) = 0;

    /// Remove a virtual display
    virtual bool remove_display(uint8_t display_id) = 0;

    /// Remove all virtual displays
    virtual void remove_all_displays() = 0;

    /// Get the list of active virtual display IDs
    virtual std::vector<uint8_t> get_active_displays() const = 0;
};

/// Create an IDD virtual display manager
std::unique_ptr<IVirtualDisplayManager> create_virtual_display_manager();

}  // namespace immersive
