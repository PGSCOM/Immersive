# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Immersive-2 is an open-source "use your PC monitors in VR" system (an Immersed alternative). It has three independent pieces that talk over a custom TCP/UDP wire protocol:

- **`host/`** — C++17 Windows application (portable stub mode on Linux/macOS) that captures the desktop via DXGI Desktop Duplication, encodes frames (MJPEG software encoder or NVENC/AMF/QSV hardware via Media Foundation), streams them over UDP, and injects mouse/keyboard input received from the client via `SendInput`.
- **`client/project/`** — Godot 4.6.3 + OpenXR VR client (Quest / Pico 4) that connects to the host, decodes the stream, and renders monitors as floating 3D panels.
- **`web/`** — experimental WebXR client; `web/bridge/bridge.js` is a Node bridge that re-exposes the native TCP/UDP protocol as HTTP/MJPEG for browsers.

`protocol/protocol.h` is the single shared definition of the wire format (message types, structs) and is included by both the C++ host and conceptually mirrored by the GDScript client. **`protocol/README.md` and `docs/PROTOCOL.md` are human-written docs and can drift out of date — when in doubt about message types or struct layout, read `protocol.h` directly.**

## Build / Run Commands

### Host (C++)

```powershell
cd host
cmake -B build -G "Visual Studio 17 2022" -A x64 -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build build --config Release
.\build\Release\immersive2_host.exe
```

Linux/macOS builds in portable mode (stubbed capture/input/IDD, real network/protocol code — useful for protocol-level dev without Windows):

```bash
cd host
cmake -B build -DCMAKE_BUILD_TYPE=Release -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build build
./build/immersive2_host
```

CMake options `ENABLE_NVENC` / `ENABLE_AMF` / `ENABLE_QSV` default to `ON` but CI and most local dev builds set them `OFF` since the MJPEG software encoder needs no GPU SDK. The host's real entry point/orchestration logic lives in `host/src/main.cpp` (see Architecture below) — there is no separate test runner; `host/tools/smoke_client.py` is the closest thing to a test suite.

Host CLI flags (see `host/src/main.cpp` `usage()`): `--codec mjpeg|h264|h265|av1`, `--jpeg-quality N` (10–95), `--no-audio`, `--max-clients N`, `--tcp-port`, `--udp-port`, `--audio-port`.

### Smoke-testing the host (no headset required)

```bash
python host/tools/smoke_client.py
```

Connects from `127.0.0.2` (not `127.0.0.1`) so it can bind the UDP video port locally even while the host holds the wildcard bind on the same port — this is the standard trick for exercising the host on a single machine. It drives the HELLO handshake, MONITOR_LIST, MULTI_MONITOR_SELECT, frame reassembly, and STREAM_STOP.

### VR Client (Godot)

Desktop testing (no headset): open `client/project/` in Godot 4.6.3+, press F5, press `O` to open the overlay and connect.

Export builds:

```bash
godot --headless --path client/project --export-debug "Android" client/dist/immersive2-debug.apk
adb install -r client/dist/immersive2-debug.apk

godot --headless --path client/project --export-debug "Windows Desktop" client/dist/immersive2-debug.exe
```

The Android export bundles the MediaCodec decoder plugin from `addons/im2_decoder/bin/*.aar`, built separately from `client/android-plugin/` (`gradle assembleRelease`, requires Android SDK/NDK; see `client/android-plugin/README.md`). The client has **two decode paths**, chosen per device by codec negotiation:
- **Hardware** (`video_decoder.gd` → MediaCodec, Android/Pico/Quest): H.264/HEVC/AV1, zero-copy into an `ExternalTexture`. Requires the AAR plugin.
- **Software** (`software_video_decoder.gd`, `SoftwareVideoDecoder`): MJPEG decoded on a `WorkerThreadPool` thread via Godot's built-in JPEG decoder — works on **PC (Windows/Linux/macOS desktop), iOS, and web**, no native plugin. The decoded `Image` is uploaded to the panel via `screen_panel.gd::update_decoded_image()`.

`main.gd::_default_codec_for_device()` picks H.264 when `VideoDecoder.is_codec_supported()` (MediaCodec present), else MJPEG, so platforms without the plugin negotiate MJPEG up front (the host always supports the MJPEG software encoder). `_resolve_codec()` also degrades a user-forced HW codec to MJPEG on such platforms, and `_request_codec_fallback()` is the runtime safety net. The plugin must register under the Godot 4.2+ **`org.godotengine.plugin.v2`** manifest prefix — a `v1` prefix is silently ignored and was the cause of a hard fall to MJPEG (≈1 fps). Note: native hardware decode for PC/iOS (Media Foundation / VideoToolbox) is not implemented — those platforms use the software MJPEG path.

### Web client (WebXR)

```bash
node web/bridge/bridge.js --connect --host 127.0.0.1 --tcp-port 19800 --udp-port 19801 --port 19810
```

Then open `http://localhost:19810/` (controls/preview) or `/vr.html` (WebXR scene).

### CI (`.github/workflows/build.yml`)

Four jobs on every push: `host-windows` (MSVC), `host-linux`, `host-macos` (all build with hardware encoders OFF), and `client-build` (Ubuntu, installs Godot 4.6.3 headless + Android SDK, exports both a Windows Desktop and an Android build from a temporary `client/.ci_project` copy). Note the comment in that workflow: `xr/openxr/enabled` in `project.godot` must stay `true` even for CI exports — disabling it would bake OpenXR off into the APK. The `--xr-mode off` flag only suppresses runtime XR init inside the *export tool itself* on the headless runner.

## Architecture

### Host: single-process, per-monitor worker threads

`host/src/main.cpp` is the orchestrator — there's no class wiring this together, it's all in `main()`. On startup it builds: a `DxgiCapture` (enumerates displays), checks Media Foundation encoder availability (`mf_encoder_available` for H.264/HEVC/AV1), creates an `InputInjector`, an `IVirtualDisplayManager` (IDD detection), optional WASAPI loopback `AudioCapture`, and the `NetworkServer`.

Each selected monitor gets its own OS thread (`stream_worker` lambda) with its own `DxgiCapture` + encoder instance, registered in `active_streams` (keyed by monitor id, guarded by `streams_mutex`). Monitor selection changes (`apply_selection`) diff the requested set against `active_streams`: stop threads no longer wanted, join them, start new ones. `restart_streams` is used when the client sends `STREAM_CONFIG` (quality change) — it tears down and respins all active streams in place without sending `STREAM_STOP` to the client (panels stay visually present).

Per-stream codec resolution follows a fallback chain, both at the CLI-default level and per-stream: requested codec (H.264/H.265/AV1 via Media Foundation MFT) → H.264 → software MJPEG (`stb_image_write`, always available). The effective codec actually used is announced back to the client in `StreamStart.codec`, which may differ from what was requested.

Mouse input arrives in *stream* pixel coordinates (which can be downscaled from native via `STREAM_CONFIG.max_width`); `main.cpp` keeps a per-monitor `input_scale` map to convert back to native pixels before calling `InputInjector::inject_mouse`.

Source layout: `capture/` (DXGI Desktop Duplication), `encoder/` (`encoder.cpp` = MJPEG software path, `mf_encoder.cpp` = Media Foundation HW path for NVENC/AMF/QSV), `network/` (`server.cpp` ties together `tcp_control.cpp` + `udp_stream.cpp`), `input/` (SendInput injection), `driver/` (`idd_manager.cpp` — IDD virtual-display detection, see below), `audio/` (WASAPI loopback capture).

On non-Windows (`IMMERSIVE_PORTABLE_HOST`), capture/input/IDD/audio backends are stubs; only network/protocol code is "real" — this mode exists for protocol development and CI, not for actually streaming a desktop.

### IDD virtual display detection

`idd_manager.cpp` looks for a device whose hardware ID starts with `Root\VID_IDD` via `SetupDiGetDeviceRegistryProperty(SPDRP_HARDWAREID)`, with a secondary fallback check for any monitor device whose friendly name contains "virtual". If neither matches, `is_driver_installed()` returns false and the host just uses physical monitors — this is optional, not required for normal operation. Driver install/build instructions are in `docs/IDD_DRIVER.md` (it relies on a third-party community driver, `itsmikethetech/Virtual-Display-Driver`, and Windows test-signing).

### VR Client (Godot)

`client/project/scripts/main.gd` is the scene controller (multi-monitor slots, auto-reconnect, workspace persistence). `network_client.gd` owns the TCP control connection + UDP video/audio sockets and latency probing. `screen_panel.gd` is a draggable/resizable 3D panel; `main.gd` owns one `video_decoder.gd` per monitor stream. `video_decoder.gd` wraps the `Im2VideoDecoder` Android plugin (MediaCodec) in a **zero-copy** path: MediaCodec decodes straight into a Godot `ExternalTexture` (a `GL_TEXTURE_EXTERNAL_OES` object) via a `SurfaceTexture`, and the panel's `screen_external.gdshader` samples it through `samplerExternalOES` — no CPU readback, no YUV unpacking. `SurfaceTexture.attachToGLContext`/`updateTexImage` must run on Godot's render thread, so they are scheduled via `RenderingServer.call_on_render_thread()` (driven each frame from `main.gd._update_decoders`). `VideoDecoder.is_codec_supported()` returns false without the plugin (PC/iOS/web); there `main.gd` instead opens a `SoftwareVideoDecoder` (`software_video_decoder.gd`) that decodes the MJPEG stream on a `WorkerThreadPool` thread and uploads the result via `screen_panel.gd::update_decoded_image()` — `_update_decoders` polls both decoder kinds each frame. `vr_input.gd` / `hand_input.gd` handle controller and hand-tracking pointer input; `ui_overlay.gd` is the in-VR settings/connect UI; `virtual_keyboard.gd` is the VR QWERTY keyboard; `audio_receiver.gd` decodes the UDP PCM audio stream into an `AudioStreamGenerator`.

The Android decoder plugin is a separate Gradle/Java project at `client/android-plugin/` (not part of the Godot project tree) producing an AAR consumed via the `addons/im2_decoder` export plugin (an `EditorExportPlugin` that adds the AAR via `_get_android_libraries`).

### Protocol

TLV control messages over TCP (`uint8 type, uint32 length LE, payload`), chunked binary frames over UDP (monitor id, frame number, chunk index/count, ≤1400-byte payload). Default ports: TCP 19800 (control), UDP 19801 (video), UDP 19802 (audio, PCM-16 stereo 48kHz). All message types/struct layouts are defined once in `protocol/protocol.h` — extend that file first when adding a new message, then mirror the struct packing manually in GDScript (the client has no codegen from the header).

## Code Style (from CONTRIBUTING.md)

- **C++ (host):** C++17, `snake_case` functions/variables, `PascalCase` classes/types, `SCREAMING_SNAKE_CASE` constants, trailing/leading `_` for private members, `#pragma once` guards.
- **GDScript (client):** follow the official GDScript style guide, use type hints, document public functions with `##` doc comments.
