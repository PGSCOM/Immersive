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
const BUFFER_FRAMES := 8192  ## Circular buffer size in frames (stereo samples)
const MIN_BUFFER    := 960   ## Minimum buffered frames before playback starts
const JITTER_WINDOW := 8     ## Max out-of-order packet reorder window

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

## AudioStreamPlayer node that does the actual playback.
var _player:    AudioStreamPlayer
## AudioStreamGeneratorPlayback — the push interface.
var _playback:  AudioStreamGeneratorPlayback

## UDP socket for receiving audio packets.
var _udp: PacketPeerUDP

## Whether we are currently listening.
var _running: bool = false

## Jitter buffer entries: { seq: int, frames: PackedVector2Array } sorted by seq.
var _jitter_buffer: Array = []  # sorted by seq number
var _next_seq: int = -1          # next expected sequence number

## Whether playback has been started (we wait for MIN_BUFFER first).
var _playback_started: bool = false

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

## Start receiving audio on the given UDP port.
func start(host_ip: String, audio_port: int) -> bool:
	if _running:
		stop()

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
		_parse_audio_packet(raw)

func _parse_audio_packet(raw: PackedByteArray) -> void:
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

	# Insert into jitter buffer sorted by seq
	_jitter_buffer.append({"seq": seq, "frames": stereo})
	_jitter_buffer.sort_custom(func(a, b): return a["seq"] < b["seq"])

	# Trim buffer: drop the OLDEST packets so latency stays bounded
	while _jitter_buffer.size() > JITTER_WINDOW:
		_jitter_buffer.pop_front()

func _push_to_generator() -> void:
	if _jitter_buffer.is_empty():
		return

	# Pre-buffer: wait until enough audio is queued before starting playback
	if not _playback_started:
		var total_frames := 0
		for entry in _jitter_buffer:
			total_frames += entry["frames"].size()
		if total_frames < MIN_BUFFER:
			return
		_player.play()
		_playback = _player.get_stream_playback()
		_playback_started = true

	if not _playback:
		return

	# Initialise expected seq from first packet
	if _next_seq < 0:
		_next_seq = _jitter_buffer[0]["seq"]

	# Push sequential packets to generator
	while not _jitter_buffer.is_empty():
		var entry: Dictionary = _jitter_buffer[0]
		# If the gap is too big the missing packets are lost — resync
		if entry["seq"] > _next_seq + JITTER_WINDOW:
			_next_seq = entry["seq"]

		var stereo: PackedVector2Array = entry["frames"]

		# Don't overflow the generator's internal buffer
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
