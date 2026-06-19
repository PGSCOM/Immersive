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
## ExternalTexture is created on the main thread (safe for has_external_texture()
## checks), then set_external_buffer_id() is called from the render thread once
## the GL texture name is known (RenderingServer routes it thread-safely).
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

	# Allocate the ExternalTexture on the main thread — Godot manages this GL
	# texture internally. We then pass its GL ID to Java so MediaCodec decodes
	# directly into the texture Godot already knows about (avoids the broken
	# set_external_buffer_id path where Godot cannot see externally-created textures).
	_external_tex = ExternalTexture.new()
	_external_tex.size = Vector2(width, height)

	var ext_tex := _external_tex
	var sid := _stream_id
	var plug := _plugin
	var mime: String = CODEC_MIME[codec]
	RenderingServer.call_on_render_thread(func():
		# get_external_buffer_id() returns the GL texture Godot created for this
		# ExternalTexture. We pass it to Java so SurfaceTexture decodes into it.
		var gl_tex_id: int = ext_tex.get_external_buffer_id()
		print("[VideoDecoder] Godot ExternalTexture glTex=%d stream=%d" % [gl_tex_id, sid])
		if gl_tex_id <= 0:
			push_warning("[VideoDecoder] ExternalTexture not ready (glTex=0) for stream=%d" % sid)
			return
		var ok: bool = plug.create_with_surface(sid, gl_tex_id, mime, width, height)
		if ok:
			print("[VideoDecoder] Decoder ready: glTex=%d stream=%d" % [gl_tex_id, sid])
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
## ShaderMaterial is not render-thread-safe for writes, so we use
## RenderingServer.material_set_param() with the material's RID instead of
## material.set_shader_parameter(), which can silently corrupt state.
func schedule_update(material: ShaderMaterial) -> void:
	if not _plugin or _stream_id < 0 or _external_tex == null:
		return
	var plug := _plugin
	var sid := _stream_id
	var mat_rid := material.get_rid()
	RenderingServer.call_on_render_thread(func():
		if plug.update_tex_image(sid):
			var arr: PackedFloat32Array = plug.get_transform_matrix(sid)
			if arr.size() == 16:
				var proj := Projection(
					Vector4(arr[0], arr[1], arr[2], arr[3]),
					Vector4(arr[4], arr[5], arr[6], arr[7]),
					Vector4(arr[8], arr[9], arr[10], arr[11]),
					Vector4(arr[12], arr[13], arr[14], arr[15])
				)
				RenderingServer.material_set_param(mat_rid, "tex_transform", proj)
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
