# Immersive-2 Wire Protocol

`protocol.h` in this directory is the **single source of truth** for the wire
format: message type values, struct layouts and packing, default ports. The
C++ host includes it directly; the GDScript client mirrors the same layouts by
hand in `client/project/scripts/network_client.gd`, and the Node bridge in
`web/bridge/bridge.js` does the same in JavaScript. Any new message goes into
`protocol.h` first.

The prose reference — channels, per-message field tables, the connection
sequence, reassembly rules — lives in [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md).

This file used to carry a second, partial copy of that reference. It drifted
(seven message types, the audio channel and a mouse field were missing), so it
is now just this pointer: one place to maintain, one place to trust.
