# IDD Virtual Display Driver

Immersive-2 can use a Windows **Indirect Display Driver (IDD)** to create
headless virtual monitors at custom resolutions and refresh rates.
This is useful when you want to stream a dedicated VR workspace rather than
one of your physical monitors.

> **Note — driver signing required.**  
> Because IDD drivers run in kernel mode, Windows enforces driver-signature
> checks.  The steps below use a community-signed build of
> **itsmikethetech/Virtual-Display-Driver**.  You must enable test-signing
> OR use the WHQL-signed release.

---

## Recommended Driver: Virtual-Display-Driver

[https://github.com/itsmikethetech/Virtual-Display-Driver](https://github.com/itsmikethetech/Virtual-Display-Driver)

This driver installs as an IDD device and exposes one or more virtual monitors
to Windows that DXGI can capture like any physical display.

### Quick Install (Windows 10/11)

1. Download the latest release from the
   [Releases page](https://github.com/itsmikethetech/Virtual-Display-Driver/releases).

2. Extract the ZIP.

3. **Enable test-signing** (required unless using a WHQL build):

   ```powershell
   # Run as Administrator
   bcdedit /set testsigning on
   # Reboot
   ```

4. Right-click `VirtualDisplayDriver.inf` → **Install**.

5. Accept the unsigned-driver warning prompt.

6. Open **Device Manager** → the new "Virtual Display" device should appear
   under **Monitors**.

### Verification

Run Immersive-2:

```powershell
.\build\Release\immersive2_host.exe
```

You should see:

```
[IDDManager] Detected itsmikethetech Virtual-Display-Driver
[Host] IDD driver found — virtual displays available
```

---

## Using with Immersive-2

Once the driver is installed the host will automatically list the virtual
display alongside physical monitors in the VR client's monitor list.

To force a specific virtual resolution you can use the **Virtual Display
Settings** utility bundled with the driver (or edit
`VirtualDisplayConfig.cfg` in the driver directory).

Recommended resolutions for VR streaming:

| Resolution | Use case |
|-----------|----------|
| 2560×1440 | Single high-res workspace |
| 3840×2160 | 4K workspace (requires fast GPU encoder) |
| 1920×1080 | Low-latency / Wi-Fi 5 |

---

## How Immersive-2 Detects the Driver

`host/src/driver/idd_manager.cpp` calls
`SetupDiGetDeviceRegistryProperty(SPDRP_HARDWAREID)` looking for devices
whose hardware-ID string starts with `Root\VID_IDD`.  It also does a
secondary check for any monitor device whose friendly name contains
"virtual".

If neither check succeeds, `IVirtualDisplayManager::is_driver_installed()`
returns `false` and the host skips virtual-display setup — it still works
normally with physical monitors.

---

## Building the Driver Yourself (Advanced)

Requirements:
- **Windows Driver Kit (WDK)** matching your Visual Studio version  
  Download: https://learn.microsoft.com/en-us/windows-hardware/drivers/download-the-wdk
- Visual Studio 2022 with "Desktop development with C++" workload
- Windows SDK 10.0.22000+

Clone and build:

```powershell
git clone https://github.com/itsmikethetech/Virtual-Display-Driver
cd Virtual-Display-Driver
# Open VirtualDisplayDriver.sln in Visual Studio 2022
# Build → Release/x64
# Output: VirtualDisplayDriver.sys + .inf
```

For WHQL signing (to avoid test-signing), you need an EV code-signing
certificate and submission to the Windows Hardware Dev Center — this is
out of scope for most personal/lab setups.

---

## Uninstall

```powershell
# Device Manager → right-click "Virtual Display" → Uninstall device
# Check "Delete the driver software for this device"
# Then disable test-signing if you enabled it:
bcdedit /set testsigning off
# Reboot
```
