# Immersive-2 Web Client (WebXR)

This folder contains an experimental browser client for Immersive-2.

## Components

- `client/`: Static web UI + WebXR scene. `client/fonts/` holds Grotesk by
  Frank Adebiaye (Velvetyne), SIL Open Font License 1.1, license file alongside
- `bridge/bridge.js`: Node.js bridge that connects to the native host protocol (TCP/UDP)
  and exposes a browser-friendly HTTP/MJPEG interface

## Quick Start

1. Start the native host (`immersive2_host`) on your PC.
2. Start the web bridge:

```bash
node web/bridge/bridge.js --connect --host 127.0.0.1 --tcp-port 19800 --udp-port 19801 --port 19810
```

3. Open:

- `http://localhost:19810/` on the PC for the controls and the live preview
- the `On the headset` address the bridge prints (and the page shows) in the
  headset's browser, for the WebXR scene

## Options

| Option | Description |
| --- | --- |
| `--port N` | HTTP port of the bridge (default 19810) |
| `--host IP`, `--tcp-port N`, `--udp-port N` | Host to connect to (default 127.0.0.1:19800/19801) |
| `--monitor N` | Monitor to stream first |
| `--connect` | Connect on startup |
| `--pin N` | The host's 6-digit pairing PIN. Only needed when the host is another PC: the host lets connections from 127.0.0.1 in without one |
| `--open` | Serve the LAN without the access key (see below) |

## Access from other devices

The bridge talks to the host from 127.0.0.1, which the host trusts without a
PIN, and re-serves the desktop over HTTP. So it does not serve the whole LAN
blindly: requests from the PC itself always work, anything else needs the
random key in the address printed at startup
(`http://<pc-ip>:19810/vr.html?key=...`). The first request with the key sets a
cookie, so the rest of the page just works. The key changes every time the
bridge starts. `--open` turns this off.

Whatever the address, the bridge refuses POSTs and the `/input` WebSocket
coming from a page of another site (their `Origin` must be the bridge
itself): otherwise any website open in the PC's browser could click and type
on the PC through `localhost`.

## Pairing

A host on another PC asks for its PIN (printed in the host's console). Pass it
with `--pin`, or type it in the page when it asks. A wrong PIN is not retried
on its own; the bridge only reconnects by itself when the host goes away or is
full, every 3 seconds.

## Input (WebXR scene)

The WebXR scene (`vr.html`) drives the PC:

- **Controllers:** point at the screen. The trigger is the left button (hold to
  drag), a short grip squeeze right-clicks, the thumbstick scrolls (faster the
  further you push). The last controller whose trigger was pressed holds the
  pointer; the other hides its ray.
- **Mouse** (the scene viewed flat, no headset): click, drag, right-click and
  wheel on the screen; dragging anywhere else still turns the view.
- **Keyboard:** keys typed while the scene has focus go to the PC (US key
  positions; the PC applies its own layout). WASD walking is off for that.

Input travels over a WebSocket at `/input` (JSON events), with `POST
/api/input` as the fallback; both sit behind the same access key as the pages.
A closed tab releases whatever it held down. The host only takes input from
the client that owns the streams, so the bridge must be the one that last
picked a monitor.

## View-only hosts

A host started with `--view-only` shares its screens but ignores clicks and
keys. The bridge reads that from the host's handshake (`viewOnly` in
`/api/status`): the scene then sends nothing and says so, and the control page
shows "view only" next to the status. Virtual monitors the host made on
request are marked "virtual" in the monitor list.

## Bridge API

- `GET /api/status` -> bridge + host connection status (includes `pinRequired`,
  `rejectReason`, `hostName`, `viewOnly`, `virtualDisplays`, `headsetUrls`;
  each monitor carries `virtual` and `primary`)
- `POST /api/connect` -> connect bridge to host (`host`, `tcpPort`, `udpPort`,
  `monitorId`, optional `pin`)
- `POST /api/disconnect` -> disconnect bridge from host
- `POST /api/select-monitor` -> select monitor id
- `GET /input` (WebSocket) / `POST /api/input` -> input events: `{t:"m", u, v, b,
  sy, sx}` (pointer at u,v in 0..1 from the top-left, button mask 1/2/4, wheel
  units with 120 a notch) and `{t:"k", vk, p}` (Windows VK code, pressed 1/0).
  POST also takes an array
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
