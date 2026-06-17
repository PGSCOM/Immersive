## Hardware video decoder wrapper for the Immersive-2 VR client.
##
## Wraps the Im2VideoDecoder Android plugin (MediaCodec). The decoder renders
## directly into a Godot [ExternalTexture] (a GL_TEXTURE_EXTERNAL_OES object) —
## zero CPU readback, no YUV→RGB in GDScript. The panel shader samples the
## ExternalTexture through `samplerExternalOES`.
##
## SurfaceTexture attach + updateTexImage must run on Godot's render/GL thread
## (that is where the external texture lives), so they are scheduled through
## [method RenderingServer.call_on_render_thread]. Drive [method render_update]
## once per frame from a node's `_process`.
##
## On platforms without the plugin (desktop, or an APK without the AAR),
## [method is_codec_supported] returns false and the caller shows a placeholder
## (there is no software fallback any more).

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
var _ext_tex: ExternalTexture = null
var _render_cb: Callable


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
	_width = width
	_height = height

	# The external texture the decoder renders into. Sizing it forces Godot to
	# allocate the underlying GL_TEXTURE_EXTERNAL_OES object on the render thread.
	_ext_tex = ExternalTexture.new()
	_ext_tex.set_size(Vector2(width, height))
	var tex_id: int = _ext_tex.get_external_texture_id()

	if not _plugin.create(_stream_id, CODEC_MIME[codec], width, height, tex_id):
		push_warning("[VideoDecoder] MediaCodec rejected %s (%dx%d)" %
			[CODEC_MIME[codec], width, height])
		_plugin = null
		_stream_id = -1
		_ext_tex = null
		return false

	_codec = codec
	_render_cb = Callable(self, "_on_render_thread")
	# Kick an attach attempt right away (idempotent, retried in render_update).
	RenderingServer.call_on_render_thread(_render_cb)
	print("[VideoDecoder] Opened %s decoder (%dx%d), stream id %d, texId %d" %
		[CODEC_MIME[codec], width, height, _stream_id, tex_id])
	return true


func is_open() -> bool:
	return _plugin != null


## The texture the panel binds to its `samplerExternalOES` shader uniform.
func get_texture() -> Texture2D:
	return _ext_tex


## Feed one encoded access unit to the decoder (runs on the calling thread).
func submit(encoded: PackedByteArray) -> void:
	if _plugin and not encoded.is_empty():
		_plugin.submit(_stream_id, encoded)


## Schedule the per-frame GL work (attach + updateTexImage) on the render thread.
## Call once per frame from a node's `_process`.
func render_update() -> void:
	if _plugin:
		RenderingServer.call_on_render_thread(_render_cb)


## SurfaceTexture transform (column-major 4x4) the shader applies to sample UVs.
func get_transform() -> PackedFloat32Array:
	if not _plugin:
		return PackedFloat32Array()
	var m = _plugin.get_transform(_stream_id)
	return PackedFloat32Array(m) if m != null else PackedFloat32Array()


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
	_ext_tex = null


## Runs on Godot's render thread (scheduled via call_on_render_thread).
func _on_render_thread() -> void:
	if not _plugin:
		return
	_plugin.attach_to_render_context(_stream_id)  # idempotent
	_plugin.update_image(_stream_id)
