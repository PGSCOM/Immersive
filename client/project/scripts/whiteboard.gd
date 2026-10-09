## A whiteboard floating in the room: draw on it with a fingertip (touch it,
## hand tracking), or point and press (trigger / pinch). A 2D canvas in a
## SubViewport on a quad, like the VR keyboard.
##
## A fingertip close in front of the board owns it and shows a ring where it
## will land, shrinking as the finger closes in; touching it draws (depths in
## FingerTouch; the other hand takes over by touching between strokes). The tool row along the bottom picks the ink, the width, the eraser,
## undo and clear (clear can be undone too). The bar under it moves it, the
## corner brackets resize it (ResizeHandle, as on the screens), the grip and
## stick move and size it. Strokes live as long as the app does.

extends Node3D
class_name Whiteboard

const VIEW_SIZE := Vector2i(1600, 1040)
const MIN_WIDTH := 0.5
const MAX_WIDTH := 3.0
const INKS := [UiTheme.INK, UiTheme.CLAY, UiTheme.SAGE, UiTheme.OCHRE]
const WIDTHS := [5.0, 12.0, 30.0]
const ERASER_PX := 56.0
const SLATE := UiTheme.WELL
## How far the hover ring stands out at HOVER_M, in canvas pixels.
const RING_SPREAD_PX := 40.0

var panel_width := 1.2
var panel_height := panel_width * VIEW_SIZE.y / VIEW_SIZE.x
var grab_bar: GrabBar = null
var resize_handles: Array[ResizeHandle] = []

var _viewport: SubViewport
var _quad: MeshInstance3D
var _canvas: Control
var _ink: Control          ## strokes (Line2D) and clear markers, oldest first
var _cursor: Control
var _stroke: Line2D = null
var _smoothed := Vector2.ZERO
var _color: Color = INKS[0]
var _width: float = WIDTHS[1]
var _erasing := false
var _dots: Array = []      ## [Dot, kind ("ink" / "width"), value]
var _btn_eraser: Button

var _pointer_pressed := false
var _pointer_px := Vector2(-100, -100)
var _ring := -1.0          ## hover depth 0..1 of the fingertip, -1 = none
var _finger := FingerTouch.new()
var _drag: LaserDrag = null

func _ready() -> void:
	_build()
	set_shown(false)

func _process(delta: float) -> void:
	if _drag:
		_drag.update(delta)
	if _finger.tick():
		_leave()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func toggle_visibility() -> void:
	set_shown(not visible)

func set_shown(show_it: bool) -> void:
	visible = show_it
	set_process(show_it)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if show_it \
		else SubViewport.UPDATE_DISABLED
	if show_it:
		_reposition_in_front_of_camera()
	else:
		_leave()
		_finger.release()
		_drag = null

## Where a ray meets the board: { uv, distance }, or {} on a miss.
func ray_hit(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	if not visible:
		return {}
	var o := global_transform.affine_inverse() * ray_origin
	var d := global_basis.inverse() * ray_direction
	if absf(d.z) < 0.0001:
		return {}
	var t := -o.z / d.z
	var uv := _uv(o + d * t)
	if t < 0.0 or not _inside(uv):
		return {}
	return {"uv": uv, "distance": t}

## Point at the board with a ray; `pressing` (trigger / pinch) draws. Returns
## the hit distance, or -1 on a miss. A fingertip on the board wins.
func pointer_ray(ray_origin: Vector3, ray_direction: Vector3, pressing: bool) -> float:
	var hit := ray_hit(ray_origin, ray_direction)
	if hit.is_empty():
		if _finger.owner < 0:
			_leave()
		return -1.0
	if _finger.owner < 0:
		_ring = 0.0
		_point(hit.uv, pressing)
	return hit.distance

## A fingertip at `tip` (world); `who` tells the hands apart. True while this
## hand owns the board (see FingerTouch).
func touch(who: int, tip: Vector3) -> bool:
	if not visible:
		return false
	var p := to_local(tip)
	var uv := _uv(p)
	var was := _finger.owner
	if not _finger.touch(who, p.z, _inside(uv)):
		if was == who:
			_leave()
		return false
	_ring = clampf(p.z / FingerTouch.HOVER_M, 0.0, 1.0)
	_point(uv, _finger.pressed)
	return true

## True while the fingertip that owns it came close enough to rest its
## hand's ray (FingerTouch.resting); hovering further out, the ray points on.
func finger_rests() -> bool:
	return _finger.owner >= 0 and _finger.resting

## The pointer went elsewhere: end the stroke, hide the ring.
func pointer_leave() -> void:
	if _finger.owner < 0:
		_leave()

func start_drag(pointer: Node3D, hit_distance: float = -1.0) -> void:
	_leave()
	_drag = LaserDrag.new(self, pointer, hit_distance)

func stop_drag() -> void:
	_drag = null

func is_dragging() -> bool:
	return _drag != null

func push_pull(delta_m: float) -> void:
	if _drag:
		_drag.push_pull(delta_m)

func get_drag_distance() -> float:
	return _drag.distance if _drag else 0.0

func scale_panel(delta_width: float) -> void:
	set_panel_width(panel_width + delta_width)

## Resize keeping the aspect: the drawing scales with the board.
func set_panel_width(width: float) -> void:
	panel_width = clampf(width, MIN_WIDTH, MAX_WIDTH)
	panel_height = panel_width * VIEW_SIZE.y / VIEW_SIZE.x
	(_quad.mesh as QuadMesh).size = Vector2(panel_width, panel_height)
	grab_bar.position = Vector3(0.0, -panel_height / 2.0 - 0.045, 0.0)
	for h in resize_handles:
		h.position = local_point(0.5 + 0.5 * h.corner.x, 0.5 - 0.5 * h.corner.y)

## Point on the board for UV (u right, v down), local space (ResizeHandle).
func local_point(u: float, v: float) -> Vector3:
	return Vector3((u - 0.5) * panel_width, (0.5 - v) * panel_height, 0.0)

func stroke_count() -> int:
	return _ink.get_children().filter(func(c): return c is Line2D and c.visible).size()

func undo() -> void:
	_stroke = null
	var last: Node = _ink.get_child(-1) if _ink.get_child_count() > 0 else null
	if last == null:
		return
	if last.has_meta("cleared"):
		for s in last.get_meta("cleared"):
			s.visible = true
	_ink.remove_child(last)
	last.queue_free()

## Hide every stroke behind one marker, so undo brings them all back.
func clear() -> void:
	_stroke = null
	var shown := _ink.get_children().filter(func(c): return c is Line2D and c.visible)
	if shown.is_empty():
		return
	for s in shown:
		s.visible = false
	var marker := Control.new()
	marker.set_meta("cleared", shown)
	_ink.add_child(marker)

# ---------------------------------------------------------------------------
# Pointer plumbing
# ---------------------------------------------------------------------------

func _uv(p: Vector3) -> Vector2:
	return Vector2(p.x / panel_width + 0.5, 0.5 - p.y / panel_height)

func _inside(uv: Vector2) -> bool:
	return uv.x >= 0.0 and uv.x <= 1.0 and uv.y >= 0.0 and uv.y <= 1.0

func _point(uv: Vector2, pressing: bool) -> void:
	_pointer_px = uv * Vector2(VIEW_SIZE)
	var motion := InputEventMouseMotion.new()
	motion.position = _pointer_px
	motion.global_position = _pointer_px
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT if _pointer_pressed else 0
	_viewport.push_input(motion)
	if pressing != _pointer_pressed:
		_push_button(pressing)
	_cursor.queue_redraw()

func _push_button(pressed: bool) -> void:
	_pointer_pressed = pressed
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = _pointer_px
	ev.global_position = _pointer_px
	_viewport.push_input(ev)

func _leave() -> void:
	if _pointer_pressed:
		_push_button(false)
	_stroke = null
	_ring = -1.0
	if _pointer_px.x >= 0.0:
		_pointer_px = Vector2(-100, -100)
		var motion := InputEventMouseMotion.new()
		motion.position = _pointer_px
		motion.global_position = _pointer_px
		_viewport.push_input(motion)
	_cursor.queue_redraw()

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

func _on_canvas_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed:
			_begin(ev.position)
		else:
			_stroke = null
	elif ev is InputEventMouseMotion and _stroke and (ev.button_mask & MOUSE_BUTTON_MASK_LEFT):
		# Light smoothing takes the fingertip's tremor out of the line.
		_smoothed = _smoothed.lerp(ev.position, 0.5)
		if _smoothed.distance_to(_stroke.points[-1]) > 2.0:
			_stroke.add_point(_smoothed)

func _begin(at: Vector2) -> void:
	_stroke = Line2D.new()
	_stroke.width = ERASER_PX if _erasing else _width
	_stroke.default_color = SLATE if _erasing else _color
	_stroke.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_stroke.end_cap_mode = Line2D.LINE_CAP_ROUND
	_stroke.joint_mode = Line2D.LINE_JOINT_ROUND
	# Two points, so a tap leaves a dot.
	_stroke.points = PackedVector2Array([at, at + Vector2(0.5, 0.0)])
	_smoothed = at
	_ink.add_child(_stroke)

func _draw_cursor() -> void:
	if _ring < 0.0 or _pointer_pressed:
		return
	var at := _pointer_px - _canvas.global_position
	var r := (ERASER_PX if _erasing else _width) / 2.0 + _ring * RING_SPREAD_PX
	_cursor.draw_arc(at, r, 0.0, TAU, 48, Color(UiTheme.INK if _erasing else _color, 0.85), 3.0, true)

func _select(kind: String, value) -> void:
	if kind == "ink":
		_color = value
		_erasing = false
	else:
		_width = value
	for d in _dots:
		d[0].selected = (d[1] == "ink" and not _erasing and d[2] == _color) \
			or (d[1] == "width" and d[2] == _width)
		if d[1] == "width":
			d[0].color = UiTheme.INK_3 if _erasing else _color  # the widths preview the ink
		d[0].queue_redraw()
	_style_eraser()

func _toggle_eraser() -> void:
	_erasing = not _erasing
	_select("width", _width)

# ---------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------

## A round swatch: an ink, or a width shown as a dot of that size.
class Dot extends Button:
	var color := Color.WHITE
	var radius := 10.0
	var selected := false

	func _draw() -> void:
		var c := size / 2.0
		draw_circle(c, radius, color, true, -1.0, true)
		if selected or is_hovered():
			draw_arc(c, radius + 9.0, 0.0, TAU, 48, Color(UiTheme.INK, 1.0 if selected else 0.35), 3.0, true)

func _build() -> void:
	_viewport = SubViewport.new()
	_viewport.size = VIEW_SIZE
	_viewport.transparent_bg = true
	_viewport.msaa_2d = Viewport.MSAA_4X
	_viewport.gui_embed_subwindows = true
	add_child(_viewport)

	var board := PanelContainer.new()
	board.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	board.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.GROUND, 30, 18, 18, UiTheme.EDGE))
	_viewport.add_child(board)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	board.add_child(column)

	# The slate clips the ink to its own rounded shape.
	var slate := Panel.new()
	slate.size_flags_vertical = Control.SIZE_EXPAND_FILL
	slate.add_theme_stylebox_override("panel", UiTheme.box(SLATE, 18))
	slate.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	column.add_child(slate)
	_canvas = Control.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.gui_input.connect(_on_canvas_input)
	slate.add_child(_canvas)
	_ink = Control.new()
	_ink.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_ink)
	_cursor = Control.new()
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.draw.connect(_draw_cursor)
	_canvas.add_child(_cursor)

	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	tools.custom_minimum_size.y = 84
	column.add_child(tools)
	for c in INKS:
		tools.add_child(_dot("ink", c, c, 17.0))
	tools.add_child(_gap())
	for w in WIDTHS:
		tools.add_child(_dot("width", w, _color, w / 2.0 + 2.0))
	tools.add_child(_gap())
	_btn_eraser = _button("Eraser", _toggle_eraser)
	tools.add_child(_btn_eraser)
	tools.add_child(_button("Undo", undo))
	tools.add_child(_button("Clear", clear))
	_select("ink", _color)

	_quad = MeshInstance3D.new()
	_quad.mesh = QuadMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = _viewport.get_texture()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	_quad.material_override = mat
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_quad)
	_quad.add_to_group(&"covers_hands")  # main.gd::_apply_hand_mask
	grab_bar = GrabBar.new()
	grab_bar.always_shown = true
	add_child(grab_bar)
	for c in [Vector2(-1, 1), Vector2(1, 1), Vector2(-1, -1), Vector2(1, -1)]:
		var handle := ResizeHandle.new(c)
		add_child(handle)
		resize_handles.append(handle)
	set_panel_width(panel_width)

func _dot(kind: String, value, color: Color, radius: float) -> Dot:
	var d := Dot.new()
	d.color = color
	d.radius = radius
	d.focus_mode = Control.FOCUS_NONE
	d.custom_minimum_size = Vector2(84, 84)
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		d.add_theme_stylebox_override(s, UiTheme.empty())
	d.pressed.connect(_select.bind(kind, value))
	d.mouse_entered.connect(d.queue_redraw)
	d.mouse_exited.connect(d.queue_redraw)
	_dots.append([d, kind, value])
	return d

func _gap() -> Control:
	var g := Control.new()
	g.custom_minimum_size.x = 40
	return g

func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 30)
	b.pressed.connect(on_press)
	_style_text_button(b, false)
	return b

func _style_eraser() -> void:
	if _btn_eraser:
		_style_text_button(_btn_eraser, _erasing)

## Same boxes as the keyboard's keys; lit = bone fill, like a latched modifier.
func _style_text_button(b: Button, lit: bool) -> void:
	var normal := UiTheme.box(UiTheme.INK_2 if lit else UiTheme.SURFACE_HI, 14, 18, 8)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", normal if lit else UiTheme.box(UiTheme.SURFACE_HOVER, 14, 18, 8))
	b.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.INK, 14, 18, 8))
	b.add_theme_stylebox_override("hover_pressed", UiTheme.box(UiTheme.INK, 14, 18, 8))
	b.add_theme_stylebox_override("focus", UiTheme.empty())
	var ink := UiTheme.GROUND if lit else UiTheme.INK
	for c in ["font_color", "font_hover_color"]:
		b.add_theme_color_override(c, ink)
	for c in ["font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(c, UiTheme.GROUND)

func _reposition_in_front_of_camera() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var fwd := -camera.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 0.0001 else Vector3.FORWARD
	var pos := camera.global_position + fwd * 0.75 + Vector3(0.0, -0.15, 0.0)
	global_transform = Transform3D(LaserDrag.facing_basis(pos, camera.global_position), pos)
