## Hardware video decoder wrapper for the Immersive-2 VR client.
##
## Wraps the Im2VideoDecoder Android plugin (MediaCodec) which decodes
## H.264 / HEVC / AV1 access units to tightly packed NV12 frames that the
## screen shader renders directly (is_yuv path).
##
## On platforms without the plugin (desktop, or APK exported without the
## AAR) `is_codec_supported()` returns false and the caller is expected to
## fall back to MJPEG.

extends RefCounted
class_name VideoDecoder

const PLUGIN_NAME := "Im2VideoDecoder"

## Protocol codec value → MediaCodec MIME type.
const CODEC_MIME := {
	0: "video/avc",   # H.264
	1: "video/hevc",  # H.265 / HEVC
	3: "video/av01",  # AV1
}

static var _next_stream_id: int = 1

var _plugin: Object = null
var _stream_id: int = -1
var _codec: int = -1
var _width: int = 0
var _height: int = 0


## True when this platform could decode the given protocol codec.
## (The actual decoder creation can still fail, e.g. AV1 on Quest 2.)
static func is_codec_supported(codec: int) -> bool:
	return CODEC_MIME.has(codec) and Engine.has_singleton(PLUGIN_NAME)


## Open a hardware decoder for the stream. Returns false when unsupported.
func open(codec: int, width: int, height: int) -> bool:
	close()
	if not is_codec_supported(codec):
		return false

	_plugin = Engine.get_singleton(PLUGIN_NAME)
	_stream_id = _next_stream_id
	_next_stream_id += 1

	if not _plugin.create(_stream_id, CODEC_MIME[codec], width, height):
		push_warning("[VideoDecoder] MediaCodec rejected %s (%dx%d)" %
			[CODEC_MIME[codec], width, height])
		_plugin = null
		_stream_id = -1
		return false

	_codec = codec
	_width = width
	_height = height
	print("[VideoDecoder] Opened %s decoder (%dx%d), stream id %d" %
		[CODEC_MIME[codec], width, height, _stream_id])
	return true


func is_open() -> bool:
	return _plugin != null


## Feed one encoded access unit to the decoder.
func submit(encoded: PackedByteArray) -> void:
	if _plugin and not encoded.is_empty():
		_plugin.submit(_stream_id, encoded)


## Newest decoded frame as packed NV12 (w*h*1.5 bytes), empty if none yet.
## Frame dimensions may differ from the open() size (codec crop): query
## get_width()/get_height() after a non-empty poll.
func poll_frame() -> PackedByteArray:
	if not _plugin:
		return PackedByteArray()
	var frame: PackedByteArray = _plugin.get_frame(_stream_id)
	if not frame.is_empty():
		_width = _plugin.get_frame_width(_stream_id)
		_height = _plugin.get_frame_height(_stream_id)
	return frame


func get_width() -> int:
	return _width


func get_height() -> int:
	return _height


func close() -> void:
	if _plugin:
		_plugin.release_decoder(_stream_id)
		_plugin = null
	_stream_id = -1
	_codec = -1
