# Session: Pixel streaming for remote screen panels

## What this session implements

Right now `remote_screen_panel.gd` renders a dark-blue placeholder with a `Label3D`
showing "Monitor N · WxH". The sharer's actual pixel content is never sent to remote
users.  This session wires up real video for the remote panels.

## Context

- The host already streams per-monitor video to the *local* client over UDP.
- The signaling server already relays arbitrary JSON and offers a WebRTC data-channel
  path (see `signaling/server.py` and `webrtc_manager.gd`).
- `remote_screen_panel.gd` has a `monitor_id` and `resolution` field ready to receive
  frames.  Its `_mesh` / material are already in place.
- The `screen_panel.gd::update_texture(frame_data, width, height)` and
  `update_decoded_image(img)` API can be copied to `remote_screen_panel.gd`.

## Approach

1. **WebRTC video track per shared monitor** — when user A shares monitor 7, open a
   WebRTC data channel named `"screen_7"` toward each peer in the room.  The sending
   side reads frames from the existing per-monitor decoder output (or directly from
   `network_client.gd`'s video frame callback) and writes them into the channel.
   Receiving side: `remote_screen_panel.gd` opens the inbound channel, decodes MJPEG
   with `SoftwareVideoDecoder` (same path as PC local decode), uploads via
   `update_decoded_image()`.

2. **Simpler alternative (P2P only):** re-use the existing UDP video stream.
   The sharer is already decoding frames — instead of discarding them, re-send the
   raw JPEG over a second UDP port to each peer (added to `network_client.gd`'s fan-out).
   Simpler to implement; breaks in SFU relay mode (3+ users) where the server would
   need to relay the video stream too.

3. **SFU relay for 3+ users:** `server.py` would need to accept a video data channel
   per shared monitor from the sharer and relay it to every other participant.  This is
   the largest piece of work but required for correct multi-user behaviour.

## Files to touch

| File | Change |
|---|---|
| `client/project/scripts/remote_screen_panel.gd` | Add `update_texture()` / `update_decoded_image()` and a `SoftwareVideoDecoder` instance |
| `client/project/scripts/remote_user.gd` | Open inbound WebRTC data channel `"screen_<mid>"` per panel and feed frames to panel |
| `client/project/scripts/webrtc_manager.gd` | Expose `open_data_channel(peer_id, label)` for video channels |
| `client/project/scripts/main.gd` | On `_on_remote_screen_share`, open outbound video channels to affected peers |
| `signaling/server.py` | (SFU path only) Relay video data-channel messages per monitor |

## Tests to add

- `test_remote_screen_panel.gd`: `update_decoded_image` uploads a solid-colour image
  and the panel's texture colour matches.
- `test_main_integration.gd`: end-to-end video channel open → frame delivered to panel.
