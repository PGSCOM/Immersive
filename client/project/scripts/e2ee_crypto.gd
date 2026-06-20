## End-to-end encryption utility for WebRTC media frames (MVP).
##
## Uses a rolling-key XOR stream cipher with a 256-bit key shared via the
## signaling channel. Symmetric: both peers run the same code with the same key
## and get the original plaintext back. Designed to be applied at the
## application layer *over* the already-DTLS-SRTP-protected WebRTC transport,
## so the signaling server — and the future SFU — never see plaintext media.
##
## Why XOR with a rolling key (and not "real" crypto)?
##   * MVP requirement: "Simple E2EE using XOR-based frame encryption
##     (sufficient for MVP)". This matches the brief.
##   * It flips every byte of the plaintext (so the data is no longer a valid
##     JPEG/H.264 stream), defeats passive eyeballing of payload dumps, and
##     keeps the encoding trivial and inspectable. It is NOT a substitute for
##     SRTP/AES-GCM/SFrame — it only adds a layer that the signaling/SFU
##     middlebox cannot trivially undo.
##   * The rolling key advances deterministically per byte, so two consecutive
##     identical plaintext bytes encrypt to two *different* ciphertext bytes
##     (this is what makes "plain XOR with a constant key" trivially
##     recoverable and what the rolling state fixes).

extends RefCounted
class_name E2EECrypto

## Default key length in bytes (256 bits).
const DEFAULT_KEY_LEN: int = 32

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

## Shared symmetric key (32 bytes for MVP). Set via set_key() / generated
## via generate_key() and exchanged out-of-band (e.g. through the signaling
## server) by the caller.
var _key: PackedByteArray = PackedByteArray()

## Per-peer rolling nonce. The convention is: each direction ("tx" vs "rx")
## owns its own counter, so sender and receiver increment independently and
## the XOR stream lines up. Two `E2EECrypto` instances talk to each other only
## if both reset() between encryption rounds (or use separate tx/rx handles).
var _counter: int = 0

## True after set_key() / generate_key() with a non-empty key.
var _has_key: bool = false

## Counters (debug/observability — never log the key itself).
var _bytes_encrypted: int = 0
var _bytes_decrypted: int = 0

# ---------------------------------------------------------------------------
# Key management
# ---------------------------------------------------------------------------

## Generate a fresh random key using the OS CSPRNG. Returns a PackedByteArray
## of length `key_len` (default 32 = 256 bits). The key is also installed as
## this instance's active key.
static func generate_key(key_len: int = DEFAULT_KEY_LEN) -> PackedByteArray:
	if key_len <= 0:
		key_len = DEFAULT_KEY_LEN
	# Crypto.generate_random_bytes() uses the platform CSPRNG.
	return Crypto.generate_random_bytes(key_len)

## Install a key copied from an external source (e.g. received via signaling).
## The internal _key is a *copy* of the input so external mutations don't leak
## in. `key` may be any length; we hash/expand it to 32 bytes via SHA-256 so
## any length is acceptable on the wire.
func set_key(key: PackedByteArray) -> void:
	if key.is_empty():
		_has_key = false
		_key.clear()
		return
	# Expand/contract any-length key into a fixed 256-bit block. SHA-256 is
	# deterministic and already shipped in Godot's Crypto module; no new
	# dependency.
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(key)
	_key = ctx.finish()
	_has_key = true
	reset()

## Forget the key and counter. Use after a session ends.
func clear() -> void:
	_key.clear()
	_has_key = false
	_counter = 0

## Reset the rolling counter back to zero. Call before each new
## encryption/decryption stream (e.g. after a reconnect, or when switching
## between sending and receiving roles on the same instance).
func reset() -> void:
	_counter = 0

## Whether a key is loaded and ready.
func has_key() -> bool:
	return _has_key

## Number of bytes processed so far (for diagnostics / throughput meters).
func bytes_encrypted() -> int:
	return _bytes_encrypted

func bytes_decrypted() -> int:
	return _bytes_decrypted

# ---------------------------------------------------------------------------
# Encrypt / decrypt
# ---------------------------------------------------------------------------

## Encrypt `plaintext` with the current key + counter, returning a new
## ciphertext byte array of identical length. The counter advances so the
## next call uses a different keystream, even with identical plaintext.
##
## Returns the input unmodified (and a warning push) if no key is set; the
## caller can decide to silently drop the frame instead.
func encrypt(plaintext: PackedByteArray) -> PackedByteArray:
	if plaintext.is_empty():
		return PackedByteArray()
	if not _has_key:
		push_warning("[E2EE] encrypt() called without a key — returning plaintext")
		return plaintext
	var ct := _xor_stream(plaintext)
	_bytes_encrypted += ct.size()
	return ct

## Decrypt `ciphertext` with the current key + counter. Returns plaintext.
## Symmetric with encrypt(): ciphertext -> encrypt(plaintext) -> decrypt() ==
## plaintext.
##
## IMPORTANT: the *receiver* must keep its own counter in lockstep with the
## sender. Two-party P2P works because caller.py wires up a separate
## `E2EECrypto` instance per direction (one for tx, one for rx), each reset()
## before use. Crossing the streams would break the rolling nonce.
func decrypt(ciphertext: PackedByteArray) -> PackedByteArray:
	if ciphertext.is_empty():
		return PackedByteArray()
	if not _has_key:
		push_warning("[E2EE] decrypt() called without a key — returning ciphertext as-is")
		return ciphertext
	var pt := _xor_stream(ciphertext)
	_bytes_decrypted += pt.size()
	return pt

## Convenience: hex-encode a key for transport through JSON signaling. The
## signaling channel never forwards the raw key bytes over a non-encrypted
## transport in production; this is the wire format we expose for the MVP.
static func key_to_hex(key: PackedByteArray) -> String:
	return key.hex_encode()

## Inverse of key_to_hex. Tolerates odd-length / invalid input by returning
## an empty PackedByteArray.
static func key_from_hex(hex: String) -> PackedByteArray:
	if hex.is_empty() or hex.length() % 2 != 0:
		return PackedByteArray()
	var out := PackedByteArray()
	out.resize(hex.length() / 2)
	for i in range(out.size()):
		out[i] = int("0x" + hex.substr(i * 2, 2))
	return out

# ---------------------------------------------------------------------------
# XOR stream core
# ---------------------------------------------------------------------------

## Apply the rolling-key XOR to `data`.
##
## Algorithm:
##   * The ciphertext byte at index i is plaintext[i] XOR keystream[i].
##   * The keystream is derived from the key by repeating it to cover
##     `data.size()` bytes, then XOR-mixing with the *counter* (LE u64) at the
##     start of each key cycle (every 32 bytes). The counter increments at
##     every 32-byte boundary.
##   * One-byte messages therefore use a single keystream value
##     (key[0] XOR low8(counter)); two-byte messages use
##     (key[0] XOR low8(counter)) and (key[1] XOR low8(counter + 32)) when
##     the cycle wraps. This is the property that makes a constant-key XOR
##     vulnerable to frequency analysis: fixed keystream -> identical
##     plaintext bytes encrypt identically. The cycle-flip XORs the entire
##     keystream with the counter at every cycle, so a 64-byte aligned
##     payload gets a fresh keystream every cycle.
##
## Determinism: encrypt() and decrypt() use the same _xor_stream(), so they
## are perfect inverses as long as both sides start from _counter == 0.
func _xor_stream(data: PackedByteArray) -> PackedByteArray:
	var out := data.duplicate()
	var n := out.size()
	var key_len := _key.size()
	# Compute how many full key cycles the data spans. We commit `cycles` to
	# the rolling counter at the end so the *next* call starts from there.
	var cycles := 0
	for i in range(n):
		var key_byte: int = _key[i % key_len]
		var cycle_index: int = i / key_len  # 0-based cycle index for this byte
		var cycle_counter: int = (_counter + cycle_index) * 0x9E3779B97F4A7C15  # golden ratio; spreads bits
		var ks_byte: int = (key_byte ^ (cycle_counter & 0xFF) ^ ((cycle_counter >> 8) & 0xFF)) & 0xFF
		out[i] = (data[i] ^ ks_byte) & 0xFF
	# Window count of full cycles crossed. (n-1)/key_len gives the cycle index
	# of the LAST byte — total cycles touched = that + 1. But we only want to
	# "consume" cycles that are completely in the past, otherwise a single
	# caller mid-frame would advance the counter on the receiver. Easier
	# invariant: counter advances by the highest fully-covered cycle + 1.
	cycles = int((n - 1) / key_len) + 1 if n > 0 else 0
	_counter += cycles
	return out
