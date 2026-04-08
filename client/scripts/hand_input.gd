## Hand-tracking input path for Immersive-2.
##
## Provides pointer + click interaction without physical controllers by using
## XR hand tracking data (thumb/index pinch gestures).

extends Node

const PINCH_DOWN_THRESHOLD := 0.72
const PINCH_UP_THRESHOLD := 0.42
const MIN_PINCH_DISTANCE_M := 0.008
const MAX_PINCH_DISTANCE_M := 0.045
const OVERLAY_TOGGLE_HOLD_S := 0.65

@onready var main_scene: Node = get_node("/root/Main")
@onready var xr_origin: XROrigin3D = get_node("/root/Main/XROrigin3D")

var _right_hand_tracker: XRHandTracker = null
var _left_hand_tracker: XRHandTracker = null

var _pinch_active: bool = false
var _last_monitor_id: int = 0
var _last_pixel: Vector2i = Vector2i.ZERO

var _left_hold_time: float = 0.0
var _left_toggle_latched: bool = false

func _ready() -> void:
	set_process(true)

func _process(delta: float) -> void:
	_refresh_trackers()

	if _is_optical_hand_tracking(_right_hand_tracker):
		_process_right_hand_pointer()
	elif _pinch_active:
		_send_release()
		_pinch_active = false

	_process_left_hand_overlay_toggle(delta)

func _refresh_trackers() -> void:
	if not is_instance_valid(_right_hand_tracker):
		_right_hand_tracker = XRServer.get_tracker(&"/user/hand_tracker/right") as XRHandTracker
	if not is_instance_valid(_left_hand_tracker):
		_left_hand_tracker = XRServer.get_tracker(&"/user/hand_tracker/left") as XRHandTracker

func _is_optical_hand_tracking(tracker: XRHandTracker) -> bool:
	if not is_instance_valid(tracker):
		return false
	if not tracker.get_has_tracking_data():
		return false

	var source := tracker.get_hand_tracking_source()
	return source == XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED \
		or source == XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN

func _process_right_hand_pointer() -> void:
	var ray := _compute_hand_ray(_right_hand_tracker)
	if not ray.get("valid", false):
		if _pinch_active:
			_send_release()
			_pinch_active = false
		return

	if not main_scene or not main_scene.has_method("get_panel_hit_from_ray"):
		return

	var hit: Dictionary = main_scene.get_panel_hit_from_ray(ray["origin"], ray["direction"])
	if not hit.get("valid", false):
		if _pinch_active:
			_send_release()
			_pinch_active = false
		return

	var panel = hit.get("panel", null)
	if panel == null or not panel.has_method("uv_to_pixel"):
		return

	var uv: Vector2 = hit.get("uv", Vector2(0.5, 0.5))
	var pixel: Vector2i = panel.uv_to_pixel(uv)
	var monitor_id: int = hit.get("monitor_id", 0)

	var pinch_strength := _compute_pinch_strength(_right_hand_tracker)
	var threshold := PINCH_UP_THRESHOLD if _pinch_active else PINCH_DOWN_THRESHOLD
	var should_press := pinch_strength >= threshold

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

func _send_release() -> void:
	if main_scene and main_scene.has_method("send_mouse_input"):
		main_scene.send_mouse_input(_last_monitor_id, _last_pixel.x, _last_pixel.y, 0, 0)

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

func _compute_pinch_strength(tracker: XRHandTracker) -> float:
	if not _joint_has_valid_position(tracker, XRHandTracker.HAND_JOINT_THUMB_TIP):
		return 0.0
	if not _joint_has_valid_position(tracker, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP):
		return 0.0

	var thumb_tip := _joint_world_position(tracker, XRHandTracker.HAND_JOINT_THUMB_TIP)
	var index_tip := _joint_world_position(tracker, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)
	var dist := thumb_tip.distance_to(index_tip)

	var normalized := 1.0 - clamp(
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
