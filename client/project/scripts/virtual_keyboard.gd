## Virtual keyboard for VR: a full US layout (Esc, Tab, symbols, arrows,
## Ctrl / Alt / Win) drawn as a 2D UI in a SubViewport on a floating quad, and
## driven by the controller or hand pointer through pointer_ray().
##
## Sends Windows virtual-key codes through main_scene.send_keyboard_input();
## the host translates them on Linux/macOS. Shift, Ctrl, Alt and Win latch for
## the next key only; Caps toggles. Holding a key repeats it.

extends Node3D
class_name VirtualKeyboard

const VIEW_SIZE := Vector2i(1500, 504)
const WIDTH_M := 0.75
const HEIGHT_M := WIDTH_M * VIEW_SIZE.y / VIEW_SIZE.x
const UNIT_PX := 90.0
const KEY_GAP := 8
const REPEAT_DELAY_S := 0.45
const REPEAT_RATE_HZ := 22.0

const MOD_SHIFT := 0x01
const MOD_CTRL := 0x02
const MOD_ALT := 0x04
const MOD_WIN := 0x08

## [label, shifted label, VK, width in key units, kind]. kind: "" = normal
## key, "mod" = one-shot modifier (value = its bit), "caps" = Caps Lock.
const ROWS := [
	[["Esc", "", 0x1B, 1.0, ""], ["1", "!", 0x31], ["2", "@", 0x32], ["3", "#", 0x33],
	 ["4", "$", 0x34], ["5", "%", 0x35], ["6", "^", 0x36], ["7", "&", 0x37],
	 ["8", "*", 0x38], ["9", "(", 0x39], ["0", ")", 0x30], ["-", "_", 0xBD],
	 ["=", "+", 0xBB], ["Backspace", "", 0x08, 2.0, ""]],
	[["Tab", "", 0x09, 1.5, ""], ["q", "Q", 0x51], ["w", "W", 0x57], ["e", "E", 0x45],
	 ["r", "R", 0x52], ["t", "T", 0x54], ["y", "Y", 0x59], ["u", "U", 0x55],
	 ["i", "I", 0x49], ["o", "O", 0x4F], ["p", "P", 0x50], ["[", "{", 0xDB],
	 ["]", "}", 0xDD], ["\\", "|", 0xDC, 1.5, ""]],
	[["Caps", "", 0x14, 1.75, "caps"], ["a", "A", 0x41], ["s", "S", 0x53], ["d", "D", 0x44],
	 ["f", "F", 0x46], ["g", "G", 0x47], ["h", "H", 0x48], ["j", "J", 0x4A],
	 ["k", "K", 0x4B], ["l", "L", 0x4C], [";", ":", 0xBA], ["'", "\"", 0xDE],
	 ["Return", "", 0x0D, 2.25, ""]],
	[["Shift", "", 0x10, 2.25, "mod"], ["z", "Z", 0x5A], ["x", "X", 0x58], ["c", "C", 0x43],
	 ["v", "V", 0x56], ["b", "B", 0x42], ["n", "N", 0x4E], ["m", "M", 0x4D],
	 [",", "<", 0xBC], [".", ">", 0xBE], ["/", "?", 0xBF],
	 ["Shift", "", 0x10, 1.75, "mod"], ["↑", "", 0x26, 1.0, ""]],
	[["Ctrl", "", 0x11, 1.5, "mod"], ["Win", "", 0x5B, 1.25, "mod"], ["Alt", "", 0x12, 1.25, "mod"],
	 ["", "", 0x20, 5.5, ""], ["`", "~", 0xC0], ["Delete", "", 0x2E, 1.5, ""],
	 ["←", "", 0x25, 1.0, ""], ["↓", "", 0x28, 1.0, ""], ["→", "", 0x27, 1.0, ""]],
]
const MOD_BITS := {0x10: MOD_SHIFT, 0x11: MOD_CTRL, 0x12: MOD_ALT, 0x5B: MOD_WIN}

## Monitor that receives the keys (main.gd keeps it on the pointed-at screen).
var active_monitor_id: int = 0
## One-shot modifiers waiting for the next key (MOD_* bits).
var latched_mods: int = 0
var caps_on: bool = false

@onready var main_scene: Node = get_node_or_null("/root/Main")

var _viewport: SubViewport
var _quad: MeshInstance3D
var _keys: Array = []          ## [{button, def}]
var _pointer_pressed := false
var _pointer_px := Vector2(-100, -100)
var _held_vk := -1
var _repeat_s := 0.0
var _drag: LaserDrag = null
var _finger := FingerTouch.new()
## The bar under the keyboard; main.gd::pick() tests it.
var grab_bar: GrabBar = null

var _style_key: StyleBoxFlat
var _style_key_hover: StyleBoxFlat
var _style_key_down: StyleBoxFlat
var _style_mod: StyleBoxFlat
var _style_latched: StyleBoxFlat

func _ready() -> void:
	_build()
	visible = false
	set_process(false)

func _process(delta: float) -> void:
	if _drag:
		_drag.update(delta)
	if _finger.tick():
		_leave()
	if _held_vk >= 0:
		_repeat_s += delta
		var interval := 1.0 / REPEAT_RATE_HZ
		while _repeat_s >= REPEAT_DELAY_S + interval:
			_repeat_s -= interval
			_tap(_held_vk)

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

## Where a ray meets the keyboard, touching nothing: { uv, distance }, or {}
## on a miss.
func ray_hit(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	if not visible:
		return {}
	var o: Vector3 = _quad.global_transform.affine_inverse() * ray_origin
	var d: Vector3 = _quad.global_basis.inverse() * ray_direction
	if absf(d.z) < 0.0001:
		return {}
	var t := -o.z / d.z
	var p := o + d * t
	var uv := Vector2(p.x / WIDTH_M + 0.5, 0.5 - p.y / HEIGHT_M)
	if t < 0.0 or uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return {}
	return {"uv": uv, "distance": t}

## Point at the keyboard with a ray. Returns the hit distance, or -1 when the
## ray misses (the caller then routes it to the screens instead). `pressing`
## is the trigger / pinch state; its changes press and release keys. A
## fingertip typing on it wins.
func pointer_ray(ray_origin: Vector3, ray_direction: Vector3, pressing: bool) -> float:
	var hit := ray_hit(ray_origin, ray_direction)
	if hit.is_empty():
		if _finger.owner < 0:
			_leave()
		return -1.0
	if _finger.owner < 0:
		_point(hit.uv, pressing)
	return hit.distance

## A fingertip at `tip` (world) typing on the keys; `who` tells the hands
## apart. True while this hand owns the keyboard (see FingerTouch).
func touch(who: int, tip: Vector3) -> bool:
	if not visible:
		return false
	var p: Vector3 = _quad.global_transform.affine_inverse() * tip
	var uv := Vector2(p.x / WIDTH_M + 0.5, 0.5 - p.y / HEIGHT_M)
	var was := _finger.owner
	if not _finger.touch(who, p.z, uv.x >= 0.0 and uv.x <= 1.0 and uv.y >= 0.0 and uv.y <= 1.0):
		if was == who:
			_leave()
		return false
	_point(uv, _finger.pressed)
	return true

func _point(uv: Vector2, pressing: bool) -> void:
	_pointer_px = uv * Vector2(VIEW_SIZE)
	var motion := InputEventMouseMotion.new()
	motion.position = _pointer_px
	motion.global_position = _pointer_px
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT if _pointer_pressed else 0
	_viewport.push_input(motion)
	if pressing != _pointer_pressed:
		_push_button(pressing)

## Legacy name kept for main.gd callers.
func pointer_update(world_pos: Vector3, is_pressing: bool) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam:
		pointer_ray(cam.global_position, (world_pos - cam.global_position).normalized(), is_pressing)

func start_drag(pointer: Node3D, hit_distance: float = -1.0) -> void:
	_leave()
	_drag = LaserDrag.new(self, pointer, hit_distance)

func stop_drag() -> void:
	_drag = null

func is_dragging() -> bool:
	return _drag != null

## The pointer went elsewhere: release a held key, clear the hover.
func pointer_leave() -> void:
	if _finger.owner < 0:
		_leave()

func push_pull(delta_m: float) -> void:
	if _drag:
		_drag.push_pull(delta_m)

func get_drag_distance() -> float:
	return _drag.distance if _drag else 0.0

# ---------------------------------------------------------------------------
# Pointer plumbing
# ---------------------------------------------------------------------------

func _push_button(pressed: bool) -> void:
	_pointer_pressed = pressed
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = _pointer_px
	ev.global_position = _pointer_px
	_viewport.push_input(ev)

## Pointer went away: release a held key and clear the hover highlight.
func _leave() -> void:
	if _pointer_pressed:
		_push_button(false)
	if _pointer_px.x >= 0.0:
		_pointer_px = Vector2(-100, -100)
		var motion := InputEventMouseMotion.new()
		motion.position = _pointer_px
		motion.global_position = _pointer_px
		_viewport.push_input(motion)
	_held_vk = -1

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

func _on_key_down(def: Array) -> void:
	var vk: int = def[2]
	var kind: String = def[4] if def.size() > 4 else ""
	if kind == "mod":
		latched_mods ^= MOD_BITS[vk]
		_refresh_labels()
		return
	if kind == "caps":
		caps_on = not caps_on
		_send(vk, 0)
		_refresh_labels()
		return
	_tap(vk)
	_held_vk = vk
	_repeat_s = 0.0
	if latched_mods != 0:
		latched_mods = 0
		_refresh_labels()

func _on_key_up() -> void:
	_held_vk = -1

## One key press + release with the latched modifiers held around it.
func _tap(vk: int) -> void:
	_send(vk, latched_mods)

func _send(vk: int, mods: int) -> void:
	if main_scene and main_scene.has_method("send_keyboard_input"):
		main_scene.send_keyboard_input(active_monitor_id, vk, true, mods)
		main_scene.send_keyboard_input(active_monitor_id, vk, false, mods)

func _refresh_labels() -> void:
	var shift := (latched_mods & MOD_SHIFT) != 0
	for k in _keys:
		var def: Array = k.def
		var b: Button = k.button
		var kind: String = def[4] if def.size() > 4 else ""
		if kind == "mod":
			var on: bool = (latched_mods & MOD_BITS[def[2]]) != 0
			_style_button(b, _style_latched if on else _style_mod, on)
		elif kind == "caps":
			_style_button(b, _style_latched if caps_on else _style_mod, caps_on)
		elif def[1] != "":
			var letter: bool = String(def[0]).length() == 1 and String(def[0]) >= "a" and String(def[0]) <= "z"
			var upper := (shift != caps_on) if letter else shift
			b.text = def[1] if upper else def[0]

# ---------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------

func _build() -> void:
	_style_key = UiTheme.box(UiTheme.SURFACE_HI, 12, 4, 2)
	_style_key_hover = UiTheme.box(UiTheme.SURFACE_HOVER, 12, 4, 2)
	_style_key_down = UiTheme.box(UiTheme.INK, 12, 4, 2)
	_style_mod = UiTheme.box(UiTheme.SURFACE, 12, 4, 2, UiTheme.EDGE)
	_style_latched = UiTheme.box(UiTheme.INK_2, 12, 4, 2)

	_viewport = SubViewport.new()
	_viewport.size = VIEW_SIZE
	_viewport.transparent_bg = true
	_viewport.gui_embed_subwindows = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	var board := PanelContainer.new()
	board.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	board.add_theme_stylebox_override("panel", UiTheme.box(Color(UiTheme.GROUND, 0.96), 26, 16, 16, UiTheme.EDGE))
	_viewport.add_child(board)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", KEY_GAP)
	board.add_child(rows)
	for row in ROWS:
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", KEY_GAP)
		hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
		rows.add_child(hbox)
		for def in row:
			hbox.add_child(_make_key(def))
	_refresh_labels()

	_quad = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(WIDTH_M, HEIGHT_M)
	_quad.mesh = quad
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
	grab_bar.position = Vector3(0.0, -HEIGHT_M / 2.0 - 0.045, 0.0)
	add_child(grab_bar)

func _make_key(def: Array) -> Button:
	var units: float = def[3] if def.size() > 3 else 1.0
	var kind: String = def[4] if def.size() > 4 else ""
	var b := Button.new()
	b.text = def[0]
	b.focus_mode = Control.FOCUS_NONE
	b.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_stretch_ratio = units
	b.custom_minimum_size = Vector2(UNIT_PX * units * 0.5, 0)
	b.clip_text = true
	var long_label := String(def[0]).length() > 1
	# Caps use the neutral font: every symbol must read at a glance.
	b.add_theme_font_size_override("font_size", 25 if long_label else 34)
	b.custom_minimum_size.y = 80
	_style_button(b, _style_mod if (kind != "" or long_label) else _style_key, false)
	b.button_down.connect(_on_key_down.bind(def))
	b.button_up.connect(_on_key_up)
	_keys.append({"button": b, "def": def})
	return b

func _style_button(b: Button, normal: StyleBoxFlat, lit: bool) -> void:
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", normal if lit else _style_key_hover)
	b.add_theme_stylebox_override("pressed", _style_key_down)
	b.add_theme_stylebox_override("hover_pressed", _style_key_down)
	var ink := UiTheme.GROUND if lit else UiTheme.INK
	b.add_theme_color_override("font_color", ink if lit or normal == _style_key else UiTheme.INK_2)
	b.add_theme_color_override("font_hover_color", ink if lit else UiTheme.INK)
	b.add_theme_color_override("font_pressed_color", UiTheme.GROUND)
	b.add_theme_color_override("font_hover_pressed_color", UiTheme.GROUND)

func _reposition_in_front_of_camera() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var fwd := -camera.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 0.0001 else Vector3.FORWARD
	var pos := camera.global_position + fwd * 0.5 + Vector3(0.0, -0.32, 0.0)
	global_transform = Transform3D(LaserDrag.facing_basis(pos, camera.global_position), pos)
