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
- `GET /stream.h264` -> low-latency H.264 stream for the WebXR/WebCodecs client
- `GET /stream.mjpg` -> MJPEG stream endpoint (2D preview)
- `GET /frame.jpg` -> latest frame snapshot (MJPEG only)

## Codec negotiation

The host streams a single codec at a time. The bridge picks it based on which
kind of reader is attached and sends a `STREAM_CONFIG` to switch:

- A `/stream.h264` reader (the WebXR scene) -> the bridge requests **H.264** and
  asks for a keyframe. The VR client decodes it with the WebCodecs `VideoDecoder`
  (hardware) and renders each frame to the panel texture.
- Only `/stream.mjpg` readers (the 2D preview) -> the bridge requests **MJPEG**.

Because there is one host codec at a time, opening the WebXR scene pauses the
2D MJPEG preview until the VR reader disconnects.

The `/stream.h264` body is a sequence of framed Annex-B access units:
`[uint32 LE payload length][uint8 flags][payload]`, where `flags` bit0 marks a
keyframe.

## Notes

- The WebXR client prefers H.264 + WebCodecs and automatically falls back to the
  MJPEG path if `VideoDecoder` is unavailable or the host can't produce H.264.
- For best WebXR compatibility, use a Chromium-based browser on a headset with
  WebXR enabled (Quest Browser / Pico Browser both support WebCodecs).
