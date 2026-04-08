# Immersive-2 Web Client (WebXR)

This folder contains an experimental browser client for Immersive-2.

## Components

- `client/`: Static web UI + WebXR scene
- `bridge/bridge.js`: Node.js bridge that connects to the native host protocol (TCP/UDP)
  and exposes a browser-friendly HTTP/MJPEG interface

## Quick Start

1. Start the native host (`immersive2_host`) on your PC.
2. Start the web bridge:

```bash
node web/bridge/bridge.js --connect --host 127.0.0.1 --tcp-port 19800 --udp-port 19801 --port 19810
```

3. Open:

- `http://localhost:19810/` for desktop web controls and stream preview
- `http://localhost:19810/vr.html` for the WebXR scene

## Bridge API

- `GET /api/status` -> bridge + host connection status
- `POST /api/connect` -> connect bridge to host
- `POST /api/disconnect` -> disconnect bridge from host
- `POST /api/select-monitor` -> select monitor id
- `GET /stream.mjpg` -> MJPEG stream endpoint
- `GET /frame.jpg` -> latest frame snapshot

## Notes

- The browser path currently expects MJPEG-compatible frames from the host stream.
- For best WebXR compatibility, use a Chromium-based browser on a headset with WebXR enabled.
