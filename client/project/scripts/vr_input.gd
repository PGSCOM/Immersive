## VR Input handler for Immersive-2.
## Translates VR controller input (trigger, grip, thumbstick)
## into mouse/keyboard events and sends them to the host.
##
## Right controller:  pointer / click / scroll / panel drag
## Left  controller:  A/X → virtual keyboard toggle
##                    grip + thumbstick Y → scale active screen panel

extends XRController3D

const TRIGGER_PRESS_THRESHOLD := 0.55
const TRIGGER_RELEASE_THRESHOLD := 0.35
const GRIP_PRESS_THRESHOLD := 0.55
const GRIP_RELEASE_THRESHOLD := 0.35

## Reference to the main scene controller.
@onready var main_scene: Node3D = get_node("/root/Main")

## Reference to the virtual keyboard (added in main.tscn).
@onready var virtual_keyboard: Node3D = get_node_or_null("/root/Main/VirtualKeyboard")

## Raycast for pointer interaction.
@onready var raycast: RayCast3D = get_node_or_null("../RightAim/RaycastOrigin/RayCast3D")
@onready var raycast_origin: Node3D = get_node_or_null("../RightAim/RaycastOrigin")

## Active monitor ID for input events.
var active_monitor_id: int = 0

## Button states for detecting press/release.
var _trigger_pressed: bool = false
var _grip_pressed: bool    = false

## Thumbstick current value.
var _thumbstick: Vector2 = Vector2.ZERO

## Last known UV position on the screen.
var _last_uv: Vector2 = Vector2(-1, -1)
## Last panel under pointer.
var _active_panel: MeshInstance3D = null

## Scale-mode: grip is held while thumbstick Y is used to resize.
var _scale_mode: bool = false
var _tracking_state_known: bool = false
var _last_tracking_active: bool = false

func _is_trigger_action(name: String) -> bool:
	return name == "trigger_click" or name == "trigger_value" or name == "trigger" or name == "select" or name == "select_click" or name == "select_value"

func _is_grip_action(name: String) -> bool:
	return name == "grip_click" or name == "grip_value" or name == "grip" or name == "squeeze" or name == "squeeze_click" or name == "squeeze_value"

func _ready() -> void:
	set_process(true)
	# Connect controller input signals
	button_pressed.connect(_on_button_pressed)
	button_released.connect(_on_button_released)
	input_float_changed.connect(_on_input_float_changed)
	input_vector2_changed.connect(_on_input_vector2_changed)
	print("[VRInput] Ready tracker=%s pose=%s" % [String(tracker), String(get("pose"))])

func _process(delta: float) -> void:
	_update_tracking_debug(delta)
	_update_pointer()
	_update_scale(delta)

# ---------------------------------------------------------------------------
# Pointer / ray-cast interaction
# ---------------------------------------------------------------------------

## Update the laser pointer and detect screen intersection.
func _update_pointer() -> void:
	if not main_scene or not main_scene.has_method("get_panel_hit_from_ray"):
		return

	var source_transform := global_transform
	if raycast_origin:
		source_transform = raycast_origin.global_transform
	elif raycast:
		source_transform = raycast.global_transform

	var ray_origin: Vector3 = source_transform.origin
	var ray_direction: Vector3 = (-source_transform.basis.z).normalized()
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

		# Send mouse move (no buttons pressed during hover)
		var buttons: int = 0
		if _trigger_pressed:
			buttons |= 0x01  # Left click
		if _grip_pressed:
			buttons |= 0x02  # Right click

		if main_scene.has_method("send_mouse_input"):
			main_scene.send_mouse_input(
				active_monitor_id,
				pixel.x, pixel.y,
				buttons, 0)

# ---------------------------------------------------------------------------
# Grip + thumbstick → panel scaling (Part 5)
# ---------------------------------------------------------------------------

func _update_scale(delta: float) -> void:
	# Scale mode is active when grip is held
	if not _grip_pressed:
		_scale_mode = false
		return

	if abs(_thumbstick.y) > 0.15:
		_scale_mode = true
		var delta_scale: float = _thumbstick.y * delta * 0.8
		if _active_panel and _active_panel.has_method("scale_panel"):
			_active_panel.scale_panel(delta_scale)

# ---------------------------------------------------------------------------
# Controller button pressed
# ---------------------------------------------------------------------------

func _on_button_pressed(button_name: String) -> void:
	if _is_trigger_action(button_name):
		_set_trigger_state(true)
		return

	if _is_grip_action(button_name):
		_set_grip_state(true)
		return

	match button_name:
		"primary_click":
			# Thumbstick click → middle mouse button
			_send_click(0x04)
		"ax_button":
			# A/X button → toggle virtual keyboard
			if virtual_keyboard and virtual_keyboard.has_method("toggle_visibility"):
				virtual_keyboard.toggle_visibility()
			else:
				# Fallback: send Escape key (original behaviour)
				if main_scene.has_method("send_keyboard_input"):
					main_scene.send_keyboard_input(active_monitor_id, 0x1B, true, 0)
		"by_button":
			# B/Y button → overlay toggle
			if main_scene and main_scene.has_method("toggle_ui_overlay"):
				main_scene.toggle_ui_overlay()

# ---------------------------------------------------------------------------
# Controller button released
# ---------------------------------------------------------------------------

func _on_button_released(button_name: String) -> void:
	if _is_trigger_action(button_name):
		_set_trigger_state(false)
		return

	if _is_grip_action(button_name):
		_set_grip_state(false)
		return

	match button_name:
		"ax_button":
			# A/X was Escape in the old code; now keyboard toggle — no release action needed
			pass
		"by_button":
			pass

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
		if not _scale_mode:
			_send_click(0x02)
	else:
		_scale_mode = false
		_send_release(0x02)

func _query_tracking_active() -> bool:
	var xr_tracker := XRServer.get_tracker(tracker)
	if xr_tracker and xr_tracker.has_method("get_has_tracking_data"):
		return xr_tracker.get_has_tracking_data()
	return false

func _update_tracking_debug(delta: float) -> void:
	if delta < 0.0:
		return
	var tracking_active := _query_tracking_active()

	if _tracking_state_known and _last_tracking_active == tracking_active:
		return

	_tracking_state_known = true
	_last_tracking_active = tracking_active
	print("[VRInput] Tracking %s tracker=%s pose=%s" % ["ACTIVE" if tracking_active else "INACTIVE", String(tracker), String(get("pose"))])

# ---------------------------------------------------------------------------
# Mouse helpers
# ---------------------------------------------------------------------------

## Send a mouse click at the current pointer position.
func _send_click(button_mask: int) -> void:
	if _last_uv.x < 0:
		return
	if not _active_panel or not _active_panel.has_method("uv_to_pixel"):
		return

	var pixel: Vector2i = _active_panel.uv_to_pixel(_last_uv)
	if main_scene.has_method("send_mouse_input"):
		main_scene.send_mouse_input(
			active_monitor_id,
			pixel.x, pixel.y,
			button_mask, 0)

## Send a mouse release at the current pointer position.
func _send_release(button_mask: int) -> void:
	if _last_uv.x < 0:
		return
	if not _active_panel or not _active_panel.has_method("uv_to_pixel"):
		return

	var pixel: Vector2i = _active_panel.uv_to_pixel(_last_uv)
	if main_scene.has_method("send_mouse_input"):
		main_scene.send_mouse_input(
			active_monitor_id,
			pixel.x, pixel.y,
			0, 0)  # No buttons pressed = release

# ---------------------------------------------------------------------------
# Thumbstick input — scroll + scale
# ---------------------------------------------------------------------------

## Handle thumbstick input for scrolling and panel scaling.
func _on_input_vector2_changed(name: String, value: Vector2) -> void:
	if name == "primary" or name == "thumbstick":
		_thumbstick = value

		# If grip is held, thumbstick Y drives panel scaling (handled in _update_scale)
		if _grip_pressed:
			return

		# Otherwise map thumbstick Y to scroll
		if abs(value.y) > 0.1 and _last_uv.x >= 0:
			var scroll: int = int(value.y * 120)
			if _active_panel and _active_panel.has_method("uv_to_pixel"):
				var pixel: Vector2i = _active_panel.uv_to_pixel(_last_uv)
				if main_scene.has_method("send_mouse_input"):
					main_scene.send_mouse_input(
						active_monitor_id,
						pixel.x, pixel.y,
						0, scroll)
