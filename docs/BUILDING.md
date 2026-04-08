# Building Immersive-2

## Prerequisites

### Windows Host

- **Windows 10/11** (x64)
- **Visual Studio 2022** with "Desktop development with C++" workload
  - Or MinGW-w64 with GCC 12+
- **CMake 3.20+** ([cmake.org](https://cmake.org/download/))
- **GPU with hardware encoding support** (one of):
  - NVIDIA: CUDA Toolkit + Video Codec SDK
  - AMD: AMF SDK
  - Intel: Intel Media SDK / oneVPL

### VR Client

- **Godot Engine 4.3+** ([godotengine.org](https://godotengine.org/download))
- **Android SDK** with NDK (for Quest/Pico builds)
- **OpenXR Loader** (included with Godot)
- **Meta Quest** or **Pico 4** headset in developer mode

## Building the Windows Host

### Using Visual Studio

```powershell
cd host
cmake -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

The executable will be at `host/build/Release/immersive2_host.exe`.

### Using MinGW

```bash
cd host
cmake -B build -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

### CMake Options

| Option         | Default | Description                    |
|----------------|---------|--------------------------------|
| ENABLE_NVENC   | ON      | Enable NVIDIA NVENC encoder    |
| ENABLE_AMF     | ON      | Enable AMD AMF encoder         |
| ENABLE_QSV     | ON      | Enable Intel QuickSync encoder |

Example:
```bash
cmake -B build -DENABLE_NVENC=ON -DENABLE_AMF=OFF -DENABLE_QSV=OFF
```

## Building the VR Client

### Desktop Testing

1. Open Godot 4.3+
2. Import the project from `client/project/`
3. Press F5 to run in desktop mode (no headset required)
4. Press `C` to connect to the host

### Quest / Pico Build

1. Open the project in Godot 4.3+
2. Go to **Project → Export**
3. Add an **Android** export preset
4. Configure:
   - **Min SDK**: 29
   - **Target SDK**: 32
   - **XR Mode**: OpenXR
   - **XR Features**: Hand tracking (optional)
5. Set the Android SDK/NDK paths in Editor Settings
6. Click **Export Project** or use one-click deploy to the headset

### Command-Line Build (Godot)

```bash
# Export for Android (Quest)
godot --headless --export-debug "Android" immersive2_client.apk

# Run in desktop mode
godot --path client/project/
```

## Development Workflow

1. Start the Windows host: `host/build/Release/immersive2_host.exe`
2. Launch the VR client on your headset (or desktop mode)
3. The client auto-connects and starts streaming

### Running Host + Client on Same Machine

For testing, you can run both on the same Windows machine:

```powershell
# Terminal 1: Start host
.\host\build\Release\immersive2_host.exe

# Terminal 2: Run Godot client in desktop mode
godot --path client\project\
# Then press 'C' to connect to localhost
```

Edit `host_ip` in `client/scripts/main.gd` to `"127.0.0.1"` for local testing.
