/// IDD Virtual Display Manager implementation.
///
/// Manages virtual displays created via the Windows Indirect Display Driver (IDD)
/// framework. Requires the Immersive-2 IDD driver to be installed on the system.

#include "driver/idd_manager.h"
#include <algorithm>
#include <iostream>

#ifdef _WIN32
#include <windows.h>
#include <setupapi.h>
#endif

namespace immersive {

class VirtualDisplayManagerImpl : public IVirtualDisplayManager {
public:
    bool is_driver_installed() const override {
        // TODO: Check for the IDD driver in the Windows driver store
        // For now, return false (driver not yet implemented)
        std::cout << "[IDDManager] Driver installation check (not yet implemented)\n";
        return false;
    }

    uint8_t create_display(const VirtualDisplayConfig& config) override {
        if (!is_driver_installed()) {
            std::cerr << "[IDDManager] IDD driver not installed. "
                      << "Virtual displays are not available.\n"
                      << "Tip: Use physical monitors for now, or install the IDD driver.\n";
            return 0;
        }

        // TODO: Communicate with the IDD driver to create a virtual display
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
    uint8_t next_id_ = 1;
    std::vector<uint8_t> active_displays_;
};

std::unique_ptr<IVirtualDisplayManager> create_virtual_display_manager() {
    return std::make_unique<VirtualDisplayManagerImpl>();
}

}  // namespace immersive
