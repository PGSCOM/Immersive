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

## Circular jitter buffer: Array of PackedFloat32Array frames.
var _jitter_buffer: Array = []  # sorted by seq number
var _next_seq: int = -1          # next expected sequence number

## How many frames are currently queued in the generator.
var _buffered_frames: int = 0

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

	# Set filter so we only accept packets from the host
	_udp.set_dest_address(host_ip, audio_port)

	_running          = true
	_next_seq         = -1
	_jitter_buffer.clear()
	_playback_started = false
	_buffered_frames  = 0

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
	var n_ch:     int = raw[6]

	var expected_bytes: int = 8 + n_samples * n_ch * 2
	if raw.size() < expected_bytes:
		return  # truncated packet

	# Decode PCM-16 LE to float32
	var frames := PackedFloat32Array()
	frames.resize(n_samples * n_ch)
	var offset := 8
	for i in range(n_samples * n_ch):
		var lo:  int = raw[offset]       & 0xFF
		var hi:  int = raw[offset + 1]   & 0xFF
		var s16: int = (hi << 8) | lo
		if s16 >= 32768:
			s16 -= 65536
		frames[i] = float(s16) / 32768.0
		offset += 2

	# Insert into jitter buffer sorted by seq
	_jitter_buffer.append({"seq": seq, "frames": frames})
	_jitter_buffer.sort_custom(func(a, b): return a["seq"] < b["seq"])

	# Trim buffer to JITTER_WINDOW entries max
	while _jitter_buffer.size() > JITTER_WINDOW:
		_jitter_buffer.pop_back()

func _push_to_generator() -> void:
	if not _playback or _jitter_buffer.is_empty():
		return

	# Initialise expected seq from first packet
	if _next_seq < 0:
		_next_seq = _jitter_buffer[0]["seq"]

	# Push sequential packets to generator
	while not _jitter_buffer.is_empty():
		var entry: Dictionary = _jitter_buffer[0]
		# Allow a small gap (consider lost packets)
		if entry["seq"] > _next_seq + JITTER_WINDOW:
			break

		_jitter_buffer.pop_front()
		_next_seq = entry["seq"] + 1

		var frames: PackedFloat32Array = entry["frames"]
		var n_ch:   int = int(frames.size()) / (frames.size() / CHANNELS) if frames.size() > 0 else CHANNELS
		var n_samp: int = frames.size() / n_ch

		# Re-interleave to stereo if mono
		var stereo := PackedVector2Array()
		stereo.resize(n_samp)
		for i in range(n_samp):
			var l: float = frames[i * n_ch] if n_ch >= 1 else 0.0
			var r: float = frames[i * n_ch + 1] if n_ch >= 2 else l
			stereo[i] = Vector2(l, r)

		if not _playback_started:
			_buffered_frames += n_samp
			# Cache frames in jitter buffer until MIN_BUFFER is met
			_jitter_buffer.push_front(entry)
			if _buffered_frames >= MIN_BUFFER:
				_player.play()
				_playback_started = true
			break
		else:
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

	# Wait until play() is called before grabbing the playback object
	await get_tree().process_frame
	# _player.play() will be called once MIN_BUFFER frames are ready
