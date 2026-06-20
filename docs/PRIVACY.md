# Privacy Model for Immersive-2 Multi-User Sessions

## Overview

Immersive-2 is designed with privacy as a first-class requirement. This document describes the privacy model for multi-user shared VR workspaces, covering data minimization, screen sharing consent, encryption, and logging practices.

---

## Core Principles

### 1. Data Minimization
- **Ephemeral identifiers only**: Session IDs, user IDs, and monitor IDs are generated per-session and never persisted.
- **No PII collection**: The system does not collect, store, or transmit personally identifiable information (names, emails, IPs linked to identity, hardware serials).
- **No screen content logging**: Frame data, pixel values, or decoded images are never logged.
- **No credential handling**: Authentication tokens, passwords, or certificates never touch application logs.

### 2. Opt-In Consent Model
- **Per-monitor granularity**: Each physical/virtual monitor must be explicitly shared by the user.
- **Default deny**: No monitor is shared unless the user takes affirmative action.
- **Revocable at any time**: Sharing can be stopped instantly with immediate effect.
- **Clear UI indicators**: Users always- The UI shows exactly which monitors are shared, with name and resolution.

### 3. End-to-End Encryption (E2EE)
- **Media encryption**: All video/audio streams use DTLS-SRTP. In multi-user (SFU) mode, Insertable Streams / SFrame provides E2EE so the SFU routes but cannot decrypt.
- **Key exchange**: Per-session ECDH key agreement; keys rotated periodically.
- **Forward secrecy**: Compromise of long-term keys does not reveal past sessions.

### 4. No-PII Logging
- **Structured logging**: All log statements use ephemeral session IDs and opaque monitor IDs.
- **Redacted fields**: IPs, usernames, display names, and screen metadata never appear in logs.
- **Audit enforced**: Automated test (	est_privacy.gd::test_no_pii_in_logs) scans source for forbidden patterns.

---

## Screen Sharing Consent Flow

`
+-----------------------------------------------------------------+
¦                        USER ACTION                              ¦
¦  1. User opens UI overlay ? sees  Monitors section             ¦
¦  2. Each monitor shows: [?] Monitor Name — 1920x1080 @ 60 Hz   ¦
¦  3. User taps a monitor ? checkbox becomes [?] (shared)         ¦
¦  4. PrivacyManager.share_monitor(monitor_id) called             ¦
¦  5. Signal monitor_share_changed emitted ? UI updates           ¦
¦  6. Network layer sends SCREEN_SHARE_STATE to signaling server  ¦
¦  7. Remote peers receive REMOTE_SCREEN_LAYOUT + stream starts   ¦
+-----------------------------------------------------------------+
                              ¦
                              ?
+-----------------------------------------------------------------+
¦                      REVOCATION FLOW                            ¦
¦  1. User taps shared monitor [?] ? becomes [?]                  ¦
¦  2. PrivacyManager.unshare_monitor(monitor_id) called           ¦
¦  3. Signal monitor_share_changed emitted ? UI updates           ¦
¦  4. Network layer sends SCREEN_SHARE_STATE (enabled=false)      ¦
¦  5. Host stops streaming that monitor (STREAM_STOP)             ¦
¦  6. Remote peers stop receiving frames within one frame period  ¦
+-----------------------------------------------------------------+
                              ¦
                              ?
+-----------------------------------------------------------------+
¦                    EMERGENCY STOP (Revoke All)                  ¦
¦  1. User presses Stop All Sharing button                      ¦
¦  2. PrivacyManager.revoke_all_sharing() called                  ¦
¦  3. All monitors unshared atomically                            ¦
¦  4. all_sharing_revoked signal emitted                          ¦
¦  5. Network layer sends SCREEN_SHARE_STATE for each monitor     ¦
¦  6. All streams stop immediately                                ¦
+-----------------------------------------------------------------+
`

---

## Data Flow & What Is Shared

| Data | Shared With | Encryption | Retention |
|------|-------------|------------|-----------|
| Monitor metadata (name, resolution) | Room participants | E2EE (signaling) | Session only |
| Video frames (encoded) | Room participants | DTLS-SRTP / SFrame | Transient (buffered ms) |
| Audio frames (PCM) | Room participants | DTLS-SRTP / SFrame | Transient (buffered ms) |
| Pose data (head/hands) | Room participants | E2EE (data channel) | Session only |
| Screen share state (bool per monitor) | Room participants | E2EE (signaling) | Session only |
| Ephemeral session ID | Local only | N/A | Memory only |
| Ephemeral user ID (per room) | Room participants | E2EE | Session only |

**Never shared:**
- Host IP address (only via signaling relay)
- OS username, hostname, hardware IDs
- File paths, window titles, clipboard contents
- Input keystrokes/mouse coordinates (only injected locally on host)

---

## Threat Model

### Adversaries Considered
1. **Passive network observer** (Wi-Fi sniffing) ? Mitigated by DTLS-SRTP / TLS
2. **Compromised signaling server** ? Cannot decrypt media (E2EE); sees only metadata
3. **Compromised SFU** ? Routes encrypted packets only; no decryption keys
4. **Malicious room participant** ? Receives only what user explicitly shares
5. **Malware on host PC** ? Out of scope (local compromise)

### What Must Never Leak
| Asset | Protection |
|-------|------------|
| Screen contents (pixels) | E2EE media; never logged |
| Identity ? IP linkage | Signaling relay hides direct IPs; no persistent IDs |
| Credentials / tokens | Never handled by app; OAuth/external auth only |
| Raw pose history | Not stored; transient in-memory only |
| Monitor layout (positions) | Shared only with consent; E2EE |

---

## Implementation Components

### PrivacyManager (client/project/scripts/privacy_manager.gd)
Central authority for sharing state:
- egister_monitor(id, name, w, h) — Called on MONITOR_LIST receipt
- share_monitor(id) / unshare_monitor(id) — Opt-in/opt-out per monitor
- evoke_all_sharing() — Emergency stop
- get_sharing_summary() — UI data (name, resolution, shared state)
- eset() — Called on disconnect/room leave; clears all state
- **Signals**: monitor_share_changed(id, shared), ll_sharing_revoked

### Network Integration
- signaling_client.gd::send_screen_share_state() — Sends SCREEN_SHARE_STATE (protocol 0x55)
- Host receives ? starts/stops per-monitor streams via STREAM_START/STREAM_STOP
- Remote clients receive REMOTE_SCREEN_LAYOUT (0x56) ? build RemoteScreenPanels

### UI Integration (ui_overlay.gd)
- Monitor list shows [?] shared / [?] not shared with tap-to-toggle
- Stop All Sharing button calls evoke_all_sharing()
- Privacy notice acknowledgment required before first share

---

## Log Audit Rules (Enforced by Test)

**Forbidden in any print(), push_warning(), push_error():**
- ip, ddress, identity, username, password, 	oken
- email, 
ame (except variable names), screen, content
- pixel, rame (except frame numbers), credential, secret
- key, certificate (except keyframe/IDR context)

**Required in every log line:**
- session=<ephemeral_id> or session_id — correlates without identity
- monitor=<opaque_id> or monitor_id — identifies stream without metadata

**Example compliant log:**
`
[Privacy] session=priv_a1b2c3d4 monitor=1 shared=True
[Network] STREAM_START: monitor=1 1920x1080 codec=2
`

**Non-compliant (would fail audit):**
`
[Privacy] User Alice shared monitor Dell U2719D at 192.168.1.50
[Network] Streaming 1920x1080 from IP 10.0.0.5
`

---

## Configuration Constants

| Constant | Value | Description |
|----------|-------|-------------|
| MAX_SHARED_MONITORS | 3 | Matches MAX_SCREENS in main.gd |
| P2P_MAX_USERS | 2 | Topology threshold (mesh ? SFU) |

---

## Testing

Run privacy tests headless:
`ash
godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
`

The test suite (	est_privacy.gd) verifies:
1. PrivacyManager instantiation and API surface
2. Monitor registration and metadata retrieval
3. Opt-in sharing (idempotent, unknown monitor rejected)
4. Immediate revocation (per-monitor and all)
5. Maximum 3 concurrent shared monitors
6. UI summary data structure
7. Privacy acknowledgment flow
8. Full state reset on disconnect
9. **Log audit**: No PII patterns in privacy_manager.gd
10. Session ID is ephemeral and rotates on reset

---

## Compliance Checklist

- [x] Screen sharing is opt-in per screen
- [x] Clear indicator of what is being shared (UI + summary API)
- [x] Immediate effect on revocation (signals + network message)
- [x] No PII logging (automated audit test)
- [x] Ephemeral identifiers only (session ID, user ID, monitor ID)
- [x] E2EE media path (DTLS-SRTP + SFrame for SFU)
- [x] Data minimization (no persistence, no screen content logs)
- [x] Consent acknowledgment required before sharing

---

## Future Enhancements

1. **Per-application window sharing** (instead of full monitor)
2. **Blur/redact regions** before encoding (client-side)
3. **Audit log export** for user transparency (local only)
4. **Hardware-backed attestation** for E2EE key verification
5. **Differential privacy** for pose/telemetry aggregation

---

*Last updated: 2026-06-20 | Implements Milestone 7 of MULTIUSER_ROADMAP.md*
