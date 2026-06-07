## Immersive-2 VR Client

Godot 4.6.3+ project for Meta Quest and Pico 4 headsets.

### Setup

1. Install [Godot 4.6.3+](https://godotengine.org/download) with Android export templates
2. Open this folder as a Godot project
3. Make sure the OpenXR plugin is enabled (Project → Project Settings → XR)
4. Configure Android export (Project → Export → Android)
5. Enable Quest/Pico XR features in the export preset

### Project Structure

```
project/
├── project.godot           # Godot project configuration
├── scenes/
│   └── main.tscn           # Main VR scene
├── scripts/
│   ├── main.gd             # Main scene controller
│   ├── network_client.gd   # TCP/UDP network client
│   ├── video_decoder.gd    # Video frame decoder
│   ├── screen_panel.gd     # Virtual screen panel in 3D
│   └── vr_input.gd         # VR input handling
└── shaders/
	└── screen.gdshader     # Screen rendering shader
```

### How It Works

1. The client connects to the Windows host over TCP (port 19800)
2. It receives a list of available monitors
3. User selects a monitor to view
4. Host starts streaming encoded video over UDP (port 19801)
5. Client decodes and displays the video on a floating 3D panel
6. VR controller input is sent back to the host for injection
