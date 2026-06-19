extends Node

## VR Input handler — plain Node attached as a child of the XRController3D.
## This avoids any interference with XRController3D's internal processing.

const TRIGGER_PRESS_THRESHOLD := 0.55
const TRIGGER_RELEASE_THRESHOLD := 0.35
const GRIP_PRESS_THRESHOLD := 0.55
const GRIP_RELEASE_THRESHOLD := 0.35
const THUMBSTICK_SCROLL_THRESHOLD := 0.1

@onready var controller: XRController3D = get_parent() as XRController3D
@onready var main_scene: Node3D = get_node_or_null("/root/Main")

## Raycast for pointer interaction (siblings under XROrigin3D).
@onready var raycast: RayCast3D = get_node_or_null("/root/Main/XROrigin3D/RightAim/RaycastOrigin/RayCast3D")
@onready var raycast_origin: Node3D = get_node_or_null("/root/Main/XROrigin3D/RightAim/RaycastOrigin")

var active_monitor_id: int = 0
var _trigger_pressed: bool = false
var _grip_pressed: bool = false
var _thumbstick: Vector2 = Vector2.ZERO
var _last_uv: Vector2 = Vector2(-1, -1)
var _active_panel: MeshInstance3D = null
var _scale_mode: bool = false
var _tracking_state_known: bool = false
var _last_tracking_active: bool = false
var _ui_hovered: bool = false
var _ui_dragging: bool = false

func _is_trigger_action(name: String) -> bool:
	return name == "trigger_click" or name == "trigger_value" or name == "trigger" or name == "select" or name == "select_click" or name == "select_value"

func _is_grip_action(name: String) -> bool:
	return name == "grip_click" or name == "grip_value" or name == "grip" or name == "squeeze" or name == "squeeze_click" or name == "squeeze_value"

func _ready() -> void:
	if not controller:
		push_error("[VRInput] Parent is not an XRController3D")
		return
	# Connect controller input signals from the parent controller
	controller.button_pressed.connect(_on_button_pressed)
	controller.button_released.connect(_on_button_released)
	controller.input_float_changed.connect(_on_input_float_changed)
	controller.input_vector2_changed.connect(_on_input_vector2_changed)
	print("[VRInput] Ready tracker=%s pose=%s" % [String(controller.tracker), String(controller.get("pose"))])

func _process(_delta: float) -> void:
	_update_tracking_debug()
	_update_pointer()
	_update_scale(_delta)

func _update_pointer() -> void:
	if not main_scene or not main_scene.has_method("get_panel_hit_from_ray"):
		return

	# When the user is tracking bare hands (no controllers), hand_input.gd owns
	# the pointer. Bail out so an untracked controller's stale pose can't fight
	# the hand cursor over the same monitor.
	if _hands_active():
		return

	var source_transform: Transform3D
	if raycast_origin:
		source_transform = raycast_origin.global_transform
	elif raycast:
		source_transform = raycast.global_transform
	else:
		source_transform = controller.global_transform

	var ray_origin: Vector3 = source_transform.origin
	var ray_direction: Vector3 = (-source_transform.basis.z).normalized()

	if main_scene.has_method("get_ui_hit_from_ray"):
		var ui_hit: Dictionary = main_scene.get_ui_hit_from_ray(ray_origin, ray_direction)
		if ui_hit.get("valid", false):
			_ui_hovered = true
			_active_panel = null
			_last_uv = Vector2(-1, -1)
			if main_scene.has_method("send_ui_pointer_move"):
				main_scene.send_ui_pointer_move(ui_hit.get("uv", Vector2(-1, -1)))
			return

	_ui_hovered = false

	var hit: Dictionary = main_scene.get_panel_hit_from_ray(ray_origin, ray_direction)
	if not hit.get("valid", false):
		_active_panel = null
		_last_uv = Vector2(-1, -1)
		return

	_active_panel = hit.get("panel", null)
	active_monitor_id = hit.get("monitor_id", 0)
	_last_uv = hit.get("uv", Vector2(-1, -1))

	if _active_panel and _active_panel.has_method("uv_to_pixel"):
		var pixel: Vector2i = _active_panel.uv_to_pixel(_last_uv)
		var buttons: int = 0
		if _trigger_pressed:
			buttons |= 0x01  # Left click
		if _grip_pressed:
			buttons |= 0x02  # Right click
		if main_scene.has_method("send_mouse_input"):
			main_scene.send_mouse_input(active_monitor_id, pixel.x, pixel.y, buttons, 0)

func _update_scale(delta: float) -> void:
	if not _grip_pressed:
		_scale_mode = false
		return
	if abs(_thumbstick.y) > 0.15:
		_scale_mode = true
		var delta_scale: float = _thumbstick.y * delta * 0.8
		if _active_panel and _active_panel.has_method("scale_panel"):
			_active_panel.scale_panel(delta_scale)

func _on_button_pressed(button_name: String) -> void:
	if _is_trigger_action(button_name):
		_set_trigger_state(true)
		return
	if _is_grip_action(button_name):
		_set_grip_state(true)
		return
	match button_name:
		"primary_click":
			_send_click(0x04)
		"ax_button":
			if main_scene and main_scene.has_method("toggle_ui_overlay"):
				main_scene.toggle_ui_overlay()
		"by_button":
			if main_scene and main_scene.has_method("toggle_ui_overlay"):
				main_scene.toggle_ui_overlay()

func _on_button_released(button_name: String) -> void:
	if _is_trigger_action(button_name):
		_set_trigger_state(false)
		return
	if _is_grip_action(button_name):
		_set_grip_state(false)
		return

func _on_input_float_changed(name: String, value: float) -> void:
	if _is_trigger_action(name):
		var pressed := _trigger_pressed
		if _trigger_pressed:
			pressed = value >= TRIGGER_RELEASE_THRESHOLD
		else:
			pressed = value >= TRIGGER_PRESS_THRESHOLD
		_set_trigger_state(pressed)
		return
	if _is_grip_action(name):
		var pressed := _grip_pressed
		if _grip_pressed:
			pressed = value >= GRIP_RELEASE_THRESHOLD
		else:
			pressed = value >= GRIP_PRESS_THRESHOLD
		_set_grip_state(pressed)

func _set_trigger_state(pressed: bool) -> void:
	if _trigger_pressed == pressed:
		return
	_trigger_pressed = pressed
	print("[VRInput] Trigger %s" % ["DOWN" if pressed else "UP"])
	if _ui_hovered and main_scene.has_method("send_ui_pointer_button"):
		main_scene.send_ui_pointer_button(pressed, MOUSE_BUTTON_LEFT)
		return
	if pressed:
		_send_click(0x01)
	else:
		_send_release(0x01)

func _set_grip_state(pressed: bool) -> void:
	if _grip_pressed == pressed:
		return
	_grip_pressed = pressed
	print("[VRInput] Grip %s" % ["DOWN" if pressed else "UP"])
	if pressed:
		if _ui_hovered and main_scene and main_scene.has_method("start_ui_drag"):
			# Grab the overlay (it is otherwise static) instead of right-clicking.
			_ui_dragging = true
			main_scene.start_ui_drag(controller)
		elif _active_panel and _active_panel.has_method("start_drag"):
			_active_panel.start_drag(controller)
		elif not _scale_mode:
			_send_click(0x02)
	else:
		if _ui_dragging and main_scene and main_scene.has_method("stop_ui_drag"):
			main_scene.stop_ui_drag()
			_ui_dragging = false
		if _active_panel and _active_panel.has_method("stop_drag"):
			_active_panel.stop_drag()
		_scale_mode = false
		_send_release(0x02)

## True when the right hand is being *optically* tracked (bare-hand mode). Mirror
## of hand_input.gd::_is_optical_hand_tracking — used to yield the pointer to the
## hand-tracking path so the two never push conflicting cursor positions.
func _hands_active() -> bool:
	var hand := XRServer.get_tracker(&"/user/hand_tracker/right") as XRHandTracker
	if hand == null or not hand.get_has_tracking_data():
		return false
	var source := hand.get_hand_tracking_source()
	return source == XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED \
		or source == XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN

func _query_tracking_active() -> bool:
	var xr_tracker := XRServer.get_tracker(controller.tracker)
	if xr_tracker and xr_tracker.has_method("get_has_tracking_data"):
		return xr_tracker.get_has_tracking_data()
	return false

func _update_tracking_debug() -> void:
	var tracking_active := _query_tracking_active()
	if _tracking_state_known and _last_tracking_active == tracking_active:
		return
	_tracking_state_known = true
	_last_tracking_active = tracking_active
	print("[VRInput] Tracking %s tracker=%s pose=%s" % ["ACTIVE" if tracking_active else "INACTIVE", String(controller.tracker), String(controller.get("pose"))])

func _send_click(button_mask: int) -> void:
	if _last_uv.x < 0:
		return
	if not _active_panel or not _active_panel.has_method("uv_to_pixel"):
		return
	var pixel: Vector2i = _active_panel.uv_to_pixel(_last_uv)
	if main_scene.has_method("send_mouse_input"):
		main_scene.send_mouse_input(active_monitor_id, pixel.x, pixel.y, button_mask, 0)

func _send_release(_button_mask: int) -> void:
	if _last_uv.x < 0:
		return
	if not _active_panel or not _active_panel.has_method("uv_to_pixel"):
		return
	var pixel: Vector2i = _active_panel.uv_to_pixel(_last_uv)
	if main_scene.has_method("send_mouse_input"):
		main_scene.send_mouse_input(active_monitor_id, pixel.x, pixel.y, 0, 0)

func _on_input_vector2_changed(name: String, value: Vector2) -> void:
	if name == "primary" or name == "thumbstick":
		_thumbstick = value
		if _grip_pressed:
			return
		if abs(value.y) > THUMBSTICK_SCROLL_THRESHOLD and _ui_hovered and main_scene.has_method("send_ui_pointer_scroll"):
			main_scene.send_ui_pointer_scroll(value.y)
			return
		var scroll_y: int = 0
		var scroll_x: int = 0
		if abs(value.y) > THUMBSTICK_SCROLL_THRESHOLD:
			scroll_y = int(value.y * 120)
		if abs(value.x) > THUMBSTICK_SCROLL_THRESHOLD:
			scroll_x = -int(value.x * 120)
		if (scroll_y != 0 or scroll_x != 0) and _last_uv.x >= 0:
			if _active_panel and _active_panel.has_method("uv_to_pixel"):
				var pixel: Vector2i = _active_panel.uv_to_pixel(_last_uv)
				if main_scene.has_method("send_mouse_input"):
					main_scene.send_mouse_input(active_monitor_id, pixel.x, pixel.y, 0, scroll_y, scroll_x)
