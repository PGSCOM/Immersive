## Standalone, NON-XR test harness for the MediaCodec -> ExternalTexture -> shader
## pipeline. Used to verify the hardware decode path on an Android emulator
## (e.g. BlueStacks) WITHOUT the Pico headset and WITHOUT the host/network.
##
## It decodes a bundled H.264 Annex-B clip (res://test_assets/clip.h264) straight
## into a Godot ExternalTexture via the Im2VideoDecoder plugin, and displays it on
## a flat quad with the real screen_external.gdshader (samplerExternalOES).
##
## A solid grey->coloured moving test pattern means the whole zero-copy path works.
## A black quad means it does not. After ~1.5s it writes user://shot.png for
## headless verification and prints [TestDecode] diagnostics to logcat.

extends Node3D

const CLIP_PATH := "res://test_assets/clip.h264"
const WIDTH := 640
const HEIGHT := 480
const CODEC := 0          # 0 = H.264 (video/avc)
const FPS := 15.0

var _decoder: VideoDecoder
var _mat: ShaderMaterial
var _mesh: MeshInstance3D
var _aus: Array[PackedByteArray] = []
var _au_index := 0
var _feed_accum := 0.0
var _started := false
var _frame := 0
var _shot_saved := false


func _ready() -> void:
	# Solid background so a black quad is obviously distinguishable.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.35, 0.0)  # green backdrop
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 0.0, 1.4)
	add_child(cam)
	cam.make_current()

	_mesh = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(1.6, 1.2)
	_mesh.mesh = qm
	add_child(_mesh)

	var shader := load("res://shaders/screen_external.gdshader") as Shader
	_mat = ShaderMaterial.new()
	_mat.shader = shader
	_mat.set_shader_parameter("tex_transform", Projection.IDENTITY)
	_mat.set_shader_parameter("tex_size", Vector2(WIDTH, HEIGHT))
	_mat.set_shader_parameter("border_width", 0.0)
	_mat.set_shader_parameter("brightness", 1.0)
	_mat.set_shader_parameter("contrast", 1.0)
	_mat.set_shader_parameter("curvature", 0.0)
	_mat.set_shader_parameter("foveation_enabled", 0)
	_mesh.material_override = _mat

	_parse_clip()
	print("[TestDecode] parsed access units: %d" % _aus.size())

	print("[TestDecode] codec supported: %s" % str(VideoDecoder.is_codec_supported(CODEC)))
	_decoder = VideoDecoder.new()
	var ok := _decoder.open(CODEC, WIDTH, HEIGHT)
	print("[TestDecode] decoder.open(%dx%d) -> %s" % [WIDTH, HEIGHT, str(ok)])


func _process(delta: float) -> void:
	if _decoder == null or _aus.is_empty():
		return
	if not _decoder.has_external_texture():
		return
	if not _started:
		var et := _decoder.get_external_texture()
		_mat.set_shader_parameter("screen_external", et)
		_started = true
		print("[TestDecode] ExternalTexture bound to material")

	# Feed access units at clip rate, looping forever so the screen always shows video.
	_feed_accum += delta
	var interval := 1.0 / FPS
	while _feed_accum >= interval:
		_feed_accum -= interval
		_decoder.submit(_aus[_au_index])
		_au_index = (_au_index + 1) % _aus.size()

	# Latch the newest decoded frame into the OES texture + push transform.
	_decoder.schedule_update(_mat)

	_frame += 1
	if _frame == 90 and not _shot_saved:
		_save_shot()


func _save_shot() -> void:
	_shot_saved = true
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null:
		var err := img.save_png("user://shot.png")
		# Average luma so logcat alone tells us black vs. content.
		var avg := 0.0
		var step := maxi(1, img.get_width() / 32)
		var n := 0
		for y in range(0, img.get_height(), step):
			for x in range(0, img.get_width(), step):
				var c := img.get_pixel(x, y)
				avg += (c.r + c.g + c.b) / 3.0
				n += 1
		avg /= max(1, n)
		print("[TestDecode] shot saved (err=%d) avg_luma=%.3f -> %s" %
			[err, avg, ("CONTENT" if avg > 0.02 else "BLACK")])
	else:
		print("[TestDecode] viewport image was null")


## Split the Annex-B elementary stream into access units. Each VCL NAL (type 1/5)
## that follows another VCL starts a new AU; SPS (7) also starts a new AU so each
## keyframe carries its parameter sets. Every NAL is re-emitted with a 4-byte
## (00 00 00 01) start code, which is what MediaCodec expects in Annex-B mode.
func _parse_clip() -> void:
	var f := FileAccess.open(CLIP_PATH, FileAccess.READ)
	if f == null:
		push_error("[TestDecode] cannot open %s" % CLIP_PATH)
		return
	var data := f.get_buffer(f.get_length())
	f.close()
	var n := data.size()

	var starts: Array[int] = []
	var i := 0
	while i + 3 < n:
		if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
			starts.append(i)
			i += 3
		else:
			i += 1
	starts.append(n)

	var cur := PackedByteArray()
	var cur_has_vcl := false
	for k in range(starts.size() - 1):
		var s: int = starts[k]
		var e: int = starts[k + 1]
		var seg := data.slice(s, e)        # seg starts at 00 00 01
		if seg.size() < 4:
			continue
		var t: int = seg[3] & 0x1f
		var is_vcl := (t == 1 or t == 5)
		if t == 7 or (is_vcl and cur_has_vcl):
			if cur.size() > 0:
				_aus.append(cur)
			cur = PackedByteArray()
			cur_has_vcl = false
		cur.append(0); cur.append(0); cur.append(0); cur.append(1)
		cur.append_array(seg.slice(3))     # NAL payload after the 00 00 01
		if is_vcl:
			cur_has_vcl = true
	if cur.size() > 0:
		_aus.append(cur)
