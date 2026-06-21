## Per-remote-user spatial voice playback for Immersive-2 (multi-user voice chat).
##
## One VoicePlayback is created per remote participant and parented under that
## user's avatar head (so their voice is spatialised — it comes from where their
## head is). Mono PCM-16 voice frames arrive via push_frame(); a small jitter
## buffer absorbs network reordering before the samples are pushed into an
## AudioStreamGenerator for playback.
##
## The buffer bookkeeping (push_frame / buffered_frame_count) is independent of an
## audio device, so it is unit-testable headlessly; play() is only touched once
## enough audio has accumulated and the node is in the tree.

extends AudioStreamPlayer3D
class_name VoicePlayback

## Minimum buffered samples before playback starts (pre-roll to hide jitter).
const MIN_BUFFER_SAMPLES := 480   ## ~10 ms at 48 kHz
## Hard cap on queued frames so a stalled receiver cannot grow unbounded.
const MAX_QUEUED_FRAMES := 32

var _gen_playback: AudioStreamGeneratorPlayback = null
## Queued frames: { seq:int, samples:PackedFloat32Array (mono) }, kept seq-sorted.
var _queue: Array = []
var _started: bool = false

func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = AudioServer.get_mix_rate()
	gen.buffer_length = 0.2  # 200 ms generator buffer
	stream = gen
	# Gentle falloff so a nearby speaker is clear without being directional to a
	# fault; voice should stay intelligible across a small shared room.
	unit_size = 4.0
	max_db = 3.0
	set_process(true)

## Queue a decoded mono voice frame (seq for reorder, samples in [-1, 1]).
func push_frame(seq: int, samples: PackedFloat32Array) -> void:
	if samples.is_empty():
		return
	_queue.append({"seq": seq, "samples": samples})
	_queue.sort_custom(func(a, b): return int(a["seq"]) < int(b["seq"]))
	while _queue.size() > MAX_QUEUED_FRAMES:
		_queue.pop_front()

## Number of frames currently buffered (for diagnostics / tests).
func buffered_frame_count() -> int:
	return _queue.size()

func _process(_delta: float) -> void:
	if _queue.is_empty():
		return

	if not _started:
		var total := 0
		for entry in _queue:
			total += (entry["samples"] as PackedFloat32Array).size()
		if total < MIN_BUFFER_SAMPLES:
			return
		if not is_inside_tree():
			return
		play()
		_gen_playback = get_stream_playback()
		_started = _gen_playback != null
		if not _started:
			return

	if _gen_playback == null:
		return

	while not _queue.is_empty():
		var entry: Dictionary = _queue[0]
		var samples: PackedFloat32Array = entry["samples"]
		if _gen_playback.get_frames_available() < samples.size():
			break  # generator full; push the rest next frame
		_queue.pop_front()
		var stereo := PackedVector2Array()
		stereo.resize(samples.size())
		for i in range(samples.size()):
			stereo[i] = Vector2(samples[i], samples[i])  # mono → centred stereo
		_gen_playback.push_buffer(stereo)

## Stop playback and drop any queued audio.
func reset() -> void:
	if _started:
		stop()
	_started = false
	_gen_playback = null
	_queue.clear()
