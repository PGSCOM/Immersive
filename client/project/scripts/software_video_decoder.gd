## Software (CPU) video decoder for the Immersive-2 client.
##
## Decodes the host's MJPEG stream (a sequence of independent JPEG frames) using
## Godot's built-in JPEG decoder, which is available on every platform — no
## native plugin required. This is the decode path for clients that have no
## hardware MediaCodec plugin: Windows/Linux/macOS desktop (PC), iOS, and web.
##
## It is the software counterpart of `VideoDecoder` (the Android MediaCodec
## wrapper) and mirrors its lifecycle (open → submit → close). Decoding runs on a
## WorkerThreadPool task so a slow frame never stalls rendering; only the most
## recent submitted frame is kept, so the client always shows the freshest image
## and never builds up latency when the CPU can't keep up.
##
## Inter-frame codecs (H.264/HEVC/AV1) are NOT handled here — they need a hardware
## or native decoder. Only MJPEG (protocol codec value 2) is supported; the host
## already falls back to MJPEG for clients that report no hardware decoder.

extends RefCounted
class_name SoftwareVideoDecoder

## Protocol codec value for MJPEG (see protocol.h VideoCodec::MJPEG).
const CODEC_MJPEG := 2

var _codec: int = -1
var _width: int = 0
var _height: int = 0
var _closed: bool = true

# Cross-thread state, guarded by _mutex.
var _mutex: Mutex = Mutex.new()
var _encoded: PackedByteArray = PackedByteArray()  ## latest frame awaiting decode
var _has_encoded: bool = false
var _decoded: Image = null                          ## latest frame awaiting upload
var _has_decoded: bool = false
var _worker_running: bool = false
var _task_id: int = -1


## True when this build can software-decode the given protocol codec.
## Only MJPEG: pure-CPU JPEG decode is the one path that works everywhere.
static func is_codec_supported(codec: int) -> bool:
	return codec == CODEC_MJPEG


## Open the decoder for a stream. Returns false for unsupported codecs.
func open(codec: int, width: int, height: int) -> bool:
	close()
	if not is_codec_supported(codec):
		return false
	_codec = codec
	_width = width
	_height = height
	_closed = false
	print("[SoftwareVideoDecoder] Opened MJPEG decoder %dx%d" % [width, height])
	return true


func is_open() -> bool:
	return not _closed and _codec != -1


## Feed one encoded frame (a complete JPEG). Thread-safe. Only the most recent
## frame is retained; if decoding lags behind arrival, older frames are dropped
## so the display stays current instead of falling behind.
func submit(data: PackedByteArray) -> void:
	if _closed or data.is_empty():
		return
	_mutex.lock()
	_encoded = data
	_has_encoded = true
	var need_task := not _worker_running
	if need_task:
		_worker_running = true
	_mutex.unlock()
	if need_task:
		_task_id = WorkerThreadPool.add_task(_decode_worker, false, "im2_mjpeg_decode")


## Poll for the most recently decoded frame (call on the main thread each frame).
## Returns the Image to upload, or null if nothing new has finished decoding.
func get_decoded_image() -> Image:
	var img: Image = null
	_mutex.lock()
	if _has_decoded:
		img = _decoded
		_decoded = null
		_has_decoded = false
	_mutex.unlock()
	return img


func get_width() -> int:
	return _width


func get_height() -> int:
	return _height


## Stop the decoder and wait for any in-flight worker to finish.
func close() -> void:
	_mutex.lock()
	var had_task := _task_id != -1
	_closed = true
	_has_encoded = false
	_mutex.unlock()
	if had_task:
		# Safe even if the task already completed; ensures the worker is not
		# still touching _decoded when the caller drops this decoder.
		WorkerThreadPool.wait_for_task_completion(_task_id)
	_mutex.lock()
	_task_id = -1
	_worker_running = false
	_decoded = null
	_has_decoded = false
	_mutex.unlock()
	_codec = -1


# --- Worker thread ---------------------------------------------------------

## Drains the pending-frame slot on a pool thread. Loops so a frame that arrives
## mid-decode is picked up without needing a fresh task. Exits (clearing
## _worker_running) only while holding the lock with no frame pending, which keeps
## submit()'s "start a task if none is running" decision race-free.
func _decode_worker() -> void:
	while true:
		_mutex.lock()
		if _closed or not _has_encoded:
			_worker_running = false
			_mutex.unlock()
			return
		var data: PackedByteArray = _encoded
		_has_encoded = false
		_mutex.unlock()

		var img := Image.new()
		if img.load_jpg_from_buffer(data) != OK:
			continue  # corrupt/partial JPEG — skip, keep the previous frame
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		# Mipmaps let the anisotropic sampler resolve fine desktop text without
		# shimmering when the panel is minified or viewed at an angle.
		img.generate_mipmaps()

		_mutex.lock()
		_decoded = img
		_has_decoded = true
		_mutex.unlock()
