# Session: Signaling auto-reconnect + codec fallback toast

## What this session implements

Two independent robustness gaps:

### 1. Signaling auto-reconnect

`signaling_client.gd` declares `_reconnect_timer` and `_reconnect_interval` but they
are never driven.  When the connection drops, `set_process(false)` is called and no
recovery is attempted.  The host connection (`network_client.gd`) already has full
auto-reconnect; the signaling client needs the same treatment.

### 2. Codec fallback notification

When `main.gd::_request_codec_fallback()` degrades (e.g. AV1 → MJPEG because the
MediaCodec plugin is absent), `push_warning()` is called but no visible feedback
appears in the overlay.  The user has no idea the codec changed, which is confusing
when quality is visibly lower than configured.

## Context

- `signaling_client.gd`: look for `_reconnect_timer`, `_reconnect_interval`,
  `_on_connection_closed()`.  The reconnect variables exist but `_process()` ignores them.
- `main.gd::_request_codec_fallback()` (line ~965): calls `push_warning` and
  `stream_codec = fallback` but never updates the overlay.
- `ui_overlay.gd::set_stream_settings()` already reflects the codec in the UI — just
  call it after the fallback resolves.  A transient toast (a `Label` that fades after
  3 s) would also be useful.

## Approach: signaling reconnect

In `signaling_client.gd::_process(delta)` (create if missing), increment
`_reconnect_timer` when disconnected and `_should_reconnect` is true; when it
exceeds `_reconnect_interval`, reset and call `connect_to_server()`.  Mirror the
pattern from `network_client.gd::_handle_reconnect()`.  Also set `_should_reconnect =
true` on explicit `connect()` and `false` on explicit `disconnect()`.

## Approach: codec fallback toast

In `main.gd::_request_codec_fallback()`, after updating `stream_codec`:
```gdscript
if ui_overlay and ui_overlay.has_method("show_toast"):
    ui_overlay.show_toast("Codec fallback: %s → %s" % [original_name, fallback_name])
if ui_overlay and ui_overlay.has_method("set_stream_settings"):
    ui_overlay.set_stream_settings(stream_codec, stream_bitrate_kbps,
        stream_jpeg_quality, stream_res_percent, stream_fps)
```

Add `show_toast(text: String, duration_s: float = 3.0)` to `ui_overlay.gd`: a `Label`
positioned at the bottom of the panel that starts visible with the text and fades/hides
after `duration_s` seconds using a `Timer`.

## Files to touch

| File | Change |
|---|---|
| `client/project/scripts/signaling_client.gd` | Drive `_reconnect_timer` in `_process()`; set flag on connect/disconnect |
| `client/project/scripts/main.gd` | Call `show_toast` + `set_stream_settings` from `_request_codec_fallback()` |
| `client/project/scripts/ui_overlay.gd` | Add `show_toast(text, duration)` — a fading Label with a Timer |

## Tests to add

- `test_signaling_client.gd`: after `_on_connection_closed()`, `_reconnect_timer`
  increments each `_process()` call and `connect_to_server` is called once the
  interval elapses.
- `test_ui_overlay.gd`: `show_toast("hello")` makes the toast label visible and
  non-empty; after the timer fires, it is hidden.
