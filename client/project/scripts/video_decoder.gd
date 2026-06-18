## Hardware video decoder wrapper for the Immersive-2 VR client.
##
## Wraps the Im2VideoDecoder Android plugin (MediaCodec) which decodes
## H.264 / HEVC / AV1 access units and renders them zero-copy into an
## ExternalTexture (GL_TEXTURE_EXTERNAL_OES via SurfaceTexture).
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
var _external_tex: ExternalTexture = null
var _tex_transform: Projection = Projection.IDENTITY


## True when this platform could decode the given protocol codec.
## (The actual decoder creation can still fail, e.g. AV1 on Quest 2.)
static func is_codec_supported(codec: int) -> bool:
	return CODEC_MIME.has(codec) and Engine.has_singleton(PLUGIN_NAME)


## Open a hardware decoder for the stream. Returns false when unsupported.
## The plugin's create_with_surface() is called on the render thread so the
## GL texture name is valid when it comes back; _external_tex is set there.
func open(codec: int, width: int, height: int) -> bool:
	close()
	if not is_codec_supported(codec):
		return false

	_plugin = Engine.get_singleton(PLUGIN_NAME)
	_stream_id = _next_stream_id
	_next_stream_id += 1
	_codec = codec
	_width = width
	_height = height

	var sid := _stream_id
	var plug := _plugin
	var mime: String = CODEC_MIME[codec]
	RenderingServer.call_on_render_thread(func():
		var gl_tex_id: int = plug.create_with_surface(sid, mime, width, height)
		if gl_tex_id > 0:
			_external_tex = ExternalTexture.new()
			_external_tex.set_external_buffer_id(gl_tex_id)
			_external_tex.size = Vector2(width, height)
			print("[VideoDecoder] ExternalTexture ready: glTex=%d stream=%d" % [gl_tex_id, sid])
		else:
			push_warning("[VideoDecoder] create_with_surface failed for %s (%dx%d)" % [mime, width, height])
	)
	print("[VideoDecoder] Scheduling %s decoder (%dx%d), stream id %d" % [mime, width, height, _stream_id])
	return true


func is_open() -> bool:
	return _plugin != null


## True once the render-thread callback has created the ExternalTexture.
func has_external_texture() -> bool:
	return _external_tex != null

func get_external_texture() -> ExternalTexture:
	return _external_tex

func get_tex_transform() -> Projection:
	return _tex_transform


## Feed one encoded access unit to the decoder.
func submit(encoded: PackedByteArray) -> void:
	if _plugin and not encoded.is_empty():
		_plugin.submit(_stream_id, encoded)


## Schedule a SurfaceTexture.updateTexImage() + transform matrix read on the
## render thread, then push the updated tex_transform into the panel material.
func schedule_update(material: ShaderMaterial) -> void:
	if not _plugin or _stream_id < 0 or _external_tex == null:
		return
	var plug := _plugin
	var sid := _stream_id
	RenderingServer.call_on_render_thread(func():
		if not is_instance_valid(material):
			return
		if plug.update_tex_image(sid):
			var arr: PackedFloat32Array = plug.get_transform_matrix(sid)
			if arr.size() == 16:
				var proj := Projection(
					Vector4(arr[0], arr[1], arr[2], arr[3]),
					Vector4(arr[4], arr[5], arr[6], arr[7]),
					Vector4(arr[8], arr[9], arr[10], arr[11]),
					Vector4(arr[12], arr[13], arr[14], arr[15])
				)
				material.set_shader_parameter("tex_transform", proj)
	)


## Flush the MediaCodec input/output queues (call after a frame gap).
func flush() -> void:
	if _plugin and _stream_id >= 0:
		_plugin.flush_decoder(_stream_id)


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
	_external_tex = null
	_tex_transform = Projection.IDENTITY
