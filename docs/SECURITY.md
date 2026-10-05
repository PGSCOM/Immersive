# Security

What Immersive-2 protects, from whom, and how. The wire details are in
`docs/PROTOCOL.md`; this is the why.

## What is at stake

A paired headset sees the PC's screens and sound and can drive its mouse and
keyboard: whoever gets a session gets the desktop of whoever is logged in.
The PIN is what stands between the network and that, so it must not be
readable on the wire, nor guessable in practice.

## Who we defend against

| Attacker | Can | Before | Now |
|----------|-----|--------|-----|
| Passive, on the same Wi-Fi or LAN | Read every packet | Reads the PIN in HELLO, then pairs; reads the keys typed into the PC (INPUT_KEYBOARD), the screens and the sound | Sees TLS and sealed UDP only |
| Active on the LAN (ARP or DHCP spoofing, a rogue AP) | Sit between headset and PC | All of the above, and inject input | The first pairing is checked by the user (fingerprint next to the PIN); after it, the headset pins the PC's certificate, and a different one never gets the PIN |
| Guessing PINs | Connect many times, from many addresses | 5 per address per minute, unlimited addresses | Also slowed down for everyone past 20 a minute (5 s each), with a warning on the PC |
| A member of a multiplayer room | Send anything the room protocol allows | Bounded profiles and messages (`room.gd`); watchers see only what is shared, cannot send input | Unchanged |
| On the network, not in the room | Read packets | Reads the watch code in the watchers' HELLO, then watches the shared screens (UDP in the clear) | The share carries the PC's certificate: watchers connect pinned, and get sealed media |
| A process on the PC | Connect to 127.0.0.1 | Trusted (USB tunnel, local tools) | Unchanged: it already runs as the user |
| The internet | Reach the ports if forwarded | Same as the LAN | Same: TLS + PIN. Do not forward the ports anyway |

Out of scope: a compromised PC or headset, someone who can read the PC's
settings folder (they have the user's account), denial of service by flooding
the network.

## Design

### Transport

- **Control channel: TLS 1.2**, mbedTLS 3.6 LTS on the host (fetched by CMake,
  checked against its SHA-256), Godot's `StreamPeerTLS` (also mbedTLS) on the
  headset. Only ECDHE-ECDSA with AES-128-GCM, ChaCha20-Poly1305 or AES-256-GCM:
  forward secrecy and authenticated encryption. TLS 1.3 would be nicer, but
  1.2 keeps the host's TLS code simple (no post-handshake messages: a read
  never has to write) and Godot's mbedTLS speaks both.
- **UDP video and audio: sealed per client.** After the PIN, the host sends a
  random 48-byte `MEDIA_KEY` inside TLS; every datagram is then
  AES-128-CBC + HMAC-SHA-256 (encrypt-then-MAC, 128-bit tag, random IVs).
  Godot has `AESContext` and `HMACContext` but no AEAD, and doing it in
  GDScript is still cheap (about 8 µs per datagram on a desktop). The client
  drops anything that does not check, so a spoofed datagram can no longer
  paint the screen either.
- **Plain TCP only from 127.0.0.0/8**: the USB cable (`adb reverse`), and local
  tools and tests. From the network it is refused with
  `REJECT_ENCRYPTION_REQUIRED`; `--allow-plaintext` lets older apps in, and
  says so at start-up.

### Identity and pairing

The PC makes an ECDSA P-256 key and a self-signed certificate the first time
it runs (`identity-key.pem`, readable by the user only, and
`identity-cert.pem`, in the settings folder). Its fingerprint, 16 hex digits
(`C175 98B2 31A4 9F12`), is printed at start-up, shown in the settings panel
next to the PIN and in the PIN notification.

Godot's TLS can verify a peer against a given certificate but cannot show it
the certificate it got, so the host sends it in `IDENTITY` inside TLS. The
headset pairs in two steps, and the PIN only ever goes to a pinned session:

1. Not paired with this PC yet: connect, TLS without verifying, HELLO with no
   PIN. The host answers `IDENTITY` and "PIN required". The certificate is
   kept as a candidate.
2. The PIN prompt shows the candidate's fingerprint: "check the PC shows
   C175 98B2 31A4 9F12". The user types the PIN.
3. The headset reconnects **pinned to the candidate** (`TLSOptions.client`
   with it as the only trusted certificate) and sends the PIN. On HELLO_ACK
   the certificate is stored next to the PIN.

A machine in the middle cannot complete step 3 with the candidate it handed
out unless it holds the PC's key; if it relays the PC's real certificate in
step 1, step 3 fails its own handshake and the PIN is never sent. What is
left is a man in the middle that presents its own certificate on the very
first pairing, which the fingerprint on the prompt is there to catch.

From then on every connection is pinned. If the PC's certificate changes (a
reinstall, or an attacker), the handshake fails: the headset forgets that
PC's certificate and PIN and starts again from step 1, with a warning on the
prompt not to type the PIN unless Immersive was reinstalled on the PC.

Over the USB cable nothing crosses a network: the connection stays plain, the
cable is trusted (as before), and the headset asks for `IDENTITY` anyway
(`HELLO_FLAG_IDENTITY`) so it knows the PC's certificate for its room shares.

### Multiplayer rooms

A headset that shares its PC's screens with a room puts the PC's certificate
in the share. Watchers connect over TLS pinned to it, and get sealed media
like any client: someone on the network who is not in the room sees neither
the watch code nor the screens.

The room channel itself (headset to headset, `room.gd`) was already DTLS,
with a certificate made per run and not checked. It keeps out who listens,
not who sits between a headset and the room: such a machine would see the
share (watch code and certificate) like any member, so it could watch the
shared screens. It still could not control the PC (watchers send no input)
nor learn the PC's PIN.

### Guessing the PIN

Unchanged per address: half a second per wrong PIN, five lock that address
out for a minute. New: past 20 wrong PINs in a minute from all addresses
together, each further one takes 5 s and the host warns (at most every ten
minutes). Slower, not locked: a lockout for everyone would let anyone keep
the real headset out. A six-digit PIN then takes days of continuous guessing
to find, in plain view of the log.

## Not done yet

- **PAKE pairing** (SPAKE2 or similar): would make the first pairing safe
  against a man in the middle without relying on the user reading the
  fingerprint. Needs crypto the Godot client does not have.
- **Checked room channel**: show the room's fingerprint next to its PIN, as
  for the PC, so joining a room is safe against a man in the middle too.
- **Fuzzing and sanitizers in CI** for the host's message parsers.
- **Signed releases** and a published fingerprint for the downloads.
- **Per-headset revocation** from the panel (today: a new PIN, or delete
  the identity files to make every headset pair again).
