## Virtual screen panel for displaying streamed desktop content.
## A MeshInstance3D whose mesh it builds itself: a flat quad, or a section of
## a vertical cylinder when curved, so every column of the desktop sits at the
## same distance from the axis (a real curved monitor, not a texture warp).
##
## Features:
##   - Texture updated each received video frame (MJPEG or raw RGBA)
##   - Laser drag (LaserDrag): the grabbed point stays on the pointer ray, the
##     panel never rolls; push/pull and resize while held, its group follows
##   - A grab bar under the panel (GrabBar): point at it and press to move it
##   - Panel size follows the monitor aspect ratio

extends MeshInstance3D

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

const SCREEN_SHADER_PATH := "res://shaders/screen.gdshader"
const SCREEN_EXTERNAL_SHADER_PATH := "res://shaders/screen_external.gdshader"
const LAYER_EXTERNAL_SHADER_PATH := "res://shaders/screen_layer_external.gdshader"
## A layer's swapchain is as big as the stream, up to this width.
const LAYER_MAX_WIDTH := 3840
const DEFAULT_CURVATURE := 0.5
## Arc covered by the panel at curvature 1.0 (radians, ~100°).
const MAX_ARC := 1.75
const CURVE_COLUMNS := 48
const MIN_WIDTH := 0.4
const MAX_WIDTH := 4.0

## Texture-orientation compensation for the zero-copy ExternalTexture (OES) path.
## The MediaCodec→SurfaceTexture→OES frame is vertically mirrored relative to
## Godot's top-left UV convention, so the screen_external shader samples with
## flip_y on (and flip_x off). This is purely a TEXTURE-sampling concern: it
## describes how the decoded pixels sit in the GL external texture, NOT where the
## panel is in space. It is deliberately NOT applied to uv_to_pixel() — the
## controller→mouse mapping is geometric and assumes an upright display. Tune
## these until the panel reads upright and un-mirrored on a new device/driver.
const DISPLAY_FLIP_X := false
const DISPLAY_FLIP_Y := true

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

## Panel dimensions in meters (16:9 default). Width is the arc length when
## curved, so resizing and curving are independent.
var panel_width: float  = 1.6
var panel_height: float = 0.9

## Whether the screen is currently receiving frames.
var is_active: bool = false

## Whether this panel is in zero-copy ExternalTexture mode (Android HW decoder).
var _using_external_texture: bool = false

## Curved-screen state. Effective curvature 0 = flat, 1 = MAX_ARC.
var _curved_mode: bool = false
var _curvature_amount: float = DEFAULT_CURVATURE

## Set while a pointer holds the panel (see LaserDrag).
var _drag: LaserDrag = null

var _placeholder_label: Label3D = null
## The bar under the screen; main.gd::pick() tests it.
var grab_bar: GrabBar = null

# OpenXR compositor layer (see set_compositor_layer()).
var _layer_wanted: bool = false
var _layer_origin: Node3D = null
var _layer: Node3D = null            ## OpenXRCompositionLayerQuad / Cylinder
var _layer_viewport: SubViewport = null
var _layer_content: Control = null   ## TextureRect, or ColorRect + OES shader
var _ext_tex: ExternalTexture = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_rebuild_mesh()
	_create_placeholder_texture()
	grab_bar = GrabBar.new()
	add_child(grab_bar)
	_place_decorations()
	set_process(true)

func _exit_tree() -> void:
	_free_layer()  # the layer lives under XROrigin3D, not under this panel

func _process(delta: float) -> void:
	if _drag:
		_drag.update(delta)
	if _layer:
		_sync_layer()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Set the resolution and update the panel aspect ratio.
func set_resolution(width: int, height: int, codec: int = 2) -> void:
	if width <= 0 or height <= 0:
		push_warning("[ScreenPanel] Ignoring invalid resolution %dx%d" % [width, height])
		return
	screen_width  = width
	screen_height = height
	panel_height = panel_width / (float(width) / float(height))
	_rebuild_mesh()

	# A stream (re)starting means a new decoder, so any ExternalTexture bound
	# from the previous one is stale. Drop back to the CPU-texture material and
	# let main.gd's _update_decoders() re-bind if the new decoder is hardware —
	# otherwise the panel would keep sampling a dead OES texture and freeze.
	if _using_external_texture:
		_using_external_texture = false
		_ext_tex = null
		material_override = null

	# Create a properly-sized texture
	screen_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	screen_image.fill(Color(0.06, 0.06, 0.055, 1.0))
	screen_texture = ImageTexture.create_from_image(screen_image)
	_texture_has_mipmaps = screen_image.has_mipmaps()
	_apply_texture()
	_rebuild_layer()  # new size, and back to the CPU texture

	is_active = true
	if _placeholder_label:
		_placeholder_label.hide()
	print("[ScreenPanel] Resolution set: %dx%d, panel: %.2f x %.2f m (codec %d)" %
		[width, height, panel_width, panel_height, codec])

## Returns true when the panel is using the zero-copy ExternalTexture path.
func is_using_external_texture() -> bool:
	return _using_external_texture

## Switch this panel to the zero-copy ExternalTexture path (Android HW decoder).
## Replaces material_override with screen_external.gdshader bound to ext_tex.
func set_external_texture(ext_tex: ExternalTexture, width: int, height: int) -> void:
	screen_width = width
	screen_height = height
	panel_height = panel_width / (float(width) / float(height))
	_rebuild_mesh()

	var shader := load(SCREEN_EXTERNAL_SHADER_PATH) as Shader
	var mat := ShaderMaterial.new()
	if shader:
		mat.shader = shader
	mat.set_shader_parameter("screen_external", ext_tex)
	mat.set_shader_parameter("tex_size", Vector2(width, height))
	mat.set_shader_parameter("tex_transform", Projection.IDENTITY)
	mat.set_shader_parameter("flip_x", 1 if DISPLAY_FLIP_X else 0)
	mat.set_shader_parameter("flip_y", 1 if DISPLAY_FLIP_Y else 0)
	material_override = mat
	_apply_panel_size_to_material()

	_using_external_texture = true
	_ext_tex = ext_tex
	_rebuild_layer()
	is_active = true
	if _placeholder_label:
		_placeholder_label.hide()
	print("[ScreenPanel] External texture mode: %dx%d" % [width, height])

## Enable/disable curved mode and set curvature amount (0..1).
func set_curvature(enabled: bool, amount: float) -> void:
	var before := _arc()
	_curved_mode = enabled
	_curvature_amount = clamp(amount, 0.0, 1.0)
	if not is_equal_approx(before, _arc()):
		_rebuild_mesh()
		# Flat and curved screens are different kinds of layer.
		if _layer and (before >= 0.001) != (_arc() >= 0.001):
			_rebuild_layer()

## Show the screen as an OpenXR compositor layer parented to `origin` (the
## XROrigin3D): the runtime samples the picture once, straight through the
## lens correction, instead of after Godot has resampled it into the eye
## buffer — text comes out noticeably sharper. A hole is punched in Godot's
## own rendering where the layer is, so the menu, keyboard and pointer still
## draw in front of it. The mesh keeps serving ray hits and the handle.
func set_compositor_layer(enabled: bool, origin: Node3D) -> void:
	_layer_wanted = enabled and origin != null
	_layer_origin = origin
	_rebuild_layer()

func has_compositor_layer() -> bool:
	return _layer != null

## The canvas material feeding the layer from the hardware decoder, so
## main.gd can push the SurfaceTexture transform to it too (or null).
func get_layer_material() -> ShaderMaterial:
	return _layer_content.material as ShaderMaterial if _layer_content else null

func _free_layer() -> void:
	if is_instance_valid(_layer):
		_layer.queue_free()
	if is_instance_valid(_layer_viewport):
		_layer_viewport.queue_free()
	_layer = null
	_layer_viewport = null
	_layer_content = null
	layers = 1  # the mesh draws the screen again

func _rebuild_layer() -> void:
	_free_layer()
	if not _layer_wanted or not is_inside_tree():
		return
	var curved := _arc() >= 0.001
	var cls := "OpenXRCompositionLayerCylinder" if curved else "OpenXRCompositionLayerQuad"
	if not ClassDB.class_exists(cls):
		return

	var w := mini(screen_width, LAYER_MAX_WIDTH)
	var h := maxi(1, int(round(float(screen_height) * w / screen_width)))
	_layer_viewport = SubViewport.new()
	_layer_viewport.size = Vector2i(w, h)
	_layer_viewport.transparent_bg = false
	_layer_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_layer_viewport)
	if _using_external_texture and _ext_tex:
		var rect := ColorRect.new()
		var mat := ShaderMaterial.new()
		mat.shader = load(LAYER_EXTERNAL_SHADER_PATH)
		mat.set_shader_parameter("screen_external", _ext_tex)
		mat.set_shader_parameter("tex_transform", Projection.IDENTITY)
		mat.set_shader_parameter("flip_x", 1 if DISPLAY_FLIP_X else 0)
		mat.set_shader_parameter("flip_y", 1 if DISPLAY_FLIP_Y else 0)
		rect.material = mat
		_layer_content = rect
	else:
		var tex_rect := TextureRect.new()
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
		tex_rect.texture = screen_texture
		_layer_content = tex_rect
	_layer_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_layer_viewport.add_child(_layer_content)

	_layer = ClassDB.instantiate(cls)
	_layer.name = "ScreenLayer%d" % get_instance_id()
	_layer.set("layer_viewport", _layer_viewport)
	_layer.set("enable_hole_punch", true)
	_layer.set("sort_order", -1)  # behind Godot's layer, seen through the hole
	_update_layer_geometry()
	_layer_origin.add_child(_layer)
	_sync_layer()
	layers = 0  # the layer shows the picture; the mesh stays for ray hits

func _update_layer_geometry() -> void:
	if not _layer:
		return
	if _layer.get_class() == "OpenXRCompositionLayerCylinder":
		if _arc() < 0.001:
			return  # turning flat: set_curvature() swaps in a quad layer next
		_layer.set("radius", _radius())
		_layer.set("central_angle", _arc())
		_layer.set("aspect_ratio", panel_width / panel_height)
		_layer.set("fallback_segments", CURVE_COLUMNS)
	else:
		_layer.set("quad_size", Vector2(panel_width, panel_height))

## The cylinder layer sits on its axis, looking at its arc along -Z: that is
## the panel's own frame moved forward by the radius.
func _sync_layer() -> void:
	var offset := Vector3(0.0, 0.0, _radius()) if _arc() >= 0.001 else Vector3.ZERO
	_layer.global_transform = global_transform * Transform3D(Basis(), offset)

## Called every frame a pointer rests on the panel: shows the grab bar.
func mark_hovered() -> void:
	if grab_bar:
		grab_bar.mark_owner_hovered()

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

	_upload_screen_image()

## Upload an already-decoded RGBA image to the panel texture. Used by the
## SoftwareVideoDecoder path (PC / iOS / web), where the JPEG decode runs off the
## main thread; this performs only the texture upload, which must run on the main
## thread. Decouples decoding from the panel so it never blocks rendering.
func update_decoded_image(img: Image) -> void:
	if not is_active or img == null:
		return
	screen_image = img
	if material_override is ShaderMaterial:
		(material_override as ShaderMaterial).set_shader_parameter("is_yuv", 0)
	_upload_screen_image()

## Push `screen_image` into the GPU texture, recreating it when size/format/mipmap
## state changed and updating in place otherwise.
func _upload_screen_image() -> void:
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

## Debug: save the latest decoded frame image to `path`. For the NV12 path this
## is an L8 image of size (w, h*1.5) — the top 2/3 is the desktop in luma, so a
## clean grayscale desktop means the decode is good; coloured/blocky noise means
## it isn't. Used by the adb test harness in main.gd. Returns true on success.
func save_debug_png(path: String) -> bool:
	if screen_image == null:
		return false
	return screen_image.save_png(path) == OK

## Grow/shrink the panel by `delta_width` metres (aspect kept).
func scale_panel(delta_width: float) -> void:
	set_panel_width(panel_width + delta_width)

func set_panel_width(width: float) -> void:
	panel_width = clamp(width, MIN_WIDTH, MAX_WIDTH)
	panel_height = panel_width / (float(screen_width) / float(screen_height))
	_rebuild_mesh()

## Programmatically set the panel position in world space.
func set_panel_position(pos: Vector3) -> void:
	global_transform.origin = pos

## Place the panel at `pos`, upright, its screen facing `look_from`.
func place_facing(pos: Vector3, look_from: Vector3) -> void:
	global_transform = Transform3D(LaserDrag.facing_basis(pos, look_from), pos)

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
			Vector3(basis_data[6], basis_data[7], basis_data[8])).orthonormalized()
		global_transform = Transform3D(
			restored_basis,
			Vector3(pos_data[0], pos_data[1], pos_data[2]))

	set_panel_width(float(state.get("panel_width", panel_width)))

# ---------------------------------------------------------------------------
# Laser drag — called from vr_input.gd
# ---------------------------------------------------------------------------

## Grab the panel with `pointer` (ray along its -Z), which hit it
## `hit_distance` metres away. The rest of its group (main.gd) comes along.
func start_drag(pointer: Node3D, hit_distance: float = -1.0) -> void:
	_drag = LaserDrag.new(self, pointer, hit_distance)
	var main := get_node_or_null("/root/Main")
	if main and main.has_method("drag_group_for"):
		_drag.add_followers(main.drag_group_for(self))

func stop_drag() -> void:
	_drag = null

func is_dragging() -> bool:
	return _drag != null

## While dragging: move the grabbed point along the ray (+ = away).
func push_pull(delta_m: float) -> void:
	if _drag:
		_drag.push_pull(delta_m)

func get_drag_distance() -> float:
	return _drag.distance if _drag else 0.0

# ---------------------------------------------------------------------------
# Geometry: flat quad or cylinder section
# ---------------------------------------------------------------------------

## Arc angle actually in use (0 = flat).
func _arc() -> float:
	return (_curvature_amount if _curved_mode else 0.0) * MAX_ARC

func _radius() -> float:
	return panel_width / _arc()

## Point on the screen surface for panel UV (u right, v down), local space.
## The screen faces +Z; a curved one bends its sides towards the viewer.
func local_point(u: float, v: float) -> Vector3:
	var y := (0.5 - v) * panel_height
	var arc := _arc()
	if arc < 0.001:
		return Vector3((u - 0.5) * panel_width, y, 0.0)
	var r := _radius()
	var phi := (u - 0.5) * arc
	return Vector3(r * sin(phi), y, r * (1.0 - cos(phi)))

func _rebuild_mesh() -> void:
	var arc := _arc()
	var columns := CURVE_COLUMNS if arc >= 0.001 else 1
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for i in range(columns + 1):
		var u := float(i) / columns
		var phi := (u - 0.5) * arc
		var n := Vector3(-sin(phi), 0.0, cos(phi))
		for v in [0.0, 1.0]:
			verts.append(local_point(u, v))
			normals.append(n)
			uvs.append(Vector2(u, v))
	for i in range(columns):
		var a := i * 2      # top-left
		var b := a + 1      # bottom-left
		var c := a + 2      # top-right
		var d := a + 3      # bottom-right
		indices.append_array([a, c, b, b, c, d])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am
	_apply_panel_size_to_material()
	_place_decorations()
	_update_layer_geometry()

# ---------------------------------------------------------------------------
# UV / pixel coordinate helpers
# ---------------------------------------------------------------------------

## Convert a 3D world position on the panel to screen UV coordinates.
## Returns Vector2(-1, -1) if the point is not on the screen surface.
func world_to_screen_uv(world_pos: Vector3) -> Vector2:
	var p: Vector3 = global_transform.affine_inverse() * world_pos
	var arc := _arc()
	var u: float
	if arc < 0.001:
		if absf(p.z) > 0.02:
			return Vector2(-1, -1)
		u = p.x / panel_width + 0.5
	else:
		var r := _radius()
		if absf(Vector2(p.x, r - p.z).length() - r) > 0.02:
			return Vector2(-1, -1)
		u = atan2(p.x, r - p.z) / arc + 0.5
	var v := 0.5 - p.y / panel_height
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return Vector2(-1, -1)
	return Vector2(u, v)

## Ray/screen intersection used by pointers.
## Returns { valid: bool, uv: Vector2, distance: float }.
func ray_to_screen_hit(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	var o: Vector3 = global_transform.affine_inverse() * ray_origin
	var d: Vector3 = (global_transform.basis.inverse() * ray_direction).normalized()
	var arc := _arc()
	if arc < 0.001:
		if absf(d.z) < 0.0001:
			return {"valid": false}
		var t := -o.z / d.z
		if t < 0.0:
			return {"valid": false}
		var p := o + d * t
		var uv := Vector2(p.x / panel_width + 0.5, 0.5 - p.y / panel_height)
		if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
			return {"valid": false}
		return {"valid": true, "uv": uv, "distance": t}

	# Cylinder around the vertical axis x=0, z=r; the screen is the part of
	# it behind the axis (z < r) within ±arc/2.
	var r := _radius()
	var oz := o.z - r
	var a := d.x * d.x + d.z * d.z
	if a < 0.000001:
		return {"valid": false}
	var b := 2.0 * (o.x * d.x + oz * d.z)
	var c := o.x * o.x + oz * oz - r * r
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return {"valid": false}
	var sq := sqrt(disc)
	for t in [(-b - sq) / (2.0 * a), (-b + sq) / (2.0 * a)]:
		if t < 0.0:
			continue
		var p: Vector3 = o + d * t
		if p.z >= r:
			continue
		var uv := Vector2(atan2(p.x, r - p.z) / arc + 0.5, 0.5 - p.y / panel_height)
		if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
			continue
		return {"valid": true, "uv": uv, "distance": t}
	return {"valid": false}

## Convert panel UV coordinates to desktop pixel coordinates for mouse input.
## This is a pure geometric mapping: the panel is set up so panel-UV (0,0) is the
## visual top-left and the display is corrected to show the desktop upright (see
## DISPLAY_FLIP_*), so UV maps straight to desktop pixels with (0,0)=top-left.
## The shader's texture-flip compensation is deliberately NOT applied here — it
## corrects how the decoded frame sits inside the OES texture, which is invisible
## to this geometric mapping. Folding it in would send the cursor to the opposite
## pixel from where the controller points.
func uv_to_pixel(uv: Vector2) -> Vector2i:
	return Vector2i(
		clampi(int(uv.x * screen_width), 0, screen_width - 1),
		clampi(int(uv.y * screen_height), 0, screen_height - 1)
	)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

func _create_placeholder_texture() -> void:
	screen_image = Image.create(screen_width, screen_height, false, Image.FORMAT_RGBA8)
	screen_image.fill(Color(0.075, 0.075, 0.068, 1.0))
	screen_texture = ImageTexture.create_from_image(screen_image)
	_texture_has_mipmaps = screen_image.has_mipmaps()
	_apply_texture()

	_placeholder_label = Label3D.new()
	_placeholder_label.text = "Waiting for the picture…"
	_placeholder_label.font_size = 40
	_placeholder_label.pixel_size = 0.0008
	_placeholder_label.modulate = Color(0.72, 0.71, 0.66, 0.9)
	_placeholder_label.outline_size = 0
	_placeholder_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_placeholder_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_placeholder_label)
	_place_decorations()

## Keep the label on the surface and the grab bar under the bottom edge.
func _place_decorations() -> void:
	if _placeholder_label:
		# The text is flat and ~0.4 m wide: lift it clear of the curve's bulge.
		var bulge := local_point(0.5 + 0.22 / panel_width, 0.5).z
		_placeholder_label.position = Vector3(0.0, 0.0, bulge + 0.004)
	if grab_bar:
		grab_bar.position = local_point(0.5, 1.0) + Vector3(0.0, -0.06, 0.0)

func _apply_texture() -> void:
	var mat := material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("screen_texture", screen_texture)
		# NV12 path samples the same texture through a point-sampled uniform.
		(mat as ShaderMaterial).set_shader_parameter("screen_texture_nv12", screen_texture)
	else:
		var shader := load(SCREEN_SHADER_PATH) as Shader
		var new_mat := ShaderMaterial.new()
		if shader:
			new_mat.shader = shader
		new_mat.set_shader_parameter("screen_texture", screen_texture)
		new_mat.set_shader_parameter("screen_texture_nv12", screen_texture)
		new_mat.set_shader_parameter("is_yuv", 0)
		material_override = new_mat

	_apply_panel_size_to_material()
	if _layer_content is TextureRect:
		(_layer_content as TextureRect).texture = screen_texture

## The shader rounds the corners in metres, so it needs the panel size.
func _apply_panel_size_to_material() -> void:
	if material_override is ShaderMaterial:
		(material_override as ShaderMaterial).set_shader_parameter(
			"panel_size_m", Vector2(panel_width, panel_height))
