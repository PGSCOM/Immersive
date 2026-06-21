## Virtual QWERTY keyboard for VR.
##
## Rendered as a Node3D floating panel with MeshInstance3D keys.
## Activated by pressing the A/X button on the left controller.
## Sends Windows virtual-key scancodes to the host via
## main_scene.send_keyboard_input().
##
## Layout rows:
##   Row 0: 1 2 3 4 5 6 7 8 9 0
##   Row 1: Q W E R T Y U I O P
##   Row 2: A S D F G H J K L
##   Row 3: Z X C V B N M
##   Row 4: [Shift] [Space] [Backspace] [Enter] [Ctrl]

extends Node3D
class_name VirtualKeyboard

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const KEY_WIDTH  : float = 0.06
const KEY_HEIGHT : float = 0.055
const KEY_DEPTH  : float = 0.012
const KEY_GAP    : float = 0.008
const KEY_Z_PRESS: float = 0.008   # Z offset when key is pressed

# Windows virtual-key codes for each keycap
# Reference: https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
const VK_SHIFT     = 0x10
const VK_CONTROL   = 0x11
const VK_RETURN    = 0x0D
const VK_BACK      = 0x08
const VK_SPACE     = 0x20

# Key layout: each entry is [label, vk_code, width_multiplier]
const KEY_ROWS = [
	[["1",0x31],["2",0x32],["3",0x33],["4",0x34],["5",0x35],
	 ["6",0x36],["7",0x37],["8",0x38],["9",0x39],["0",0x30]],

	[["Q",0x51],["W",0x57],["E",0x45],["R",0x52],["T",0x54],
	 ["Y",0x59],["U",0x55],["I",0x49],["O",0x4F],["P",0x50]],

	[["A",0x41],["S",0x53],["D",0x44],["F",0x46],["G",0x47],
	 ["H",0x48],["J",0x4A],["K",0x4B],["L",0x4C]],

	[["Z",0x5A],["X",0x58],["C",0x43],["V",0x56],["B",0x42],
	 ["N",0x4E],["M",0x4D]],

	[["Shift",VK_SHIFT, 1.5],["Space",VK_SPACE, 3.0],
	 ["Bksp", VK_BACK,  1.5],["Enter",VK_RETURN,1.5],
	 ["Ctrl", VK_CONTROL,1.5]]
]

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

## Reference to the main scene controller for send_keyboard_input.
@onready var main_scene: Node3D = get_node("/root/Main")

## Whether Shift is currently latched.
var shift_active: bool = false
## Whether Ctrl is currently latched.
var ctrl_active: bool = false

## Active monitor to send input to.
var active_monitor_id: int = 0

## Map from MeshInstance3D → [label, vk_code]
var _key_nodes: Dictionary = {}

## Currently hovered key.
var _hovered_key: MeshInstance3D = null

## Edge-detection latch so a held press types a key only once (not every frame).
var _press_was_active: bool = false

## Whether the key meshes have been built yet (lazy, so the keyboard is usable
## the first time it is shown or pointed at, regardless of _ready() timing).
var _built: bool = false

# Materials
var _mat_normal:  StandardMaterial3D
var _mat_hover:   StandardMaterial3D
var _mat_pressed: StandardMaterial3D
var _mat_active:  StandardMaterial3D  # Shift/Ctrl when latched

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_ensure_built()
	visible = false

## Build the key meshes once (idempotent). Called from _ready() and lazily from
## the first interaction so the keyboard works even if _ready() has not run yet.
func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_build_materials()
	_build_keyboard()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Show or hide the keyboard.
func toggle_visibility() -> void:
	_ensure_built()
	visible = not visible
	if visible:
		_reposition_in_front_of_camera()

## Called from vr_input.gd with the world-space tip position of the
## left-hand index finger / pointer.
## Returns the vk_code of any key that was triggered, or -1.
func pointer_update(world_pos: Vector3, is_pressing: bool) -> int:
	_ensure_built()
	# Compare in the keyboard's local frame: keys are positioned locally, so this
	# is independent of where the keyboard sits in the world (and robust in tests
	# where global transforms are not propagated).
	var local: Vector3 = global_transform.affine_inverse() * world_pos
	var best_key: MeshInstance3D = null
	var best_dist: float = 0.04  # max hit radius in metres

	for key_node in _key_nodes.keys():
		if not is_instance_valid(key_node): continue
		var d: float = key_node.position.distance_to(local)
		if d < best_dist:
			best_dist = d
			best_key  = key_node

	# Update hover highlight
	if _hovered_key != null and _hovered_key != best_key:
		_set_key_material(_hovered_key, _mat_normal)
		_hovered_key = null

	var triggered: int = -1
	if best_key != null:
		_hovered_key = best_key
		# Only fire on the press edge so a held trigger/pinch types a key once.
		if is_pressing and not _press_was_active:
			_set_key_material(best_key, _mat_pressed)
			triggered = _activate_key(best_key)
		elif not is_pressing:
			_set_key_material(best_key, _mat_hover)

	_press_was_active = is_pressing
	return triggered

## Ray-based interaction for the controller / hand pointer.
## Intersects the ray with the keyboard's plane and drives the same hover/press
## logic as pointer_update(). Returns { valid: bool, distance: float, vk: int };
## valid is true when the ray is over a key (so the caller should not also act on
## a panel behind the keyboard).
func ray_update(ray_origin: Vector3, ray_direction: Vector3, is_pressing: bool) -> Dictionary:
	if not visible:
		return {"valid": false}

	# Plane through the keyboard origin with the keyboard's local +Z as normal.
	var normal: Vector3 = global_transform.basis.z.normalized()
	var denom: float = ray_direction.dot(normal)
	if absf(denom) < 0.0001:
		return {"valid": false}
	var t: float = (global_transform.origin - ray_origin).dot(normal) / denom
	if t < 0.0:
		return {"valid": false}

	var hit_point: Vector3 = ray_origin + ray_direction * t
	var vk: int = pointer_update(hit_point, is_pressing)
	# pointer_update() leaves _hovered_key set only when the hit was within a key.
	return {"valid": _hovered_key != null, "distance": t, "vk": vk}

# ---------------------------------------------------------------------------
# Building the keyboard
# ---------------------------------------------------------------------------

func _build_materials() -> void:
	_mat_normal = StandardMaterial3D.new()
	_mat_normal.albedo_color = Color(0.18, 0.18, 0.22)
	_mat_normal.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL

	_mat_hover = StandardMaterial3D.new()
	_mat_hover.albedo_color = Color(0.30, 0.45, 0.70)
	_mat_hover.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL

	_mat_pressed = StandardMaterial3D.new()
	_mat_pressed.albedo_color = Color(0.80, 0.80, 1.00)
	_mat_pressed.emission_enabled = true
	_mat_pressed.emission = Color(0.6, 0.6, 1.0)
	_mat_pressed.emission_energy_multiplier = 1.5

	_mat_active = StandardMaterial3D.new()
	_mat_active.albedo_color = Color(0.20, 0.65, 0.35)
	_mat_active.emission_enabled = true
	_mat_active.emission = Color(0.1, 0.5, 0.2)

func _build_keyboard() -> void:
	var total_rows: int = KEY_ROWS.size()
	var start_y: float  = (total_rows - 1) * (KEY_HEIGHT + KEY_GAP) / 2.0

	for row_idx in range(total_rows):
		var row: Array = KEY_ROWS[row_idx]

		# Calculate total row width
		var total_width: float = 0.0
		for key_def in row:
			var mult: float = float(key_def[2]) if key_def.size() >= 3 else 1.0
			total_width += KEY_WIDTH * mult + KEY_GAP
		total_width -= KEY_GAP

		var x: float = -total_width / 2.0
		var y: float = start_y - row_idx * (KEY_HEIGHT + KEY_GAP)

		for key_def in row:
			var label: String = key_def[0]
			var vk:    int    = key_def[1]
			var mult:  float  = float(key_def[2]) if key_def.size() >= 3 else 1.0
			var kw:    float  = KEY_WIDTH * mult
			var cx:    float  = x + kw / 2.0

			var key_node := _make_key(label, vk, kw, cx, y)
			add_child(key_node)

			x += kw + KEY_GAP

## Create a single key MeshInstance3D.
func _make_key(label: String, vk_code: int, width: float, cx: float, cy: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = "Key_%s" % label

	var box := BoxMesh.new()
	box.size = Vector3(width - 0.002, KEY_HEIGHT - 0.002, KEY_DEPTH)
	node.mesh = box
	node.material_override = _mat_normal.duplicate()

	node.position = Vector3(cx, cy, 0.0)

	# Label
	var lbl := Label3D.new()
	lbl.text = label
	lbl.font_size = 18
	lbl.modulate = Color.WHITE
	lbl.no_depth_test = true
	lbl.position = Vector3(0.0, 0.0, KEY_DEPTH / 2.0 + 0.002)
	lbl.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	node.add_child(lbl)

	_key_nodes[node] = [label, vk_code]
	return node

# ---------------------------------------------------------------------------
# Key activation
# ---------------------------------------------------------------------------

func _activate_key(key_node: MeshInstance3D) -> int:
	var info: Array = _key_nodes.get(key_node, [])
	if info.size() < 2:
		return -1

	var label:   String = info[0]
	var vk_code: int    = info[1]

	# Handle modifier latching
	if vk_code == VK_SHIFT:
		shift_active = not shift_active
		_set_key_material(key_node, _mat_active if shift_active else _mat_normal)
		return -1

	if vk_code == VK_CONTROL:
		ctrl_active = not ctrl_active
		_set_key_material(key_node, _mat_active if ctrl_active else _mat_normal)
		return -1

	# Build modifier bitmask: bit0=shift, bit1=ctrl, bit2=alt
	var mods: int = 0
	if shift_active: mods |= 0x01
	if ctrl_active:  mods |= 0x02

	# Send key-down + key-up pair
	if main_scene and main_scene.has_method("send_keyboard_input"):
		main_scene.send_keyboard_input(active_monitor_id, vk_code, true,  mods)
		main_scene.send_keyboard_input(active_monitor_id, vk_code, false, mods)

	# Auto-release Shift after one keypress
	if shift_active and vk_code != VK_SHIFT:
		shift_active = false
		for kn in _key_nodes:
			var kinfo: Array = _key_nodes[kn]
			if kinfo.size() >= 2 and kinfo[1] == VK_SHIFT:
				_set_key_material(kn, _mat_normal)

	# Animate key press
	_animate_key_press(key_node)

	print("[VirtualKeyboard] Key: %s (vk=0x%02X) mods=0x%02X" % [label, vk_code, mods])
	return vk_code

func _animate_key_press(key_node: MeshInstance3D) -> void:
	# Tweens require the node to be inside the tree; skip the cosmetic animation
	# when it is not (e.g. headless tests) rather than dereference a null tween.
	if not is_inside_tree():
		return
	# Move key down slightly, then restore after 80 ms
	key_node.position.z -= KEY_Z_PRESS
	var tween := create_tween()
	tween.tween_property(key_node, "position:z",
		key_node.position.z + KEY_Z_PRESS, 0.08)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _set_key_material(key_node: MeshInstance3D, mat: StandardMaterial3D) -> void:
	if is_instance_valid(key_node):
		key_node.material_override = mat

func _reposition_in_front_of_camera() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var camera := vp.get_camera_3d()
	if camera == null:
		return
	var forward: Vector3 = -camera.global_transform.basis.z
	global_position = camera.global_position + forward * 0.6 + Vector3(0.0, -0.15, 0.0)
	global_rotation = camera.global_rotation
