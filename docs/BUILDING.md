# Building Immersive-2

## Prerequisites

### Host (Windows / Linux / macOS)

- **CMake 3.20+** ([cmake.org](https://cmake.org/download/))
- **Windows 10/11 (x64)** for full host features
  - Visual Studio 2022 with "Desktop development with C++" workload
  - Or MinGW-w64 with GCC 12+
- **Linux** (X11 or Wayland) — GCC 12+ or Clang 14+, see [Linux](#linux)
- **macOS 13+** — Xcode command line tools, see [macOS](#macos-13-ventura-or-newer)
- **GPU hardware encoder SDK** (optional — the MJPEG software encoder works with no GPU):
  - NVIDIA: CUDA Toolkit + NVIDIA Video Codec SDK
  - AMD: AMD Advanced Media Framework (AMF) SDK
  - Intel: Intel oneVPL or Intel Media SDK

### VR Client

- **Godot Engine 4.7** ([godotengine.org](https://godotengine.org/download))
- **Android SDK + NDK** (for Quest/Pico builds)
  - Install via Android Studio or `sdkmanager`
  - Required packages: `platforms;android-36`, `build-tools;36.1.0`, `ndk;29.0.14206865`
- **Meta Quest** or **Pico 4** headset in developer mode

---

## Building the Host

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

### Linux

```bash
# Debian/Ubuntu. Every group is optional; the host builds with whatever is found
# (cmake prints "Linux backends: X11=… Wayland-portal=… PulseAudio=… FFmpeg=…").
sudo apt install build-essential cmake pkg-config \
  libx11-dev libxext-dev libxrandr-dev libxtst-dev libxfixes-dev \
  libdbus-1-dev libpipewire-0.3-dev \
  libpulse-dev \
  libavcodec-dev libavutil-dev libswscale-dev
# Fedora: libX11-devel libXext-devel libXrandr-devel libXtst-devel libXfixes-devel
#         dbus-devel pipewire-devel pulseaudio-libs-devel ffmpeg-devel (RPM Fusion)

# GPU encoding (runtime): the VAAPI driver for your GPU.
#   Intel (Broadwell and newer, incl. Core Ultra):  sudo apt install intel-media-va-driver-non-free
#   AMD:                                              sudo apt install mesa-va-drivers
#   NVIDIA: NVENC comes with the proprietary driver.

cd host
cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build build
./build/immersive2_host
```

- **Wayland** (GNOME, KDE, …): capture and input go through xdg-desktop-portal
  (ScreenCast + RemoteDesktop) and PipeWire. The first run shows the desktop's
  screen-share dialog: pick the monitors to stream and allow remote control. The
  choice is remembered (`~/.config/immersive2/portal-restore-token`); delete that
  file to choose again. Compositors whose portal lacks RemoteDesktop (e.g.
  wlroots) stream fine but ignore VR input.
- **X11**: MIT-SHM capture per RandR monitor, XTEST input. No dialog.
- **Audio**: the monitor of the default output, through PulseAudio or
  PipeWire (pipewire-pulse).
- **Video**: H.264 / HEVC / AV1 through FFmpeg — NVENC first, then VAAPI, then
  libx264 (software H.264, fine for 1080p60 on a recent laptop CPU). The host
  logs which one it picked (`[FfmpegEncoder] H.264 via h264_vaapi …`); if it
  says libx264 on a machine with a GPU, install the VAAPI driver above.

### macOS (13 Ventura or newer)

```bash
xcode-select --install   # compilers + SDK
cd host
cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build build
./build/immersive2_host
```

Capture and system audio use ScreenCaptureKit (scaled to the stream size on the
GPU), video is encoded by VideoToolbox (hardware H.264 / HEVC, low-latency mode),
input uses CGEvent. The first
run asks for two permissions in System Settings → Privacy & Security, granted to
the terminal (or the binary) that launches the host:

- **Screen Recording** — without it no display is listed. Restart the host after
  granting it.
- **Accessibility** — without it the VR mouse/keyboard does nothing.

### Protocol testing without a desktop

`./build/immersive2_host --stub` serves three fake solid-grey monitors and only
logs input, on any OS. `host/tools/smoke_client.py` and `host/tools/e2e_test.py`
use it.

### CMake Options

| Option         | Default | Description                                        |
|----------------|---------|----------------------------------------------------|
| ENABLE_NVENC   | ON      | Enable NVIDIA NVENC hardware encoder               |
| ENABLE_AMF     | ON      | Enable AMD AMF hardware encoder                    |
| ENABLE_QSV     | ON      | Enable Intel QuickSync hardware encoder            |

When all hardware encoders are disabled (`=OFF`), the MJPEG software encoder
(`stb_image_write`) is used. This requires no external SDK and works on any CPU.

### What the Host Does

1. Enumerates all connected displays (DXGI/WGC, ScreenCaptureKit, RandR or the Wayland portal)
2. Listens on TCP :19800 for client connections
3. On connection, sends the monitor list to the VR client
4. When the client selects a monitor, starts capturing it + MJPEG encoding
5. Streams encoded frames over UDP :19801 in chunks of ≤ 1400 bytes
6. Receives mouse/keyboard input from the VR client and injects it (SendInput,
   CGEvent, XTEST or the RemoteDesktop portal)

H.264/HEVC/AV1 are hardware-encoded on every OS (Media Foundation, VideoToolbox,
FFmpeg NVENC/VAAPI); a codec the machine cannot encode falls back to H.264, then
MJPEG, and the STREAM_START tells the client which one it got.

---

## Building the VR Client

### Desktop Testing (no headset)

1. Open Godot 4.7+
2. Import the project from `client/project/`
3. Press **F5** to run in desktop mode
4. Press **O** to open the UI overlay, enter the host IP, and connect

### Quest / Pico APK Build

#### Via Godot Editor

1. Open the project in Godot 4.7+
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

## Running the Web Client (WebXR)

The web client uses a lightweight Node.js bridge that translates the native
host protocol into browser-friendly HTTP/MJPEG endpoints.

```bash
node web/bridge/bridge.js --connect --host 127.0.0.1 --tcp-port 19800 --udp-port 19801 --port 19810
```

Open:

- `http://localhost:19810/` for the desktop web control panel
- `http://localhost:19810/vr.html` for the WebXR scene

---

## Running the Full System

### Basic Setup

1. Connect the host machine and VR headset to the same Wi-Fi network
2. Start the host:
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
- **`host-linux`** job: builds the portable host on Ubuntu
- **`host-macos`** job: builds the portable host on macOS
- **`client-build`** job: installs Godot 4.7 headless, exports Windows Desktop and
  Android APK builds

Artifacts are uploaded as:
- `immersive2_host_windows`
- `immersive2_host_linux`
- `immersive2_host_macos`
- `immersive2_client_windows`
- `immersive2_client_android`

---

## Troubleshooting

### Host: "No displays found"
- On Windows: ensure monitors are active and GPU drivers are installed
- On macOS: grant Screen Recording (System Settings → Privacy & Security) and restart the host
- On Linux: run it inside the graphical session (`DISPLAY` / `WAYLAND_DISPLAY` set); on
  Wayland, accept the screen-share dialog
- Anywhere: `--stub` gives fake displays for protocol testing

### Client: OpenXR not initializing
- Ensure the headset runtime is active (put the headset on or use PC link)
- Verify OpenXR runtime is set to the correct provider (Meta / SteamVR / Pico)

### Client: Black screen / no video
- Check that the host is running and the firewall ports are open
- Verify you're on the same Wi-Fi network (5 GHz recommended)
- Check the latency indicator — high latency (> 100 ms) may cause dropped frames

### Client: Export fails (missing templates)
- Install export templates via **Editor → Manage Export Templates** in Godot
- Or download from https://godotengine.org/download/archive/4.7-stable/
