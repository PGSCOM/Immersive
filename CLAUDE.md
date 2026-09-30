# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Immersive-2 is an open-source "use your PC monitors in VR" system (an Immersed alternative). It has three independent pieces that talk over a custom TCP/UDP wire protocol:

- **`host/`** — C++ application for Windows, Linux and macOS that captures the desktop (Windows: WGC → DXGI fallback; macOS: ScreenCaptureKit; Linux: xdg-desktop-portal + PipeWire on Wayland, XShm on X11), encodes frames (MJPEG software encoder everywhere; H.264/HEVC/AV1 through `create_hw_encoder()`: Media Foundation on Windows, VideoToolbox on macOS, FFmpeg NVENC → VAAPI → libx264 on Linux), streams them over UDP, captures system audio (WASAPI / ScreenCaptureKit / PulseAudio) and injects mouse/keyboard input from the client (SendInput / CGEvent / RemoteDesktop portal / XTEST).
- **`client/project/`** — Godot 4.7 + OpenXR VR client (Quest / Pico 4) that connects to the host, decodes the stream, and renders monitors as floating 3D panels.
- **`web/`** — experimental WebXR client; `web/bridge/bridge.js` is a Node bridge that re-exposes the native TCP/UDP protocol as HTTP/MJPEG for browsers.

`protocol/protocol.h` is the single shared definition of the wire format (message types, structs) and is included by both the C++ host and conceptually mirrored by the GDScript client. **`docs/PROTOCOL.md` is the human-written reference; it is kept in sync but `protocol.h` still wins when they disagree, so read the header directly when in doubt.** (`protocol/README.md` used to hold a second, drifting copy of that reference — it is now just a pointer.)

## Build / Run Commands

### Host (C++)

```powershell
cd host
cmake -B build -G "Visual Studio 17 2022" -A x64 -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build build --config Release
.\build\Release\immersive2_host.exe
```

Linux/macOS (real capture/input/audio; dependencies and permissions in `docs/BUILDING.md`). On Linux every backend is optional at configure time — cmake prints `Linux backends: X11=… Wayland-portal=… PulseAudio=…` and builds with whatever it found:

```bash
cd host
cmake -B build -DCMAKE_BUILD_TYPE=Release -DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF
cmake --build build
./build/immersive2_host
```

CMake options `ENABLE_NVENC` / `ENABLE_AMF` / `ENABLE_QSV` default to `ON` but CI and most local dev builds set them `OFF` since the MJPEG software encoder needs no GPU SDK. The host's real entry point/orchestration logic lives in `host/src/main.cpp` (see Architecture below) — there is no unit-test runner; `host/tools/smoke_client.py` and `host/tools/view_only_test.py` (host only) and `host/tools/e2e_test.py` (host + Godot client) are the test suite.

Host CLI flags (see `host/src/main.cpp` `usage()`): `--codec mjpeg|h264|h265|av1`, `--jpeg-quality N` (10–95), `--pin NNNNNN` / `--no-pin` (pairing; default: a random PIN created once in `~/.config/immersive2/pairing-pin` or `%APPDATA%\Immersive2\pairing-pin` — tests always pass `--pin 246810` or `--no-pin` so they never create it), `--no-audio`, `--no-usb` (skip the `adb reverse` upkeep that lets a USB-cabled headset connect to its own 127.0.0.1; see `host/src/usb/adb_reverse.cpp`), `--view-only` (share screens, ignore all input; advertised in discovery and HELLO_ACK), `--max-clients N`, `--tcp-port`, `--udp-port`, `--audio-port`, `--install-idd-cert` (one-shot, admin-only: trusts a self-signed key so an unsigned IDD driver installs — see `docs/IDD_DRIVER.md`; never runs on its own).

### Smoke-testing the host (no headset required)

```bash
./host/build/immersive2_host --stub --pin 246810 &     # fake displays, input only logged
python host/tools/smoke_client.py
```

Connects from `127.0.0.2` (not `127.0.0.1`) so it can bind the UDP video port locally even while the host holds the wildcard bind on the same port — this is the standard trick for exercising the host on a single machine. Because it is not 127.0.0.1 it is *not* trusted, so it also exercises pairing: LAN discovery on UDP 19800, HELLO without / with a wrong PIN (HELLO_REJECT), a request before HELLO (dropped), idle unpaired sockets (dropped, never blocking a real client). Then the HELLO handshake with the PIN, MONITOR_LIST, MULTI_MONITOR_SELECT, frame reassembly, per-monitor downscaling, the codec fallback chain, STREAM_STOP, and a second connection from 127.0.0.1 (trusted, like USB) in TCP media mode that must receive every monitor as in-band `VIDEO_FRAME` messages, get at most a few frames while it stops sending FRAME_ACK, and live frames again once it acks. `IM2_PIN`, `IM2_TCP_PORT` and `IM2_UDP_PORT` override its defaults (as they do for codec_test/x11_test), so several sessions on one machine can test in parallel on different ports.

`--stub` (any OS; `stub_capture.cpp`; monitors 0-1 static like an idle event-driven capture, monitor 2 animated with a bar in its left quarter) reports **three** fake displays of different resolutions (1920x1080, 1920x1200, 1280x720), so this smoke test genuinely covers the multi-monitor paths — three worker threads, per-monitor encoders and the per-monitor mouse-scaling map — rather than a single stream.

### End-to-end test: real host + real Godot client (no headset required)

```bash
python3 host/tools/e2e_test.py        # E2E_VERBOSE=1 to see both logs
```

Linux only. Builds the host (incremental), re-imports the Godot project (class names), starts the host with `--stub --pin 246810 --no-usb` (ports from `IM2_TCP_PORT`/`IM2_UDP_PORT`, default 19800/19801, passed to the client as `--im2-port`/`--im2-udp-port`), and runs the actual client headless (`godot` 4.7 on PATH) with the test-harness args `--im2-host=127.0.0.1 --im2-monitors=0,1,2 --im2-capture`. Checks that all three stub monitors decode onto their own panel (each stub is a distinct grey, reported by the `panel mon=N ... center=RRGGBB` harness line), that the client reconnects after the host is killed and after it freezes (SIGSTOP — exercises the client's 10 s host-silence timeout in `network_client.gd`), that the host's client sockets carry TCP keepalive, and that Ctrl+C exits the host. Step 5 reconnects with `--im2-usb`, the client's USB mode: `adb reverse` tunnels TCP only, so the client sets `HELLO_FLAG_TCP_MEDIA` and the host sends video/audio in-band on the control socket (`VIDEO_FRAME` / `AUDIO_DATA`); on Android a `127.x` host address implies it. Step 6 is automatic USB: a client started on the LAN address with `--im2-usb-port=N` (turns on the USB probe on desktop; the "cable" is 127.0.0.1:N) must move to a local TCP forwarder standing in for `adb reverse` when it appears, back to the LAN when it drops every connection (the pulled cable), and to the forwarder again. Step 7 runs `client/tests/discovery_test.gd` (HostDiscovery finds the running host, with its PIN flag) and then pairing for real over the machine's LAN address: without `--im2-pin` the client must be refused (reason 1) and stop retrying, with it it must stream. Step 8 starts a client with `--im2-virtual=1280x720`: the host must create virtual monitor 100 and the client must stream it (the stub's virtual grey, 208). Step 10 runs `client/tests/overlay_test.gd` under `xvfb-run`: it renders the real in-VR menu offscreen and drives it with the same pointer events the controllers inject (address keypad and validation, the discovered-PC list, PIN entry, tabs, monitor switches, Space/Quality controls, and that each tab fits the fixed 1000x680 panel without scrolling); pass `-- /tmp/shot` to it to get PNGs of each state. Step 11 runs headless: `client/tests/hand_input_test.gd` feeds `hand_input.gd` a fake tracked hand and checks that a pinch clicks where the hand points (the ray goes shoulder → index knuckle, so curling the finger into a pinch cannot move it) and that hand shake does not turn a click into a drag; `client/tests/controller_idle_test.gd` drives `vr_input.gd` (trigger click, release reaching the PC even off the screen, short grip = right click vs held grip = grab, hand-over between controllers, idle hiding); `client/tests/workspace_test.gd` checks ray hits on flat/curved screens, LaserDrag (upright, facing the head, push/pull) and the VR keyboard's one-shot modifiers. Test runs launched with `--im2-host` never write the user's config or workspace. Run the suite after touching the protocol, reconnect, shutdown, menu or input code.

### USB tunnel test (Linux/macOS, no device)

```bash
python3 host/tools/usb_test.py
```

Runs the host with a fake `adb` (PATH and HOME replaced, so a real adb is never touched) listing two headsets, one unauthorised: it must arm `adb -s <serial> reverse` on the authorised one only, tell the person to accept the prompt on the other, log changes only, re-arm after a replug, find adb in `~/Android/Sdk/platform-tools` without PATH, and not leak its sockets into adb (an adb server the host starts must not keep its port open).

### Codec test (any OS, needs ffmpeg)

```bash
python3 host/tools/codec_test.py [path/to/immersive2_host]
```

Starts the host with `--stub`, requests H.264, HEVC and AV1 in turn (each must stream itself or the announced H.264 fallback, downscaled by the encoder), sends REQUEST_KEYFRAME and decodes with ffmpeg starting **at** that keyframe only — the late-joiner / loss-recovery case — checking every monitor's grey. On Linux, VAAPI needs the GPU's VA driver (Intel: `intel-media-va-driver-non-free`), else it tests libx264.

### X11 backend test (no desktop touched)

```bash
python3 host/tools/x11_test.py
```

Linux only (Xvfb, xrandr, xsetroot, xdotool, xev, Python PIL). Runs the real host on a private `Xvfb -noreset` split into two RandR monitors painted red/blue and checks the monitor list, per-monitor crop/colour, pointer placement, Shift+A, wheel notches and (with ffmpeg) `codec_test.check_codecs()` on that coloured content. The Wayland/macOS backends have no automated test: CI only compiles macOS and the Wayland code needs a real portal dialog.

### VR Client (Godot)

Desktop testing (no headset): open `client/project/` in Godot 4.7+, press F5, press `O` to open the overlay and connect.

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

Four jobs on every push: `host-windows` (MSVC), `host-linux`, `host-macos` (all build with hardware encoders OFF and run `smoke_client.py` against `--stub`; `host-linux` also installs every Linux backend's -dev package, fails if cmake skipped one, and runs `codec_test.py` + `x11_test.py`; `host-macos` runs `codec_test.py` against VideoToolbox), and `client-build` (Ubuntu, installs Godot 4.7 headless + Android SDK, exports both a Windows Desktop and an Android build from a temporary `client/.ci_project` copy, then runs `e2e_test.py`). Note the comment in that workflow: `xr/openxr/enabled` in `project.godot` must stay `true` even for CI exports — disabling it would bake OpenXR off into the APK. The `--xr-mode off` flag only suppresses runtime XR init inside the *export tool itself* on the headless runner.

## Architecture

### Host: single-process, per-monitor worker threads

`host/src/main.cpp` is the orchestrator — there's no class wiring this together, it's all in `main()`. On startup it builds a capture backend via `create_screen_capture()` (or `create_stub_capture()` with `--stub`) to enumerate displays, checks Media Foundation encoder availability (`mf_encoder_available` for H.264/HEVC/AV1), creates an `InputInjector`, an `IVirtualDisplayManager` (IDD detection), optional loopback `AudioCapture`, and the `NetworkServer`.

Each selected monitor gets its own OS thread (`stream_worker` lambda) with its own capture + encoder instance, registered in `active_streams` (keyed by monitor id, guarded by `streams_mutex`). Monitor selection changes (`apply_selection`) diff the requested set against `active_streams`: stop threads no longer wanted, join them, start new ones. `restart_streams` is used when the client sends `STREAM_CONFIG` (quality change) — it tears down and respins all active streams, sending `STREAM_STOP` for each first so the client rebuilds its panel and decoder from the following `STREAM_START`.

USB (`usb/adb_reverse.cpp`): `start_adb()` finds adb (PATH, then the Android SDK's usual folders) and starts its server before any socket exists; `keep_adb_reverse()` runs on its own thread and every 3 s arms `adb -s <serial> reverse tcp:<port> tcp:<port>` on each authorised device lacking it, logging state changes only. Server sockets are close-on-exec / non-inheritable, so an adb daemon started later cannot keep the port bound after the host exits. In TCP media mode (server.cpp) the socket has TCP_NODELAY and a 1 MB send buffer, and each monitor may have at most 4 frames sent but not yet FRAME_ACKed; beyond that whole frames are dropped (the client's gap detection asks for a keyframe).

Pairing (server.cpp): nothing but HELLO is served until the HELLO passes `check_pin()` — 127.0.0.1 is trusted (local processes, `adb reverse`), everyone else must send `ServerConfig::pin`; wrong PINs cost 0.5 s and 5 lock the address out for a minute; unpaired sockets get a 5 s receive timeout and don't count toward `--max-clients`. The monitor list and AUDIO_START follow the HELLO_ACK (on_connected_ fires then, not at accept). A discovery thread answers `DiscoveryRequest` broadcasts on UDP `<tcp_port>`. Input callbacks only accept the client that owns the streams, and the host releases held buttons/keys when that client goes away. Frame numbers keep growing across restarts of a monitor's stream (`frame_high_water`), and STREAM_START carries `first_frame`, so the client can drop late frames of the previous stream.

Per-stream codec resolution follows a fallback chain, both at the CLI-default level and per-stream: requested codec (H.264/H.265/AV1 via `create_hw_encoder()`) → H.264 → software MJPEG (`stb_image_write`, always available). The effective codec actually used is announced back to the client in `StreamStart.codec`, which may differ from what was requested.

Mouse input arrives in *stream* pixel coordinates (which can be downscaled from native via `STREAM_CONFIG.max_width`); `main.cpp` keeps a per-monitor `input_scale` map to convert back to native pixels before calling `InputInjector::inject_mouse`.

Each stream worker makes its own capture instance, so backends only ever serve one monitor per instance. The worker restarts a capture that reports `is_capturing() == false` (monitor unplugged, screen-share revoked) and rescales any frame whose size differs from the announced stream size (unless the encoder `scales_input()`; captures that can scale for free honour the `set_output_size()` hint). Event-driven captures deliver nothing on a static desktop, so the worker keeps the newest frame: a frame skipped by FPS pacing is sent once the pacing allows, a REQUEST_KEYFRAME re-encodes it as an IDR at once, and an idle stream re-sends it as an IDR every second. The `--stub` capture mimics that (one frame, then nothing), so the tests exercise this path. Keyboard `scancode` is a Windows VK code on every OS; `main.cpp` presses Shift/Ctrl/Alt around a key from the client's `modifiers` bits (the VR keyboard latches them locally), and non-Windows injectors translate VKs (`input/vk_keysym.h` for X11/Wayland, a kVK table in `mac_input.mm`).

Source layout: `capture/` (`wgc_capture.cpp`/`dxgi_capture.cpp` Windows, `mac_capture.mm`, `x11_capture.cpp`, `portal_session.cpp` + `pipewire_capture.cpp` for Wayland, `linux_backends.cpp` = which Linux backend runs, `stub_capture.cpp`), `encoder/` (`encoder.cpp` = MJPEG software path, `mf_encoder.cpp` = Media Foundation HW path for NVENC/AMF/QSV, `vt_encoder.mm` = VideoToolbox, `ffmpeg_encoder.cpp` = Linux NVENC/VAAPI/libx264; all obey the output contract documented in `encoder.h` — one access unit per `encode()`, Annex-B/OBU, parameter sets on every IDR, no B-frames, BT.601 limited), `network/` (`server.cpp` — TCP control channel, UDP packetisation and send, flow control), `input/` (`input_injector.cpp` SendInput, `mac_input.mm`, `x11_input.cpp`, `portal_input.cpp`), `driver/` (`idd_manager.cpp` — IDD virtual-display detection, see below), `audio/` (`audio_capture.cpp` WASAPI, `mac_audio_capture.mm`, `pulse_audio_capture.cpp`). `src/` is on the include path for private headers shared between backends.

On a Wayland session capture and input share one process-wide portal session (`portal_session.cpp`, libdbus): RemoteDesktop+ScreenCast, persisted with a restore token in `~/.config/immersive2/portal-restore-token` so only the first run shows the dialog; X11 is never used as a silent fallback there (it would capture black). Virtual displays made on a headset's request (`IVirtualDisplayManager` in `driver/idd_manager.h`, ids from `VIRTUAL_MONITOR_ID_BASE` = 100, at most 4, removed on exit): X11 adds RandR 1.5 monitors (`x11_capture.cpp`, the screen grows to the right), GNOME Wayland uses Mutter's ScreenCast RecordVirtual (`mutter_virtual.cpp`), macOS the private `CGVirtualDisplay` looked up at run time (`mac_capture.mm`, untested: CI only compiles it), `--stub` fakes them in grey 208; Windows and other desktops answer VDISPLAY_UNSUPPORTED. IDD detection is Windows-only.

### IDD virtual display detection

`idd_manager.cpp` looks for a device whose hardware ID starts with `Root\VID_IDD` via `SetupDiGetDeviceRegistryProperty(SPDRP_HARDWAREID)`, with a secondary fallback check for any monitor device whose friendly name contains "virtual". If neither matches, `is_driver_installed()` returns false and the host just uses physical monitors — this is optional, not required for normal operation. `is_driver_installed()` is a pure query; the signature-trust bypass lives in `install_idd_signing_certificate()` and only runs from `--install-idd-cert`. Driver install/build instructions are in `docs/IDD_DRIVER.md` (it relies on a third-party community driver, `itsmikethetech/Virtual-Display-Driver`, and Windows test-signing).

### VR Client (Godot)

`client/project/scripts/main.gd` is the scene controller: connection state, auto-reconnect (to the last PC, following it via discovery if its IP changes), PIN pairing (pins per PC in the config's `[pairing]`), monitor selection, the arc arrangement / recenter (`pose_recentered` too), and automatic workspace persistence (layouts per monitor id, kept across STREAM_STOP/START so quality changes don't move screens; a saved layout far off the gaze is swung back in front). It is the only writer of `user://immersive2_config.cfg`. `host_discovery.gd` lists PCs from UDP broadcast replies. Automatic USB: on Android (or with `--im2-usb-port`) `usb_probe.gd` sends a HELLO to 127.0.0.1:<port> every 2 s unless already on the cable or the user pressed Disconnect; a HELLO_ACK makes `main.gd` move the session there (`_switch_to`, handled like a drop so screens stay), and losing the USB session falls straight back to `_lan_ip` (the PC's network address, which is also what the config keeps as `host_ip`). At launch it waits for the first probe before auto-connecting over Wi-Fi. The menu's status line says "over USB" / "over Wi-Fi". `screen_panel.gd` builds each screen's mesh itself — a flat quad or a cylinder section whose arc is `curvature × 1.75 rad` — and does the matching ray/cylinder hit test; the shaders only round the corners (no ALPHA write: screens are opaque). `laser_drag.gd` moves screens, menu and keyboard (grabbed point stays on the ray, object faces the head, never rolls). `world.gd` + `sky.gdshader`/`floor.gdshader` are the surroundings. `ui_theme.gd` holds the palette/type shared with the web page (Grotesk from Velvetyne, SIL OFL, in `fonts/`, for the wordmark and big titles only). `network_client.gd` owns the TCP control connection + UDP video/audio sockets and latency probing. `screen_panel.gd` is a draggable/resizable 3D panel; `main.gd` owns one `video_decoder.gd` per monitor stream. `video_decoder.gd` wraps the `Im2VideoDecoder` Android plugin (MediaCodec) in a **zero-copy** path: MediaCodec decodes straight into a Godot `ExternalTexture` (a `GL_TEXTURE_EXTERNAL_OES` object) via a `SurfaceTexture`, and the panel's `screen_external.gdshader` samples it through `samplerExternalOES` — no CPU readback, no YUV unpacking. `SurfaceTexture.attachToGLContext`/`updateTexImage` must run on Godot's render thread, so they are scheduled via `RenderingServer.call_on_render_thread()` (driven each frame from `main.gd._update_decoders`). `VideoDecoder.is_codec_supported()` returns false without the plugin (PC/iOS/web); there `main.gd` instead opens a `SoftwareVideoDecoder` (`software_video_decoder.gd`) that decodes the MJPEG stream on a `WorkerThreadPool` thread and uploads the result via `screen_panel.gd::update_decoded_image()` — `_update_decoders` polls both decoder kinds each frame. `vr_input.gd` (one per controller; the last one whose trigger was pressed owns the pointer) / `hand_input.gd` handle controller and hand-tracking pointer input; `ui_overlay.gd` is the in-VR menu (tabs Connect / Screens / Space / Quality, PIN keypad; holds no settings, main.gd pushes them in); `virtual_keyboard.gd` is the VR keyboard (a 2D UI in a SubViewport; one-shot Shift/Ctrl/Alt/Win, key repeat); `key_map.gd` maps a Bluetooth keyboard's keys to VK codes (forwarded on Android only — on a PC client the keyboard already belongs to a PC). Controller vibration goes through the `haptic` action (action_type 4, `/user/hand/*/output/haptic` in every profile of `openxr_action_map.tres`) via `vr_input.gd::_buzz()`, gated by `main.gd::haptics_enabled`. `main.gd::_can_control()` (the user's "Control this PC" switch and the host's HOST_FLAG_VIEW_ONLY) gates every mouse/keyboard send. With "Sharper text" on and a runtime that composites layers natively, each `screen_panel.gd` drives an `OpenXRCompositionLayerCylinder`/`Quad` placed under XROrigin3D (fed from a SubViewport: the CPU texture, or the OES texture through `screen_layer_external.gdshader`), hole-punched behind Godot's projection layer, with its own mesh hidden (`layers = 0`) but still used for ray hits — untested on a headset, so it is opt-in. Virtual screens: the menu asks via VIRTUAL_DISPLAY_CREATE; `main.gd` shows the new monitor once both VIRTUAL_DISPLAY_RESULT and the re-sent MONITOR_LIST (per-monitor flags byte, MONITOR_FLAG_VIRTUAL) have arrived; `--im2-virtual=WxH` does that from the command line for tests; `audio_receiver.gd` decodes the UDP PCM audio stream into an `AudioStreamGenerator`.

The Android decoder plugin is a separate Gradle/Java project at `client/android-plugin/` (not part of the Godot project tree) producing an AAR consumed via the `addons/im2_decoder` export plugin (an `EditorExportPlugin` that adds the AAR via `_get_android_libraries`).

### Protocol

TLV control messages over TCP (`uint8 type, uint32 length LE, payload`), chunked binary frames over UDP (monitor id, frame number, chunk index/count, ≤1400-byte payload). Default ports: TCP 19800 (control), UDP 19801 (video), UDP 19802 (audio, PCM-16 stereo 48kHz). All message types/struct layouts are defined once in `protocol/protocol.h` — extend that file first when adding a new message, then mirror the struct packing manually in GDScript (the client has no codegen from the header).

## Code Style (from CONTRIBUTING.md)

- **C++ (host):** C++17, `snake_case` functions/variables, `PascalCase` classes/types, `SCREAMING_SNAKE_CASE` constants, trailing/leading `_` for private members, `#pragma once` guards.
- **GDScript (client):** follow the official GDScript style guide, use type hints, document public functions with `##` doc comments.
