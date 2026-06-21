## Voice chat for Immersive-2 multi-user sessions (Immersed parity: headset mic →
## other users, with a mute toggle).
##
## Capture:  the headset microphone is recorded on a dedicated, muted audio bus
##   carrying an AudioEffectCapture (muting the bus stops the local echo while the
##   effect still taps the signal). Each tick the captured stereo is downmixed to
##   mono, sliced into fixed-length frames, encoded as PCM-16, and emitted via
##   voice_frame_ready — main.gd then routes it through MultiuserManager
##   (P2P WebRTC voice channel for ≤2 users, SFU relay for 3+).
## Playback: incoming frames are decoded and pushed to a per-user VoicePlayback
##   (an AudioStreamPlayer3D anchored to that user's avatar head → spatial voice).
##
## A mute toggle gates capture instantly. Encode/decode are pure static helpers so
## the wire format is unit-testable without a microphone or audio device.

extends Node
class_name VoiceChat

## Emitted with an encoded voice frame ready to send to the room.
signal voice_frame_ready(frame: PackedByteArray)
## Emitted whenever the local mic mute state changes.
signal mute_changed(muted: bool)

const VoicePlaybackScript := preload("res://scripts/voice_playback.gd")

## Dedicated capture bus name (created on demand).
const VOICE_BUS := "VoiceCapture"
## Voice frame length in milliseconds (20 ms ≈ standard VoIP framing).
const FRAME_MS := 20
## Frame header: seq(u32) + num_samples(u16) + flags(u8) + reserved(u8).
const HEADER_SIZE := 8

# --- Capture state ---
var _mic_player: AudioStreamPlayer = null
var _capture_effect: AudioEffectCapture = null
var _capturing: bool = false
var _muted: bool = false
var _seq: int = 0
var _frame_samples: int = 0
var _capture_accum: PackedFloat32Array = PackedFloat32Array()

# --- Playback state ---
## user_id -> VoicePlayback
var _playbacks: Dictionary = {}

func _process(_delta: float) -> void:
	if _capturing:
		_pump_capture()

func _exit_tree() -> void:
	stop_capture()
	clear_playbacks()

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

## Begin recording the microphone. Returns false if the capture bus/effect could
## not be created (e.g. no audio backend). Idempotent.
func start_capture() -> bool:
	if _capturing:
		return true
	if not _ensure_capture_bus():
		return false
	_frame_samples = maxi(1, int(AudioServer.get_mix_rate() * FRAME_MS / 1000.0))
	_capture_accum = PackedFloat32Array()
	_mic_player = AudioStreamPlayer.new()
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = VOICE_BUS
	add_child(_mic_player)
	_mic_player.play()
	_capturing = true
	return true

## Stop recording the microphone (playback of remote users is unaffected).
func stop_capture() -> void:
	if is_instance_valid(_mic_player):
		_mic_player.stop()
		_mic_player.queue_free()
	_mic_player = null
	_capturing = false
	_capture_accum = PackedFloat32Array()

func is_capturing() -> bool:
	return _capturing

## Pull whatever the mic captured this tick, frame it, and emit. While muted the
## buffer is still drained (so it never overruns) but nothing is sent.
func _pump_capture() -> void:
	if _capture_effect == null:
		return
	var available := _capture_effect.get_frames_available()
	if available <= 0:
		return
	var stereo := _capture_effect.get_buffer(available)
	if _muted:
		return  # drained above; discard while muted
	_capture_accum.append_array(downmix_to_mono(stereo))
	while _capture_accum.size() >= _frame_samples:
		var frame_mono := _capture_accum.slice(0, _frame_samples)
		_capture_accum = _capture_accum.slice(_frame_samples)
		voice_frame_ready.emit(encode_frame(_seq, frame_mono))
		_seq = (_seq + 1) & 0xFFFFFFFF

func _ensure_capture_bus() -> bool:
	var idx := AudioServer.get_bus_index(VOICE_BUS)
	if idx == -1:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, VOICE_BUS)
		# Mute the bus output so the user does not hear their own mic; the
		# AudioEffectCapture still taps the signal upstream of the mute.
		AudioServer.set_bus_mute(idx, true)
		_capture_effect = AudioEffectCapture.new()
		AudioServer.add_bus_effect(idx, _capture_effect)
	elif _capture_effect == null:
		# Bus already exists (e.g. after a stop/start) — recover the effect.
		for i in range(AudioServer.get_bus_effect_count(idx)):
			var fx := AudioServer.get_bus_effect(idx, i)
			if fx is AudioEffectCapture:
				_capture_effect = fx as AudioEffectCapture
				break
		if _capture_effect == null:
			_capture_effect = AudioEffectCapture.new()
			AudioServer.add_bus_effect(idx, _capture_effect)
	return _capture_effect != null

# ---------------------------------------------------------------------------
# Mute
# ---------------------------------------------------------------------------

func set_muted(muted: bool) -> void:
	if _muted == muted:
		return
	_muted = muted
	mute_changed.emit(_muted)

func toggle_mute() -> void:
	set_muted(not _muted)

func is_muted() -> bool:
	return _muted

# ---------------------------------------------------------------------------
# Playback
# ---------------------------------------------------------------------------

## Create (or reparent) the playback for `user_id`. Pass the remote user's head
## node as `anchor` for spatial voice; null keeps it non-spatial under this node.
func attach_playback(user_id: int, anchor: Node3D = null) -> VoicePlayback:
	return _ensure_playback(user_id, anchor)

## Decode and route an incoming voice frame to the right user's playback.
func on_remote_voice(user_id: int, frame: PackedByteArray) -> void:
	var decoded := decode_frame(frame)
	if not decoded.get("valid", false):
		return
	var pb := _ensure_playback(user_id)
	pb.push_frame(int(decoded["seq"]), decoded["samples"])

func remove_playback(user_id: int) -> void:
	var pb = _playbacks.get(user_id, null)
	if is_instance_valid(pb):
		pb.queue_free()
	_playbacks.erase(user_id)

func clear_playbacks() -> void:
	for user_id in _playbacks.keys():
		var pb = _playbacks[user_id]
		if is_instance_valid(pb):
			pb.queue_free()
	_playbacks.clear()

func playback_count() -> int:
	return _playbacks.size()

func get_playback(user_id: int) -> VoicePlayback:
	return _playbacks.get(user_id, null)

func _ensure_playback(user_id: int, anchor: Node3D = null) -> VoicePlayback:
	var pb: VoicePlayback = _playbacks.get(user_id, null)
	if not is_instance_valid(pb):
		pb = VoicePlaybackScript.new()
		pb.name = "VoicePlayback_%d" % user_id
		_playbacks[user_id] = pb
	var parent: Node = anchor if is_instance_valid(anchor) else self
	if pb.get_parent() != parent:
		if pb.get_parent() != null:
			pb.get_parent().remove_child(pb)
		parent.add_child(pb)
	return pb

# ---------------------------------------------------------------------------
# Pure codec helpers (unit-tested headlessly)
# ---------------------------------------------------------------------------

## Average a stereo buffer down to a mono float buffer.
static func downmix_to_mono(stereo: PackedVector2Array) -> PackedFloat32Array:
	var mono := PackedFloat32Array()
	mono.resize(stereo.size())
	for i in range(stereo.size()):
		mono[i] = (stereo[i].x + stereo[i].y) * 0.5
	return mono

## Encode a mono float frame to the wire format: header + PCM-16 LE samples.
static func encode_frame(seq: int, mono: PackedFloat32Array) -> PackedByteArray:
	var n: int = mini(mono.size(), 0xFFFF)
	var buf := PackedByteArray()
	buf.resize(HEADER_SIZE + n * 2)
	buf.encode_u32(0, seq & 0xFFFFFFFF)
	buf.encode_u16(4, n)
	buf.encode_u8(6, 0)  # flags (reserved)
	buf.encode_u8(7, 0)  # reserved
	var off := HEADER_SIZE
	for i in range(n):
		var s: int = int(round(clampf(mono[i], -1.0, 1.0) * 32767.0))
		buf.encode_s16(off, s)
		off += 2
	return buf

## Decode a wire frame back to { valid, seq, samples (mono float) }.
static func decode_frame(frame: PackedByteArray) -> Dictionary:
	if frame.size() < HEADER_SIZE:
		return {"valid": false}
	var seq: int = frame.decode_u32(0)
	var n: int = frame.decode_u16(4)
	if frame.size() < HEADER_SIZE + n * 2:
		return {"valid": false}
	var samples := PackedFloat32Array()
	samples.resize(n)
	var off := HEADER_SIZE
	for i in range(n):
		samples[i] = float(frame.decode_s16(off)) / 32768.0
		off += 2
	return {"valid": true, "seq": seq, "samples": samples}
