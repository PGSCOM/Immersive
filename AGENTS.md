# AGENTS.md — Operating rules for opencode agents

This file is auto-loaded by opencode for **every** agent in this repo. It is the
contract all agents must follow. Project-specific architecture lives in
`CLAUDE.md`, `docs/ARCHITECTURE.md` and `docs/PROTOCOL.md` (also auto-loaded).

## 0. Golden rule: nothing is "done" until it is tested and green

An agent may **never** report a task as finished, complete, or working unless it
has actually run the relevant tests/build and observed them pass. "It should
work" is not acceptance. If you cannot run a test, say so explicitly and mark the
task **blocked**, not done.

## 1. Mandatory testing protocol

Every feature, fix, or refactor must ship with tests **and** a passing run:

- **Godot / GDScript tests MUST be launched with `--xr-mode off`.** Without it
  the headless run shows an XR warning and does **not** continue automatically,
  so the test hangs/blocks. Canonical command:

  ```bash
  godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
  ```

  (Use the project's existing test runner / GUT / GdUnit4 entrypoint; if none
  exists, create one under `client/project/test/`.) Always pass
  `--headless --xr-mode off` for any non-interactive Godot invocation, including
  exports and smoke runs.

- **C++ host:** build with hardware encoders OFF for CI/local
  (`-DENABLE_NVENC=OFF -DENABLE_AMF=OFF -DENABLE_QSV=OFF`) and exercise the
  protocol with `python host/tools/smoke_client.py` (connects from `127.0.0.2`).
  Add new unit/integration tests next to the code they cover.

- **Networking (P2P / SFU / signaling):** add automated integration tests that
  spin up N simulated peers (2 = P2P mesh, 3+ = SFU) and assert connection,
  track subscription, and topology migration. Do not rely on manual testing only.

- **Decoders:** verify hardware decode is actually selected (not a silent
  software fallback) per platform and per codec — assert on the negotiated codec
  and the active decoder path in a test, log it explicitly.

Run the **full** relevant suite before handing back. Paste the command(s) you ran
and a short result summary into your final message.

## 2. Definition of Done (checklist every task must satisfy)

1. Code compiles / the Godot project opens with no new errors.
2. New + existing tests pass (command + output shown).
3. `godot --headless --xr-mode off ...` used for any Godot run.
4. No secrets, no PII, no personal data logged or persisted (see §4).
5. Public functions documented (`##` GDScript doc comments, C++17 style).
6. Docs updated (`README.md` / `docs/*`) when behavior or protocol changes.
7. `protocol/protocol.h` updated **first** for any new wire message, then the
   GDScript mirror — they must stay byte-compatible.

## 3. Code style (from CONTRIBUTING.md)

- **C++17 (host):** `snake_case` funcs/vars, `PascalCase` types,
  `SCREAMING_SNAKE_CASE` constants, leading/trailing `_` for privates,
  `#pragma once`.
- **GDScript (client):** official GDScript style guide, type hints everywhere,
  `##` doc comments on public functions.

## 4. Privacy & security are first-class requirements

- Minimize data collected; never log PII, IPs tied to identity, screen contents,
  or credentials. Prefer ephemeral, in-memory identifiers.
- Media between peers must be encrypted (WebRTC SRTP/DTLS by default; pursue
  end-to-end encryption where the SFU only routes and never decrypts).
- Screen sharing is **opt-in and revocable** per screen; a user must always be
  able to see and control what they expose.
- Signaling/SFU servers must not retain media or identity beyond session scope.

## 5. Delegation model

- Primary agents (`build`, `plan`) own the conversation and **delegate** focused
  work to subagents via the task tool / `@agent` mentions.
- Subagents stay in their lane (their file's description), return concise results,
  and must respect this whole file. They do not silently expand scope.

## 6. Network topology decision (locked)

- **1–2 users:** direct **P2P mesh** (no media server).
- **3+ users:** **SFU** server routes streams.
- Migration across the boundary (the 3rd user joining / dropping to 2) must be
  automatic and seamless. The threshold lives in one config constant.
