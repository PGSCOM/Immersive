# Session: Privacy consent + E2EE wiring

## What this session implements

Two related privacy features that exist as dead code and need to be activated:

1. **Privacy acknowledgement flow** — `PrivacyManager` has `acknowledge_privacy_notice()`
   and `is_privacy_acknowledged()` but the overlay never checks them.  The intent
   (show the user a one-time consent screen before they can share a monitor) is not
   enforced.

2. **E2EE dead file** — `e2ee_crypto.gd` implements encryption/decryption with a
   shared key but is never instantiated or connected to any signal path (voice frames,
   whiteboard strokes, screen layout messages).  Either wire it in or remove it.

## Context

- `privacy_manager.gd`: `share_monitor(id)` and `unshare_monitor(id)` work, but
  `acknowledge_privacy_notice()` / `is_privacy_acknowledged()` are never called.
- `e2ee_crypto.gd`: has `encrypt(data: PackedByteArray) -> PackedByteArray` and
  `decrypt(data: PackedByteArray) -> PackedByteArray`; no callers.
- `ui_overlay.gd`: the Monitors tab has a share toggle but no consent step.

## Approach: privacy notice

Gate `share_monitor()` in `privacy_manager.gd` behind `is_privacy_acknowledged()`.
If not acknowledged, call a new signal `privacy_notice_required` instead of sharing.
In `ui_overlay.gd`, connect that signal to show a modal dialog (a simple `VBoxContainer`
overlay inside the SubViewport with the notice text and an "I understand" button).
On confirm, call `privacy_manager.acknowledge_privacy_notice()` and retry the share.
Persist acknowledgement to `user://immersive2_config.cfg` `[privacy] acknowledged = true`
so it only shows once per install.

## Approach: E2EE

Decision point: wire it in or delete it.

**Wire in:** route all multiuser messages (whiteboard strokes, screen layout, voice frames)
through `e2ee_crypto.gd` in `multiuser_manager.gd` before sending / after receiving.
Requires key exchange (Diffie-Hellman or a pre-shared key set in the overlay).

**Delete:** remove `e2ee_crypto.gd`; add a comment in `CONTRIBUTING.md` noting it is
out of scope until a key-exchange protocol is defined.

Recommendation: **delete** for now. The dead file implies security that does not exist
and could mislead users.

## Files to touch

| File | Change |
|---|---|
| `client/project/scripts/privacy_manager.gd` | Gate `share_monitor()` on acknowledgement; emit `privacy_notice_required` |
| `client/project/scripts/ui_overlay.gd` | Modal consent dialog wired to `privacy_notice_required` |
| `client/project/scripts/main.gd` | Connect `privacy_notice_required` from privacy_manager → overlay |
| `client/project/scripts/e2ee_crypto.gd` | Delete (or wire — see decision above) |

## Tests to add

- `test_privacy_manager.gd`: `share_monitor()` before acknowledgement does not add to
  shared set; after acknowledgement it does.
- `test_ui_overlay.gd`: `privacy_notice_required` signal triggers the consent dialog.
