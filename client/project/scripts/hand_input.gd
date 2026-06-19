## Hand-tracking input for Immersive-2 (Pico 4 + SteamVR + Quest).
##
## Lets the user drive the virtual desktop with bare hands — no controllers:
##   • Right hand — index-finger ray pointer; pinch (thumb + index) = left click,
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
##            Android manifest (export_presets.cfg → gradle_build/manifest_additions)
##   • Quest: export preset xr_features/hand_tracking >= 1

extends Node

const PINCH_DOWN_THRESHOLD := 0.72
const PINCH_UP_THRESHOLD := 0.42
const MIN_PINCH_DISTANCE_M := 0.008
const MAX_PINCH_DISTANCE_M := 0.045
const OVERLAY_TOGGLE_HOLD_S := 0.65
const RAY_SMOOTHING := 0.5            ## 0 = raw, →1 = heavier low-pass on the ray
const MAX_RAY_LENGTH := 8.0

@onready var main_scene: Node = get_node_or_null("/root/Main")
@onready var xr_origin: XROrigin3D = get_node_or_null("/root/Main/XROrigin3D")

var _right_hand_tracker: XRHandTracker = null
var _left_hand_tracker: XRHandTracker = null

# Right-hand pointer state.
var _pinch_active: bool = false
var _on_overlay: bool = false
var _last_monitor_id: int = 0
var _last_pixel: Vector2i = Vector2i.ZERO

# Ray low-pass filter (optical hand tracking is jittery).
var _have_smoothed: bool = false
var _smooth_origin: Vector3 = Vector3.ZERO
var _smooth_dir: Vector3 = Vector3.FORWARD

# Left-hand overlay-toggle state.
var _left_hold_time: float = 0.0
var _left_toggle_latched: bool = false

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

	if _is_optical_hand_tracking(_right_hand_tracker):
		_process_right_hand_pointer()
	else:
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

func _process_right_hand_pointer() -> void:
	var ray := _compute_hand_ray(_right_hand_tracker)
	if not ray.get("valid", false):
		_end_pinch_if_active()
		_hide_pointer_visual()
		return

	var origin: Vector3 = ray["origin"]
	var direction: Vector3 = ray["direction"]
	var smoothed := _smooth_ray(origin, direction)
	origin = smoothed[0]
	direction = smoothed[1]

	var pinch_strength := _compute_pinch_strength(_right_hand_tracker)
	var threshold := PINCH_UP_THRESHOLD if _pinch_active else PINCH_DOWN_THRESHOLD
	var should_press := pinch_strength >= threshold

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

	# 2) Streamed monitor panels.
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
		_left_hold_time = 0.0
		_left_toggle_latched = false
		return

	var pinch_strength := _compute_pinch_strength(_left_hand_tracker)
	if pinch_strength >= PINCH_DOWN_THRESHOLD:
		_left_hold_time += delta
		if _left_hold_time >= OVERLAY_TOGGLE_HOLD_S and not _left_toggle_latched:
			if main_scene and main_scene.has_method("toggle_ui_overlay"):
				main_scene.toggle_ui_overlay()
			_left_toggle_latched = true
	elif pinch_strength <= PINCH_UP_THRESHOLD:
		_left_hold_time = 0.0
		_left_toggle_latched = false

# ---------------------------------------------------------------------------
# Ray / pinch math
# ---------------------------------------------------------------------------

func _compute_hand_ray(tracker: XRHandTracker) -> Dictionary:
	if not _joint_has_valid_position(tracker, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP):
		return {"valid": false}

	var tip := _joint_world_position(tracker, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)
	var base_joint := XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL
	var base := _joint_world_position(tracker, base_joint)

	var direction := tip - base
	if direction.length() < 0.001 and _joint_has_valid_position(tracker, XRHandTracker.HAND_JOINT_WRIST):
		var wrist := _joint_world_position(tracker, XRHandTracker.HAND_JOINT_WRIST)
		direction = tip - wrist

	if direction.length() < 0.001:
		return {"valid": false}

	return {
		"valid": true,
		"origin": tip,
		"direction": direction.normalized()
	}

## Exponential low-pass on origin (lerp) and direction (slerp) to tame the
## jitter inherent to camera-based hand tracking. Returns [origin, direction].
func _smooth_ray(origin: Vector3, direction: Vector3) -> Array:
	if _have_smoothed:
		origin = _smooth_origin.lerp(origin, 1.0 - RAY_SMOOTHING)
		direction = _smooth_dir.slerp(direction, 1.0 - RAY_SMOOTHING).normalized()
	_smooth_origin = origin
	_smooth_dir = direction
	_have_smoothed = true
	return [origin, direction]

func _compute_pinch_strength(tracker: XRHandTracker) -> float:
	if not _joint_has_valid_position(tracker, XRHandTracker.HAND_JOINT_THUMB_TIP):
		return 0.0
	if not _joint_has_valid_position(tracker, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP):
		return 0.0

	var thumb_tip := _joint_world_position(tracker, XRHandTracker.HAND_JOINT_THUMB_TIP)
	var index_tip := _joint_world_position(tracker, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)
	var dist := thumb_tip.distance_to(index_tip)

	var normalized: float = 1.0 - clampf(
		(dist - MIN_PINCH_DISTANCE_M) / (MAX_PINCH_DISTANCE_M - MIN_PINCH_DISTANCE_M),
		0.0,
		1.0)
	return normalized

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
	beam.size = Vector3(0.004, 0.004, 1.0)  # 1 m on Z, scaled per-frame to ray length
	_laser.mesh = beam
	_laser.material_override = _make_emissive_material(Color(0.25, 0.8, 1.0, 0.75), true)
	_laser.visible = false
	main_scene.add_child(_laser)

	_cursor = MeshInstance3D.new()
	var dot := SphereMesh.new()
	dot.radius = 0.012
	dot.height = 0.024
	_cursor.mesh = dot
	_cursor.material_override = _make_emissive_material(Color(0.45, 0.9, 1.0, 1.0), false)
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
	_laser.visible = true

	_cursor.visible = hit
	if hit:
		_cursor.global_transform = Transform3D(Basis(), end)

func _hide_pointer_visual() -> void:
	if is_instance_valid(_laser):
		_laser.visible = false
	if is_instance_valid(_cursor):
		_cursor.visible = false
	_have_smoothed = false
