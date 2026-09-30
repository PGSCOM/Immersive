## Hand-tracking input for Immersive-2 (Pico 4 + SteamVR + Quest).
##
## Lets the user drive the virtual desktop with bare hands — no controllers:
##   • Right hand — point with the arm; pinch (thumb + index) = left click,
##     hold-and-move = click-drag. Works on both the streamed monitor panels and
##     the in-VR overlay menu, with a visible laser + cursor for aiming feedback.
##   • Left hand  — pinch-and-hold (~0.65 s) toggles the overlay menu.
##
## Platform-agnostic: it consumes the OpenXR XR_EXT_hand_tracking joints exposed
## by Godot as XRHandTracker, so the same code path serves Pico 4 / Quest (Android)
## and SteamVR (Windows). It only acts when a hand is *optically* tracked, so it
## never fights the controller input path (vr_input.gd) — see _is_optical...().
##
## Requirements:
##   • project setting  xr/openxr/extensions/hand_tracking = true  (project.godot)
##   • Pico:  <meta-data android:name="handtracking" android:value="1"/> in the
##            Android manifest (added by addons/im2_decoder/im2_decoder.gd)
##   • Quest: export preset xr_features/hand_tracking >= 1

extends Node

## Thumb-tip to index-tip distance that starts a pinch, and the wider one that
## ends it (the gap keeps a half-closed pinch from flickering).
const PINCH_PRESS_M := 0.02
const PINCH_RELEASE_M := 0.035
## The pinch must look open this long before it lets go. Pico drops or jolts
## the finger tips for a frame or two mid-pinch (the thumb hides behind the
## index), which used to release the click after ~30 ms and re-press it.
const PINCH_RELEASE_HOLD_S := 0.12
const OVERLAY_TOGGLE_HOLD_S := 0.65
const KEYBOARD_TOGGLE_HOLD_S := 1.6
## The ray runs from an estimated shoulder (head + these offsets) through the
## index knuckle, like the Quest / Pico system pointer. It follows the arm, not
## the finger, so curling the index into a pinch does not move it.
const SHOULDER_DOWN_M := 0.18
const SHOULDER_SIDE_M := 0.17
## One Euro filter on the ray direction: steady when the hand is still, little
## lag when it moves fast. Raise MIN_CUTOFF if it feels slow, lower it if jittery.
const FILTER_MIN_CUTOFF := 1.0
const FILTER_BETA := 4.0
## A pinch holds the ray still until the hand moves this far (~1.5°), so a click
## never turns into a tiny drag (breaks double-clicks, selects text).
const CLICK_SLOP_RAD := 0.026
const MAX_RAY_LENGTH := 8.0

@onready var main_scene: Node = get_node_or_null("/root/Main")
@onready var xr_origin: XROrigin3D = get_node_or_null("/root/Main/XROrigin3D")

var _right_hand_tracker: XRHandTracker = null
var _left_hand_tracker: XRHandTracker = null

# Right-hand pointer state.
var _pinch_active: bool = false     # button held down on a target
var _right_pinching: bool = false   # fingers pinched (with hysteresis)
var _right_tracked: bool = false
var _press_origin: Vector3 = Vector3.ZERO
var _press_dir: Vector3 = Vector3.FORWARD
var _dragging: bool = false
var _on_overlay: bool = false
var _last_monitor_id: int = 0
var _last_pixel: Vector2i = Vector2i.ZERO

# One Euro filter state for the ray direction (ZERO = start over).
var _dir_filtered: Vector3 = Vector3.ZERO
var _dir_rate: Vector3 = Vector3.ZERO

# Left-hand overlay-toggle state.
var _left_pinching: bool = false
var _open_s: Dictionary = {}  # tracker -> seconds its pinch has looked open
var _left_hold_time: float = 0.0
var _left_toggle_latched: bool = false
var _left_kbd_latched: bool = false

# Visual pointer (laser beam + cursor dot), created lazily in the world.
var _laser: MeshInstance3D = null
var _cursor: MeshInstance3D = null

func _ready() -> void:
	set_process(true)

func _exit_tree() -> void:
	if is_instance_valid(_laser):
		_laser.queue_free()
	if is_instance_valid(_cursor):
		_cursor.queue_free()

func _process(delta: float) -> void:
	_refresh_trackers()

	var tracked := _is_optical_hand_tracking(_right_hand_tracker)
	if tracked != _right_tracked:
		_right_tracked = tracked
		print("[HandInput] Right hand %s" % ["tracked" if tracked else "lost"])
	if tracked:
		_process_right_hand_pointer(delta)
	else:
		_right_pinching = false
		_end_pinch_if_active()
		_hide_pointer_visual()

	_process_left_hand_overlay_toggle(delta)

func _refresh_trackers() -> void:
	if not is_instance_valid(_right_hand_tracker):
		_right_hand_tracker = XRServer.get_tracker(&"/user/hand_tracker/right") as XRHandTracker
	if not is_instance_valid(_left_hand_tracker):
		_left_hand_tracker = XRServer.get_tracker(&"/user/hand_tracker/left") as XRHandTracker

## True only when the tracker reports *real* (camera-based) hand data — not a
## controller emulating a hand. This keeps hand input and controller input
## mutually exclusive without any explicit mode switch.
func _is_optical_hand_tracking(tracker: XRHandTracker) -> bool:
	if not is_instance_valid(tracker):
		return false
	if not tracker.get_has_tracking_data():
		return false

	var source := tracker.get_hand_tracking_source()
	return source == XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED \
		or source == XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN

# ---------------------------------------------------------------------------
# Right-hand pointer
# ---------------------------------------------------------------------------

func _process_right_hand_pointer(delta: float) -> void:
	var ray := _compute_hand_ray(_right_hand_tracker)
	if not ray.get("valid", false):
		_right_pinching = false
		_end_pinch_if_active()
		_hide_pointer_visual()
		return

	var origin: Vector3 = ray["origin"]
	var direction := _filter_direction(ray["direction"], delta)

	var should_press := _is_pinching(_right_hand_tracker, _right_pinching, delta)
	if should_press != _right_pinching:
		print("[HandInput] Pinch %s (%d mm)" % ["DOWN" if should_press else "UP",
			_pinch_distance(_right_hand_tracker) * 1000.0])
		if should_press:
			_press_origin = origin
			_press_dir = direction
			_dragging = false
	# Hold the ray where the pinch started (release frame included) until the
	# hand clearly moves away: that is a drag, not a shaky click.
	if (should_press or _right_pinching) and not _dragging:
		if direction.angle_to(_press_dir) > CLICK_SLOP_RAD:
			_dragging = true
		else:
			origin = _press_origin
			direction = _press_dir
	_right_pinching = should_press

	# 1) Overlay menu takes priority so the bare hands can connect/configure.
	if main_scene and main_scene.has_method("get_ui_hit_from_ray"):
		var ui_hit: Dictionary = main_scene.get_ui_hit_from_ray(origin, direction)
		if ui_hit.get("valid", false):
			_handle_overlay_hit(ui_hit, should_press, origin, direction)
			return

	# Pointer left the overlay — release any held overlay click.
	if _on_overlay:
		if _pinch_active and main_scene and main_scene.has_method("send_ui_pointer_button"):
			main_scene.send_ui_pointer_button(false, MOUSE_BUTTON_LEFT)
		_on_overlay = false
		_pinch_active = false

	# 2) In-VR QWERTY keyboard, when it is open: it floats in front of the
	#    panels, so it takes the ray before they do.
	var kbd_distance: float = main_scene.send_keyboard_pointer(origin, direction, should_press) \
		if main_scene and main_scene.has_method("send_keyboard_pointer") else -1.0
	if kbd_distance >= 0.0:
		_pinch_active = should_press
		_update_pointer_visual(origin, direction, kbd_distance, true)
		return

	# 3) Streamed monitor panels.
	if not main_scene or not main_scene.has_method("get_panel_hit_from_ray"):
		_hide_pointer_visual()
		return

	var hit: Dictionary = main_scene.get_panel_hit_from_ray(origin, direction)
	if not hit.get("valid", false):
		_end_pinch_if_active()
		_update_pointer_visual(origin, direction, MAX_RAY_LENGTH, false)
		return

	var panel = hit.get("panel", null)
	if panel == null or not panel.has_method("uv_to_pixel"):
		_update_pointer_visual(origin, direction, MAX_RAY_LENGTH, false)
		return

	var uv: Vector2 = hit.get("uv", Vector2(0.5, 0.5))
	var pixel: Vector2i = panel.uv_to_pixel(uv)
	if panel.has_method("mark_hovered"):
		panel.mark_hovered()
	var monitor_id: int = hit.get("monitor_id", 0)

	if main_scene.has_method("send_mouse_input"):
		main_scene.send_mouse_input(
			monitor_id,
			pixel.x,
			pixel.y,
			0x01 if should_press else 0,
			0)

	_pinch_active = should_press
	_last_monitor_id = monitor_id
	_last_pixel = pixel
	_update_pointer_visual(origin, direction, hit.get("distance", MAX_RAY_LENGTH), true)

## Drive the in-VR overlay menu with the hand pointer.
func _handle_overlay_hit(ui_hit: Dictionary, should_press: bool, origin: Vector3, direction: Vector3) -> void:
	_on_overlay = true
	var uv: Vector2 = ui_hit.get("uv", Vector2(0.5, 0.5))
	if main_scene.has_method("send_ui_pointer_move"):
		main_scene.send_ui_pointer_move(uv)
	if should_press != _pinch_active:
		if main_scene.has_method("send_ui_pointer_button"):
			main_scene.send_ui_pointer_button(should_press, MOUSE_BUTTON_LEFT)
		_pinch_active = should_press
	_update_pointer_visual(origin, direction, ui_hit.get("distance", 1.5), true)

## Release a held pinch (mouse button up / overlay button up) when tracking is
## lost or the pointer leaves every target.
func _end_pinch_if_active() -> void:
	if not _pinch_active:
		return
	if _on_overlay:
		if main_scene and main_scene.has_method("send_ui_pointer_button"):
			main_scene.send_ui_pointer_button(false, MOUSE_BUTTON_LEFT)
	elif main_scene and main_scene.has_method("send_mouse_input"):
		main_scene.send_mouse_input(_last_monitor_id, _last_pixel.x, _last_pixel.y, 0, 0)
	_pinch_active = false
	_on_overlay = false

# ---------------------------------------------------------------------------
# Left-hand overlay toggle
# ---------------------------------------------------------------------------

func _process_left_hand_overlay_toggle(delta: float) -> void:
	if not _is_optical_hand_tracking(_left_hand_tracker):
		_left_pinching = false
		_left_hold_time = 0.0
		_left_toggle_latched = false
		_left_kbd_latched = false
		return

	_left_pinching = _is_pinching(_left_hand_tracker, _left_pinching, delta)
	if _left_pinching:
		_left_hold_time += delta
		if _left_hold_time >= OVERLAY_TOGGLE_HOLD_S and not _left_toggle_latched:
			if main_scene and main_scene.has_method("toggle_ui_overlay"):
				main_scene.toggle_ui_overlay()
			_left_toggle_latched = true
		# Keep holding and it becomes the keyboard toggle instead — the only way
		# to reach the in-VR keyboard with no controllers in hand. The overlay
		# toggle that already fired at 0.65 s is undone first, so a short pinch
		# means "overlay" and a long one means "keyboard", never both.
		elif _left_hold_time >= KEYBOARD_TOGGLE_HOLD_S and not _left_kbd_latched:
			if main_scene and main_scene.has_method("toggle_ui_overlay"):
				main_scene.toggle_ui_overlay()
			if main_scene and main_scene.has_method("toggle_virtual_keyboard"):
				main_scene.toggle_virtual_keyboard()
			_left_kbd_latched = true
	else:
		_left_hold_time = 0.0
		_left_toggle_latched = false
		_left_kbd_latched = false

# ---------------------------------------------------------------------------
# Ray / pinch math
# ---------------------------------------------------------------------------

func _compute_hand_ray(tracker: XRHandTracker) -> Dictionary:
	var knuckle_joint := XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL
	var head := get_viewport().get_camera_3d()
	if head == null or not _joint_has_valid_position(tracker, knuckle_joint):
		return {"valid": false}

	var knuckle := _joint_world_position(tracker, knuckle_joint)
	var right := head.global_basis.x
	right.y = 0.0
	var shoulder := head.global_position + Vector3.DOWN * SHOULDER_DOWN_M \
		+ right.normalized() * SHOULDER_SIDE_M
	var direction := knuckle - shoulder
	if direction.length() < 0.01:
		return {"valid": false}

	return {
		"valid": true,
		"origin": knuckle,
		"direction": direction.normalized()
	}

## One Euro filter (Casiez et al. 2012) on the ray direction: the cutoff rises
## with speed, so slow aiming is smoothed hard and fast sweeps barely lag.
func _filter_direction(direction: Vector3, delta: float) -> Vector3:
	if _dir_filtered == Vector3.ZERO or delta <= 0.0:
		_dir_filtered = direction
		_dir_rate = Vector3.ZERO
		return direction
	_dir_rate = _dir_rate.lerp((direction - _dir_filtered) / delta, _euro_alpha(1.0, delta))
	var cutoff := FILTER_MIN_CUTOFF + FILTER_BETA * _dir_rate.length()
	_dir_filtered = _dir_filtered.lerp(direction, _euro_alpha(cutoff, delta)).normalized()
	return _dir_filtered

static func _euro_alpha(cutoff: float, delta: float) -> float:
	return 1.0 / (1.0 + 1.0 / (TAU * cutoff * delta))

## Thumb and index tips together, with hysteresis on `was_pinching` and a
## short hold before letting go (see PINCH_RELEASE_HOLD_S).
func _is_pinching(tracker: XRHandTracker, was_pinching: bool, delta: float) -> bool:
	var dist := _pinch_distance(tracker)
	if dist < 0.0:
		return was_pinching  # tips not tracked this frame: keep what we had
	if dist < (PINCH_RELEASE_M if was_pinching else PINCH_PRESS_M):
		_open_s[tracker] = 0.0
		return true
	_open_s[tracker] = _open_s.get(tracker, 0.0) + delta
	return was_pinching and _open_s[tracker] < PINCH_RELEASE_HOLD_S

## Thumb-tip to index-tip distance in metres, or -1 when either is not tracked.
func _pinch_distance(tracker: XRHandTracker) -> float:
	var thumb := XRHandTracker.HAND_JOINT_THUMB_TIP
	var index := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	if not (_joint_has_valid_position(tracker, thumb) and _joint_has_valid_position(tracker, index)):
		return -1.0
	return tracker.get_hand_joint_transform(thumb).origin.distance_to(
		tracker.get_hand_joint_transform(index).origin)

func _joint_has_valid_position(tracker: XRHandTracker, joint: int) -> bool:
	if not is_instance_valid(tracker):
		return false
	var flags: int = tracker.get_hand_joint_flags(joint)
	return (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0

func _joint_world_position(tracker: XRHandTracker, joint: int) -> Vector3:
	var local_joint := tracker.get_hand_joint_transform(joint).origin
	if xr_origin:
		return xr_origin.global_transform * local_joint
	return local_joint

# ---------------------------------------------------------------------------
# Visual pointer (laser beam + cursor dot)
# ---------------------------------------------------------------------------

func _ensure_pointer_visual() -> void:
	if is_instance_valid(_laser):
		return
	if not is_instance_valid(main_scene) or not (main_scene is Node3D):
		return

	_laser = MeshInstance3D.new()
	var beam := BoxMesh.new()
	beam.size = Vector3(0.0024, 0.0024, 1.0)  # 1 m on Z, scaled per-frame to ray length
	_laser.mesh = beam
	_laser.material_override = _make_emissive_material(Color(0.93, 0.92, 0.88, 0.4), true)
	_laser.visible = false
	main_scene.add_child(_laser)

	_cursor = MeshInstance3D.new()
	var dot := SphereMesh.new()
	dot.radius = 0.0065
	dot.height = 0.013
	_cursor.mesh = dot
	_cursor.material_override = _make_emissive_material(Color(0.93, 0.92, 0.88, 1.0), false)
	_cursor.visible = false
	main_scene.add_child(_cursor)

func _make_emissive_material(color: Color, transparent: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b)
	mat.emission_energy_multiplier = 1.5
	if transparent:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat

func _update_pointer_visual(origin: Vector3, direction: Vector3, distance: float, hit: bool) -> void:
	_ensure_pointer_visual()
	if not is_instance_valid(_laser):
		return

	var length: float = clampf(distance, 0.05, MAX_RAY_LENGTH)
	var end := origin + direction * length
	var mid := origin + direction * (length * 0.5)

	var up := Vector3.UP
	if absf(direction.dot(up)) > 0.99:
		up = Vector3.RIGHT
	var oriented := Basis.looking_at(direction, up)  # local -Z follows `direction`
	_laser.transform = Transform3D(oriented.scaled(Vector3(1.0, 1.0, length)), mid)
	_laser.visible = hit  # a beam into empty space is just noise

	_cursor.visible = hit
	if hit:
		_cursor.global_transform = Transform3D(Basis(), end)

func _hide_pointer_visual() -> void:
	if is_instance_valid(_laser):
		_laser.visible = false
	if is_instance_valid(_cursor):
		_cursor.visible = false
	_dir_filtered = Vector3.ZERO
