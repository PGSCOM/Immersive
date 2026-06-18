## Virtual screen panel for displaying streamed desktop content.
## Attached to a MeshInstance3D (PlaneMesh) in the VR scene.
##
## Features:
##   - Texture updated each received video frame (MJPEG or raw RGBA)
##   - Repositionable with controller grip (drag and drop in 3D space)
##   - Latency indicator overlay in the corner
##   - Panel size updates to match monitor aspect ratio

extends MeshInstance3D

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

const SCREEN_SHADER_PATH := "res://shaders/screen.gdshader"
const DEFAULT_CURVATURE := 0.18
const DEFAULT_FOVEATION_STRENGTH := 0.55

## Screen texture that receives decoded frames.
var screen_texture: ImageTexture
## Current screen image.
var screen_image: Image
## Whether the active texture was created with mipmaps (used to decide between
## an in-place update() and a full recreate).
var _texture_has_mipmaps: bool = false

## Screen dimensions.
var screen_width: int  = 1920
var screen_height: int = 1080

## Panel dimensions in meters (16:9 default).
var panel_width: float  = 1.6
var panel_height: float = 0.9

## Whether the screen is currently receiving frames.
var is_active: bool = false

## Current latency (ms) displayed in corner.
var _latency_ms: float = 0.0

## Curved-screen mode state.
var _curved_mode: bool = false
var _curvature_amount: float = DEFAULT_CURVATURE

## Eye-tracked foveated rendering state.
var _foveation_enabled: bool = false
var _foveation_strength: float = DEFAULT_FOVEATION_STRENGTH
var _foveation_focus_uv: Vector2 = Vector2(0.5, 0.5)

# Drag state
var _is_dragging: bool         = false
var _drag_controller: Node3D   = null
var _drag_offset: Transform3D

# Latency label overlay (billboard)
var _latency_label: Label3D    = null
var _placeholder_label: Label3D = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_create_placeholder_texture()
	_create_latency_label()
	set_process(true)

func _process(_delta: float) -> void:
	if _is_dragging and is_instance_valid(_drag_controller):
		_follow_controller()
	_update_latency_label()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Set the resolution and update the panel aspect ratio.
func set_resolution(width: int, height: int, codec: int = 2) -> void:
	screen_width  = width
	screen_height = height

	# Update panel aspect ratio
	var aspect: float = float(width) / float(height)
	panel_height = panel_width / aspect

	# Update the mesh size
	if mesh is PlaneMesh:
		(mesh as PlaneMesh).size = Vector2(panel_width, panel_height)
	_update_latency_label_anchor()

	# Create a properly-sized texture
	screen_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	screen_image.fill(Color(0.1, 0.1, 0.1, 1.0))
	screen_texture = ImageTexture.create_from_image(screen_image)
	_apply_texture()

	is_active = true
	if _placeholder_label:
		_placeholder_label.hide()
	print("[ScreenPanel] Resolution set: %dx%d, panel: %.2f x %.2f m" %
		[width, height, panel_width, panel_height])

## Enable/disable curved mode and set curvature amount.
func set_curvature(enabled: bool, amount: float) -> void:
	_curved_mode = enabled
	_curvature_amount = clamp(amount, 0.0, 0.5)
	_apply_curvature_to_material()

func set_foveation(enabled: bool, strength: float) -> void:
	_foveation_enabled = enabled
	_foveation_strength = clamp(strength, 0.0, 1.0)
	_apply_foveation_to_material()

func set_foveation_focus_uv(uv: Vector2) -> void:
	_foveation_focus_uv = Vector2(clamp(uv.x, 0.0, 1.0), clamp(uv.y, 0.0, 1.0))
	if material_override is ShaderMaterial:
		(material_override as ShaderMaterial).set_shader_parameter("gaze_uv", _foveation_focus_uv)

## Update the screen texture with new video frame data.
## frame_data may be:
##   - JPEG bytes (from MJPEG software encoder): decoded via Image.load_jpg_from_buffer
##   - Raw RGBA bytes (legacy path)
func update_texture(frame_data: PackedByteArray, width: int, height: int) -> void:
	if not is_active:
		return

	# JPEG (MJPEG path) — detected by magic bytes FF D8 FF
	var looks_jpeg: bool = frame_data.size() >= 3 \
		and frame_data[0] == 0xFF and frame_data[1] == 0xD8 and frame_data[2] == 0xFF
	var img := Image.new()
	var err: int = img.load_jpg_from_buffer(frame_data) if looks_jpeg else ERR_INVALID_DATA
	if err == OK:
		# load_jpg returns RGB8; convert so the texture format stays stable
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		# Mipmaps let the anisotropic sampler resolve fine text without shimmer.
		img.generate_mipmaps()
		screen_image = img
		if material_override is ShaderMaterial:
			(material_override as ShaderMaterial).set_shader_parameter("is_yuv", 0)
	else:
		# Log decode errors to help diagnose black-screen issues
		if looks_jpeg:
			print("[ScreenPanel] JPEG decode error (", err, ") for ", frame_data.size(), " bytes")
		# Fallback: treat as raw RGBA or YUV NV12 bytes
		if frame_data.size() == int(width * height * 1.5):
			# YUV NV12 (from MediaCodec) -> shader handles YUV decode
			var yuv_height := int(height * 1.5)
			screen_image = Image.create_from_data(width, yuv_height, false, Image.FORMAT_L8, frame_data)
			if material_override is ShaderMaterial:
				(material_override as ShaderMaterial).set_shader_parameter("is_yuv", 1)
		elif frame_data.size() >= width * height * 4:
			# RAW RGBA
			screen_image = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, frame_data)
			screen_image.generate_mipmaps()
			if material_override is ShaderMaterial:
				(material_override as ShaderMaterial).set_shader_parameter("is_yuv", 0)
		else:
			return

	# ImageTexture.update() requires identical size and format; otherwise
	# the texture must be recreated (e.g. resolution change, RGBA<->L8).
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

	if _placeholder_label and _placeholder_label.visible:
		_placeholder_label.hide()

## Scale the panel up/down using thumbstick.
## Called from vr_input.gd when thumbstick Y is held while grip is pressed.
func scale_panel(delta_scale: float) -> void:
	panel_width = clamp(panel_width + delta_scale, 0.4, 4.0)
	panel_height = panel_width / (float(screen_width) / float(screen_height))
	if mesh is PlaneMesh:
		(mesh as PlaneMesh).size = Vector2(panel_width, panel_height)
	_update_latency_label_anchor()

## Programmatically set the panel position in world space.
func set_panel_position(pos: Vector3) -> void:
	global_transform.origin = pos

## Serialize panel transform/size for workspace persistence.
func get_layout_state() -> Dictionary:
	var basis := global_transform.basis
	return {
		"position": [
			global_transform.origin.x,
			global_transform.origin.y,
			global_transform.origin.z
		],
		"basis": [
			basis.x.x, basis.x.y, basis.x.z,
			basis.y.x, basis.y.y, basis.y.z,
			basis.z.x, basis.z.y, basis.z.z
		],
		"panel_width": panel_width
	}

## Restore panel transform/size from a serialized workspace layout state.
func apply_layout_state(state: Dictionary) -> void:
	if state.is_empty():
		return

	var pos_data: Array = state.get("position", [])
	var basis_data: Array = state.get("basis", [])

	if pos_data.size() == 3 and basis_data.size() == 9:
		var restored_basis := Basis(
			Vector3(basis_data[0], basis_data[1], basis_data[2]),
			Vector3(basis_data[3], basis_data[4], basis_data[5]),
			Vector3(basis_data[6], basis_data[7], basis_data[8]))
		global_transform = Transform3D(
			restored_basis,
			Vector3(pos_data[0], pos_data[1], pos_data[2]))

	var restored_width: float = state.get("panel_width", panel_width)
	panel_width = clamp(restored_width, 0.4, 4.0)
	panel_height = panel_width / (float(screen_width) / float(screen_height))
	if mesh is PlaneMesh:
		(mesh as PlaneMesh).size = Vector2(panel_width, panel_height)
	_update_latency_label_anchor()

## Update the displayed latency value.
func set_latency(ms: float) -> void:
	_latency_ms = ms

# ---------------------------------------------------------------------------
# Grip-based dragging — called from vr_input.gd
# ---------------------------------------------------------------------------

## Begin dragging this panel with the given controller.
func start_drag(controller: Node3D) -> void:
	_is_dragging = true
	_drag_controller = controller
	# Record the panel's pose relative to the controller at grab time
	_drag_offset = controller.global_transform.affine_inverse() * global_transform

func stop_drag() -> void:
	_is_dragging = false
	_drag_controller = null

func _follow_controller() -> void:
	global_transform = _drag_controller.global_transform * _drag_offset

# ---------------------------------------------------------------------------
# UV / pixel coordinate helpers
# ---------------------------------------------------------------------------

## Convert a 3D world position to screen UV coordinates.
## Returns Vector2(-1, -1) if the point is not on the screen plane.
func world_to_screen_uv(world_pos: Vector3) -> Vector2:
	var local_pos: Vector3 = global_transform.affine_inverse() * world_pos
	return _local_to_uv(local_pos)

## Ray/screen intersection helper used by gaze-based foveation.
## Returns { valid: bool, uv: Vector2, distance: float }.
func ray_to_screen_hit(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	var local_origin: Vector3 = global_transform.affine_inverse() * ray_origin
	var local_dir: Vector3 = global_transform.basis.inverse() * ray_direction

	if abs(local_dir.z) < 0.0001:
		return {"valid": false}

	var t: float = -local_origin.z / local_dir.z
	if t < 0.0:
		return {"valid": false}

	var local_hit: Vector3 = local_origin + local_dir * t
	var uv := _local_to_uv(local_hit)
	if uv.x < 0.0:
		return {"valid": false}

	return {
		"valid": true,
		"uv": uv,
		"distance": t
	}

func _local_to_uv(local_pos: Vector3) -> Vector2:

	# The panel faces -Z (FACE_Z orientation); points on the panel have z ≈ 0
	if abs(local_pos.z) > 0.02:
		return Vector2(-1.0, -1.0)

	var u: float = (local_pos.x / panel_width) + 0.5
	var v: float = 0.5 - (local_pos.y / panel_height)

	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return Vector2(-1.0, -1.0)

	return Vector2(u, v)

## Convert UV coordinates to pixel coordinates on the screen.
func uv_to_pixel(uv: Vector2) -> Vector2i:
	return Vector2i(
		int(uv.x * screen_width),
		int(uv.y * screen_height)
	)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

func _create_placeholder_texture() -> void:
	screen_image = Image.create(screen_width, screen_height, false, Image.FORMAT_RGBA8)
	screen_image.fill(Color(0.05, 0.05, 0.08, 1.0))

	var border_color := Color(0.3, 0.3, 0.5, 1.0)
	screen_image.fill_rect(Rect2i(0, 0, screen_width, 1), border_color)
	screen_image.fill_rect(Rect2i(0, screen_height - 1, screen_width, 1), border_color)
	screen_image.fill_rect(Rect2i(0, 0, 1, screen_height), border_color)
	screen_image.fill_rect(Rect2i(screen_width - 1, 0, 1, screen_height), border_color)

	screen_texture = ImageTexture.create_from_image(screen_image)
	_apply_texture()

	_create_placeholder_label()

func _apply_texture() -> void:
	var mat := material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("screen_texture", screen_texture)
		# NV12 path samples the same texture through a point-sampled uniform.
		(mat as ShaderMaterial).set_shader_parameter("screen_texture_nv12", screen_texture)
	else:
		# Create shader-based material so curved mode can be toggled at runtime.
		var shader := load(SCREEN_SHADER_PATH) as Shader
		var new_mat := ShaderMaterial.new()
		if shader:
			new_mat.shader = shader
		new_mat.set_shader_parameter("screen_texture", screen_texture)
		new_mat.set_shader_parameter("screen_texture_nv12", screen_texture)
		new_mat.set_shader_parameter("is_yuv", 0)
		material_override = new_mat

	_apply_curvature_to_material()
	_apply_foveation_to_material()

func _apply_curvature_to_material() -> void:
	if material_override is ShaderMaterial:
		var mat := material_override as ShaderMaterial
		var value := _curvature_amount if _curved_mode else 0.0
		mat.set_shader_parameter("curvature", value)

func _apply_foveation_to_material() -> void:
	if material_override is ShaderMaterial:
		var mat := material_override as ShaderMaterial
		mat.set_shader_parameter("foveation_enabled", 1 if _foveation_enabled else 0)
		mat.set_shader_parameter("foveation_strength", _foveation_strength)
		mat.set_shader_parameter("gaze_uv", _foveation_focus_uv)

func _create_latency_label() -> void:
	_latency_label = Label3D.new()
	_latency_label.text = ""
	_latency_label.font_size = 24
	_latency_label.modulate = Color(0.3, 1.0, 0.3)
	_latency_label.no_depth_test = true
	_latency_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED

	_update_latency_label_anchor()
	_latency_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_latency_label)

func _create_placeholder_label() -> void:
	_placeholder_label = Label3D.new()
	_placeholder_label.text = "Immersive-2 · Waiting for stream"
	_placeholder_label.font_size = 28
	_placeholder_label.modulate = Color(0.5, 0.5, 0.7, 0.8)
	_placeholder_label.no_depth_test = true
	_placeholder_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_placeholder_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_placeholder_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_placeholder_label.position = Vector3(0, 0, 0.002)
	add_child(_placeholder_label)

func _update_latency_label_anchor() -> void:
	if _latency_label:
		_latency_label.position = Vector3(panel_width * 0.5 - 0.05, panel_height * 0.5 - 0.03, 0.001)

func _update_latency_label() -> void:
	if not _latency_label:
		return
	if _latency_ms <= 0.0 or not is_active:
		_latency_label.text = ""
		return

	var label_text := "%.0f ms" % _latency_ms
	var color := Color(0.3, 1.0, 0.3)
	if _latency_ms > 30.0:
		color = Color(1.0, 0.8, 0.2)
	if _latency_ms > 60.0:
		color = Color(1.0, 0.3, 0.3)

	_latency_label.text = label_text
	_latency_label.modulate = color
