## VR Input handler for Immersive-2.
## Translates VR controller input (trigger, grip, thumbstick)
## into mouse/keyboard events and sends them to the host.
##
## Right controller:  pointer / click / scroll / panel drag
## Left  controller:  A/X → virtual keyboard toggle
##                    grip + thumbstick Y → scale active screen panel

extends XRController3D

## Reference to the main scene controller.
@onready var main_scene: Node3D = get_node("/root/Main")

## Reference to the screen panel.
@onready var screen_panel: MeshInstance3D = get_node("/root/Main/ScreenPanel")

## Reference to the virtual keyboard (added in main.tscn).
@onready var virtual_keyboard: Node3D = get_node_or_null("/root/Main/VirtualKeyboard")

## Raycast for pointer interaction.
@onready var raycast: RayCast3D = $RaycastOrigin/RayCast3D

## Active monitor ID for input events.
var active_monitor_id: int = 0

## Button states for detecting press/release.
var _trigger_pressed: bool = false
var _grip_pressed: bool    = false

## Thumbstick current value.
var _thumbstick: Vector2 = Vector2.ZERO

## Last known UV position on the screen.
var _last_uv: Vector2 = Vector2(-1, -1)

## Scale-mode: grip is held while thumbstick Y is used to resize.
var _scale_mode: bool = false

func _ready() -> void:
	# Connect controller input signals
	button_pressed.connect(_on_button_pressed)
	button_released.connect(_on_button_released)

func _process(delta: float) -> void:
	_update_pointer()
	_update_scale(delta)

# ---------------------------------------------------------------------------
# Pointer / ray-cast interaction
# ---------------------------------------------------------------------------

## Update the laser pointer and detect screen intersection.
func _update_pointer() -> void:
	if not screen_panel or not raycast:
		return

	raycast.force_raycast_update()

	if raycast.is_colliding():
		var collision_point: Vector3 = raycast.get_collision_point()

		# Convert to screen UV coordinates
		if screen_panel.has_method("world_to_screen_uv"):
			var uv: Vector2 = screen_panel.world_to_screen_uv(collision_point)

			if uv.x >= 0 and uv.y >= 0:
				_last_uv = uv

				# Convert to pixel coordinates
				if screen_panel.has_method("uv_to_pixel"):
					var pixel: Vector2i = screen_panel.uv_to_pixel(uv)

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
		if screen_panel and screen_panel.has_method("scale_panel"):
			screen_panel.scale_panel(delta_scale)

# ---------------------------------------------------------------------------
# Controller button pressed
# ---------------------------------------------------------------------------

func _on_button_pressed(button_name: String) -> void:
	match button_name:
		"trigger_click":
			_trigger_pressed = true
			_send_click(0x01)  # Left button
		"grip_click":
			_grip_pressed = true
			if not _scale_mode:
				_send_click(0x02)  # Right button
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
			# B/Y button → Enter key
			if main_scene.has_method("send_keyboard_input"):
				main_scene.send_keyboard_input(active_monitor_id, 0x0D, true, 0)

# ---------------------------------------------------------------------------
# Controller button released
# ---------------------------------------------------------------------------

func _on_button_released(button_name: String) -> void:
	match button_name:
		"trigger_click":
			_trigger_pressed = false
			_send_release(0x01)
		"grip_click":
			_grip_pressed = false
			_scale_mode = false
			_send_release(0x02)
		"ax_button":
			# A/X was Escape in the old code; now keyboard toggle — no release action needed
			pass
		"by_button":
			if main_scene.has_method("send_keyboard_input"):
				main_scene.send_keyboard_input(active_monitor_id, 0x0D, false, 0)

# ---------------------------------------------------------------------------
# Mouse helpers
# ---------------------------------------------------------------------------

## Send a mouse click at the current pointer position.
func _send_click(button_mask: int) -> void:
	if _last_uv.x < 0:
		return
	if not screen_panel or not screen_panel.has_method("uv_to_pixel"):
		return

	var pixel: Vector2i = screen_panel.uv_to_pixel(_last_uv)
	if main_scene.has_method("send_mouse_input"):
		main_scene.send_mouse_input(
			active_monitor_id,
			pixel.x, pixel.y,
			button_mask, 0)

## Send a mouse release at the current pointer position.
func _send_release(button_mask: int) -> void:
	if _last_uv.x < 0:
		return
	if not screen_panel or not screen_panel.has_method("uv_to_pixel"):
		return

	var pixel: Vector2i = screen_panel.uv_to_pixel(_last_uv)
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
	if name == "primary":
		_thumbstick = value

		# If grip is held, thumbstick Y drives panel scaling (handled in _update_scale)
		if _grip_pressed:
			return

		# Otherwise map thumbstick Y to scroll
		if abs(value.y) > 0.1 and _last_uv.x >= 0:
			var scroll: int = int(value.y * 120)
			if screen_panel.has_method("uv_to_pixel"):
				var pixel: Vector2i = screen_panel.uv_to_pixel(_last_uv)
				if main_scene.has_method("send_mouse_input"):
					main_scene.send_mouse_input(
						active_monitor_id,
						pixel.x, pixel.y,
						0, scroll)
