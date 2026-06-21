## Remote screen panel for displaying another user's shared monitor.
##
## Placed around a remote user's avatar from the REMOTE_SCREEN_LAYOUT message
## (pose + size + resolution). Once video streaming is active, call
## update_decoded_image() each frame to display live pixels; until then the
## panel shows a dark placeholder so the viewer can see where the shared monitor
## sits and which one it is.

extends Node3D

const SCREEN_SHADER_PATH := "res://shaders/screen.gdshader"

## Monitor ID this panel represents (from the remote user's layout).
var monitor_id: int = -1

## Native resolution of the remote monitor.
var resolution: Vector2i = Vector2i(1920, 1080)

## Panel size in meters (width, height).
var panel_size: Vector2 = Vector2(1.6, 0.9)

## True once apply_layout_metadata() has been called (panel is positioned and
## sized). update_decoded_image() is a no-op until this is set.
var is_active: bool = false

## GPU texture uploaded from decoded frames.
var screen_texture: ImageTexture = null

## The most-recently-decoded Image (retained so texture can be recreated after a
## resolution change without needing the caller to re-submit the frame).
var screen_image: Image = null

## Whether the current screen_texture was built with mipmaps.
var _texture_has_mipmaps: bool = false

## MeshInstance3D that displays the screen surface.
var _mesh: MeshInstance3D = null

## PlaneMesh for the screen.
var _plane: PlaneMesh = null

## Floating label naming the shared monitor (hidden once live pixels arrive).
var _label: Label3D = null

func _ready() -> void:
	_mesh = MeshInstance3D.new()
	add_child(_mesh)

	_plane = PlaneMesh.new()
	_plane.size = panel_size
	_plane.orientation = PlaneMesh.FACE_Z
	_mesh.mesh = _plane

	_label = Label3D.new()
	_label.font_size = 22
	_label.modulate = Color(0.70, 0.82, 1.0)
	_label.no_depth_test = true
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.position = Vector3(0.0, panel_size.y * 0.5 + 0.04, 0.0)
	_mesh.add_child(_label)
	_refresh_label()

	_create_placeholder_texture()

## Apply layout metadata from REMOTE_SCREEN_LAYOUT message.
func apply_layout_metadata(entry: Dictionary) -> void:
	monitor_id = entry.get("monitor_id", -1)
	var pos := Vector3(entry.get("pos_x", 0.0), entry.get("pos_y", 0.0), entry.get("pos_z", 0.0))
	var rot := Quaternion(entry.get("rot_x", 0.0), entry.get("rot_y", 0.0), entry.get("rot_z", 0.0), entry.get("rot_w", 1.0))

	transform.origin = pos
	transform.basis = Basis(rot)

	panel_size = Vector2(entry.get("width", 1.6), entry.get("height", 0.9))
	resolution = Vector2i(entry.get("resolution_w", 1920), entry.get("resolution_h", 1080))

	if _plane:
		_plane.size = panel_size
	if _label:
		_label.position = Vector3(0.0, panel_size.y * 0.5 + 0.04, 0.0)
	_refresh_label()
	is_active = true

## Upload an already-decoded RGBA image to the panel texture.
##
## Must be called from the main thread. Decoding runs off-thread (in
## SoftwareVideoDecoder); the caller polls get_decoded_image() there and hands
## the result here for GPU upload. No-op until apply_layout_metadata() has been
## called (is_active == true).
func update_decoded_image(img: Image) -> void:
	if not is_active or img == null:
		return
	screen_image = img
	if _mesh.material_override is ShaderMaterial:
		(_mesh.material_override as ShaderMaterial).set_shader_parameter("is_yuv", 0)
	_upload_screen_image()
	# Hide the "Monitor N · WxH" label once we have real pixels.
	if _label and _label.visible:
		_label.hide()

## Get the current panel size.
func get_panel_size() -> Vector2:
	return panel_size

## Get the current resolution.
func get_resolution() -> Vector2i:
	return resolution

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

func _refresh_label() -> void:
	if _label:
		_label.text = "🖥 Monitor %d · %d×%d" % [monitor_id, resolution.x, resolution.y]

func _create_placeholder_texture() -> void:
	# Small 4×4 dark-blue placeholder so the shader has a valid texture to sample.
	screen_image = Image.create(4, 4, false, Image.FORMAT_RGBA8)
	screen_image.fill(Color(0.08, 0.10, 0.16, 1.0))
	screen_texture = ImageTexture.create_from_image(screen_image)
	_apply_texture()

func _apply_texture() -> void:
	var mat := _mesh.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("screen_texture", screen_texture)
		(mat as ShaderMaterial).set_shader_parameter("screen_texture_nv12", screen_texture)
	else:
		var shader := load(SCREEN_SHADER_PATH) as Shader
		var new_mat := ShaderMaterial.new()
		if shader:
			new_mat.shader = shader
		new_mat.set_shader_parameter("screen_texture", screen_texture)
		new_mat.set_shader_parameter("screen_texture_nv12", screen_texture)
		new_mat.set_shader_parameter("is_yuv", 0)
		_mesh.material_override = new_mat

## Push screen_image into the GPU texture. Reuses the existing ImageTexture when
## size/format/mipmap state are unchanged; recreates it otherwise.
func _upload_screen_image() -> void:
	if screen_texture \
			and screen_texture.get_width() == screen_image.get_width() \
			and screen_texture.get_height() == screen_image.get_height() \
			and screen_texture.get_format() == screen_image.get_format() \
			and _texture_has_mipmaps == screen_image.has_mipmaps():
		screen_texture.update(screen_image)
	else:
		screen_texture = ImageTexture.create_from_image(screen_image)
		_texture_has_mipmaps = screen_image.has_mipmaps()
		_apply_texture()
