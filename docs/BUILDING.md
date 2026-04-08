# Building Immersive-2

## Prerequisites

### Windows Host

- **Windows 10/11** (x64)
- **Visual Studio 2022** with "Desktop development with C++" workload
  - Or MinGW-w64 with GCC 12+
- **CMake 3.20+** ([cmake.org](https://cmake.org/download/))
- **GPU hardware encoder SDK** (optional — the MJPEG software encoder works with no GPU):
  - NVIDIA: CUDA Toolkit + NVIDIA Video Codec SDK
  - AMD: AMD Advanced Media Framework (AMF) SDK
  - Intel: Intel oneVPL or Intel Media SDK

### VR Client

- **Godot Engine 4.3** ([godotengine.org](https://godotengine.org/download))
- **Android SDK + NDK** (for Quest/Pico builds)
  - Install via Android Studio or `sdkmanager`
  - Required packages: `platforms;android-32`, `build-tools;33.0.2`, `ndk;25.2.9519653`
- **Meta Quest** or **Pico 4** headset in developer mode

---

## Building the Windows Host

### Using Visual Studio 2022

```powershell
cd host

# Software encoder only (no GPU SDK required — recommended for development)
cmake -B build -G "Visual Studio 17 2022" -A x64 ^
  -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF

# With NVENC (requires NVIDIA Video Codec SDK)
cmake -B build -G "Visual Studio 17 2022" -A x64 ^
  -DENABLE_NVENC=ON -DENABLE_AMF=OFF -DENABLE_QSV=OFF

cmake --build build --config Release
```

The executable will be at `host/build/Release/immersive2_host.exe`.

### Using MinGW

```bash
cd host
cmake -B build -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build build
```

### CMake Options

| Option         | Default | Description                                        |
|----------------|---------|----------------------------------------------------|
| ENABLE_NVENC   | ON      | Enable NVIDIA NVENC hardware encoder               |
| ENABLE_AMF     | ON      | Enable AMD AMF hardware encoder                    |
| ENABLE_QSV     | ON      | Enable Intel QuickSync hardware encoder            |

When all hardware encoders are disabled (`=OFF`), the MJPEG software encoder
(`stb_image_write`) is used. This requires no external SDK and works on any CPU.

### What the Host Does

1. Enumerates all connected displays via DXGI
2. Listens on TCP :19800 for client connections
3. On connection, sends the monitor list to the VR client
4. When the client selects a monitor, starts DXGI capture + MJPEG encoding
5. Streams encoded frames over UDP :19801 in chunks of ≤ 1400 bytes
6. Receives mouse/keyboard input from the VR client and injects it via SendInput

---

## Building the VR Client

### Desktop Testing (no headset)

1. Open Godot 4.3+
2. Import the project from `client/project/`
3. Press **F5** to run in desktop mode
4. Press **O** to open the UI overlay, enter the host IP, and connect

### Quest / Pico APK Build

#### Via Godot Editor

1. Open the project in Godot 4.3+
2. Go to **Editor → Editor Settings → Export → Android**
3. Set **Android SDK Path** to your Android SDK root
4. Go to **Project → Export**
5. Select the **Android** preset
6. Configure signing if needed (or leave unsigned for developer installs)
7. Click **Export Project** (produces `.apk`)
8. Install via: `adb install Immersive2.apk`

#### Via Command Line

```bash
# Set up environment
export ANDROID_HOME=/path/to/android-sdk
export PATH=$ANDROID_HOME/platform-tools:$PATH

# Import project (generates .godot/ cache)
godot --headless --path client/project --import

# Export APK
WORKSPACE=$(pwd)
mkdir -p client/export/android
godot --headless \
  --path "$WORKSPACE/client/project" \
  --export-debug "Android" \
  "$WORKSPACE/client/export/android/Immersive2.apk"

# Install on connected headset
adb install client/export/android/Immersive2.apk
```

#### Windows Desktop Export

```bash
WORKSPACE=$(pwd)
mkdir -p client/export/windows
godot --headless \
  --path "$WORKSPACE/client/project" \
  --export-debug "Windows Desktop" \
  "$WORKSPACE/client/export/windows/Immersive2.exe"
```

---

## Running the Full System

### Basic Setup

1. Connect the Windows PC and VR headset to the same Wi-Fi network
2. Start the host on Windows:
   ```powershell
   .\host\build\Release\immersive2_host.exe
   ```
3. Launch the VR client on your headset
4. Press **B/Y** (VR) or **O** (desktop) to open the overlay
5. Enter the host PC's local IP address
6. Click **Connect**
7. Select a monitor from the list

### Local Testing (Host + Client on Same Machine)

```powershell
# Terminal 1: Start host
.\host\build\Release\immersive2_host.exe

# Terminal 2: Run Godot client
godot --path client\project\
```

Enter `127.0.0.1` as the host IP in the overlay.

### Firewall

The host needs the following ports open for inbound connections:

| Port  | Protocol | Purpose            |
|-------|----------|--------------------|
| 19800 | TCP      | Control channel    |
| 19801 | UDP      | Video stream       |

On Windows:
```powershell
netsh advfirewall firewall add rule name="Immersive2 TCP" protocol=TCP dir=in localport=19800 action=allow
netsh advfirewall firewall add rule name="Immersive2 UDP" protocol=UDP dir=in localport=19801 action=allow
```

---

## CI/CD

GitHub Actions runs on every push:

- **`host-windows`** job: builds the C++ host with MSVC (Visual Studio 17 2022)
  using `-DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF` (MJPEG software encoder)
- **`client-build`** job: installs Godot 4.3 headless, exports Windows Desktop and
  Android APK builds

Artifacts are uploaded as:
- `immersive2_host_windows`
- `immersive2_client_windows`
- `immersive2_client_android`

---

## Troubleshooting

### Host: "No displays found"
- Ensure you are running on Windows (DXGI is Windows-only)
- The DXGI capture implementation is currently a stub; real capture via DDA is in progress

### Client: OpenXR not initializing
- Ensure the headset runtime is active (put the headset on or use PC link)
- Verify OpenXR runtime is set to the correct provider (Meta / SteamVR / Pico)

### Client: Black screen / no video
- Check that the host is running and the firewall ports are open
- Verify you're on the same Wi-Fi network (5 GHz recommended)
- Check the latency indicator — high latency (> 100 ms) may cause dropped frames

### Client: Export fails (missing templates)
- Install export templates via **Editor → Manage Export Templates** in Godot
- Or download from https://godotengine.org/download/archive/4.3-stable/
