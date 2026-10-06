## Audio receiver for Immersive-2 VR Client.
##
## Receives UDP packets of PCM-16 stereo 48 kHz audio from the host
## and plays them back using Godot's AudioStreamGenerator.
##
## A circular buffer absorbs network jitter.  Packets that arrive
## out-of-order within a small window are reordered before playback.
##
## Usage:
##   var audio_rx := AudioReceiver.new()
##   audio_rx.start(host_ip, audio_port)
##   add_child(audio_rx)   # must be in scene tree for _process to run

extends Node
class_name AudioReceiver

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const SAMPLE_RATE   := 48000
const CHANNELS      := 2
## Audio queued before playback (re)starts: 40 ms absorbs Wi-Fi jitter.
const MIN_BUFFER    := 1920
## Most audio kept waiting, in the reorder queue plus the player (~120 ms).
## Above it the oldest audio is dropped, so a host clock running slightly
## fast cannot pile up delay over a long session.
const MAX_BUFFER    := 5760

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

## AudioStreamPlayer node that does the actual playback.
var _player:    AudioStreamPlayer
## AudioStreamGeneratorPlayback — the push interface.
var _playback:  AudioStreamGeneratorPlayback

## UDP socket for receiving audio packets.
var _udp: PacketPeerUDP
## Opens them when the connection has a media key (NetworkClient.SealOpener);
## null when they come plain.
var _opener: RefCounted = null

## Whether we are currently listening.
var _running: bool = false

## Jitter buffer entries: { seq: int, frames: PackedVector2Array } sorted by seq.
var _jitter_buffer: Array = []  # sorted by seq number
var _next_seq: int = -1          # next expected sequence number

## Whether playback has been started (we wait for MIN_BUFFER first).
var _playback_started: bool = false
## Underruns reported by the player so far (get_skips()).
var _last_skips: int = 0

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_build_player()

func _process(_delta: float) -> void:
	if not _running:
		return
	_receive_packets()
	_push_to_generator()

func _exit_tree() -> void:
	stop()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Start receiving audio on the given UDP port. media_key: the connection's
## MEDIA_KEY (empty: the packets come plain), see NetworkClient.SealOpener.
func start(host_ip: String, audio_port: int, media_key := PackedByteArray()) -> bool:
	if _running:
		stop()
	_opener = null if media_key.is_empty() \
		else preload("res://scripts/network_client.gd").SealOpener.new(media_key)

	_udp = PacketPeerUDP.new()
	var err := _udp.bind(audio_port)
	if err != OK:
		push_warning("[AudioReceiver] Failed to bind UDP port %d: %d" % [audio_port, err])
		return false

	# Default send target (used only if we ever reply); PacketPeerUDP has no
	# inbound source filter, so this is not a filter despite the old comment.
	_udp.set_dest_address(host_ip, audio_port)

	_running          = true
	_next_seq         = -1
	_jitter_buffer.clear()
	_playback_started = false

	print("[AudioReceiver] Listening for audio on UDP:%d" % audio_port)
	return true

## Stop receiving and clear buffers.
func stop() -> void:
	if not _running:
		return
	_running = false
	if _udp:
		_udp.close()
		_udp = null
	if _player:
		_player.stop()
	_playback = null
	_playback_started = false
	_jitter_buffer.clear()
	print("[AudioReceiver] Stopped")

## Set master volume (0.0–1.0).
func set_volume(vol: float) -> void:
	if _player:
		_player.volume_db = linear_to_db(clamp(vol, 0.0, 1.0))

# ---------------------------------------------------------------------------
# Internal — packet receive
# ---------------------------------------------------------------------------

func _receive_packets() -> void:
	while _udp and _udp.get_available_packet_count() > 0:
		var raw: PackedByteArray = _udp.get_packet()
		if _opener:
			raw = _opener.open(raw)  # empty (dropped) unless sealed with our key
		parse_packet(raw)

## Queue one audio packet (AudioPacketHeader + PCM). Called for UDP packets
## and, in USB mode, for AUDIO_DATA messages from the TCP control channel.
func parse_packet(raw: PackedByteArray) -> void:
	# AudioPacketHeader: seq(4) + samples(2) + channels(1) + reserved(1) = 8 bytes
	if raw.size() < 8:
		return

	var seq:      int = (raw[0])        | (raw[1] << 8)  | (raw[2] << 16) | (raw[3] << 24)
	var n_samples:int = (raw[4])        | (raw[5] << 8)
	var n_ch:     int = max(1, raw[6])

	var expected_bytes: int = 8 + n_samples * n_ch * 2
	if raw.size() < expected_bytes:
		return  # truncated packet

	# Decode PCM-16 LE straight into the interleaved stereo form the generator
	# wants. Doing it in one pass (instead of PCM→float32 array here and
	# float32→Vector2 again at push time) halves the per-sample GDScript work,
	# which at 48 kHz stereo is ~96k iterations a second on the main thread.
	var stereo := PackedVector2Array()
	stereo.resize(n_samples)
	var offset := 8
	var stride := n_ch * 2
	for i in range(n_samples):
		var l: float = raw.decode_s16(offset) / 32768.0
		var r: float = (raw.decode_s16(offset + 2) / 32768.0) if n_ch >= 2 else l
		stereo[i] = Vector2(l, r)
		offset += stride

	# Already played past it: a late packet would only play out of order.
	if _next_seq >= 0 and seq < _next_seq and _next_seq - seq < 1_000_000:
		return
	# Insert into jitter buffer sorted by seq
	_jitter_buffer.append({"seq": seq, "frames": stereo})
	_jitter_buffer.sort_custom(func(a, b): return a["seq"] < b["seq"])

func _queued_frames() -> int:
	var n := 0
	for entry in _jitter_buffer:
		n += entry["frames"].size()
	return n

## Frames sitting in the player, not yet heard.
func _player_frames() -> int:
	if not _playback:
		return 0
	var capacity := int((_player.stream as AudioStreamGenerator).buffer_length * SAMPLE_RATE)
	return max(0, capacity - _playback.get_frames_available())

func _push_to_generator() -> void:
	if _jitter_buffer.is_empty():
		return

	# Pre-buffer: wait until enough audio is queued before (re)starting, so
	# the first bit of Wi-Fi jitter does not crackle.
	if not _playback_started:
		if _queued_frames() < MIN_BUFFER:
			return
		if not _player.playing:
			_player.play()
		_playback = _player.get_stream_playback()
		_playback_started = true
		_last_skips = _playback.get_skips()

	if not _playback:
		return

	# The player ran dry (host clock slower, or a Wi-Fi stall): build the
	# cushion up again instead of crackling on every packet from now on.
	var skips := _playback.get_skips()
	if skips != _last_skips:
		_last_skips = skips
		if _player_frames() == 0 and _queued_frames() < MIN_BUFFER:
			_playback_started = false
			return

	# Too much waiting (host clock faster): drop the oldest audio.
	while _jitter_buffer.size() > 1 and _queued_frames() + _player_frames() > MAX_BUFFER:
		_next_seq = _jitter_buffer.pop_front()["seq"] + 1

	# Initialise expected seq from first packet
	if _next_seq < 0:
		_next_seq = _jitter_buffer[0]["seq"]

	# Push packets in order; a missing one is waited for only while the
	# queue is short, then given up on.
	while not _jitter_buffer.is_empty():
		var entry: Dictionary = _jitter_buffer[0]
		if entry["seq"] > _next_seq and _queued_frames() < MIN_BUFFER:
			break
		var stereo: PackedVector2Array = entry["frames"]
		if _playback.get_frames_available() < stereo.size():
			break
		_jitter_buffer.pop_front()
		_next_seq = entry["seq"] + 1
		_playback.push_buffer(stereo)

# ---------------------------------------------------------------------------
# Internal — player setup
# ---------------------------------------------------------------------------

func _build_player() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = float(SAMPLE_RATE)
	gen.buffer_length = 0.2  # 200 ms generator buffer

	_player = AudioStreamPlayer.new()
	_player.stream = gen
	_player.autoplay = false
	add_child(_player)
	# _player.play() is called (and _playback grabbed) once MIN_BUFFER
	# frames have accumulated in the jitter buffer.
