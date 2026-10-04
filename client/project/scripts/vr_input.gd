extends Node

## Controller input. One instance sits under each XRController3D (left and
## right); both work the same way and the one whose trigger was pressed last
## drives the pointer (the other hides its laser), like the system UI.
##
##   Trigger          click (desktop, menu, keyboard), draw on the whiteboard;
##                    on the bar under a screen, the menu, the keyboard or the
##                    whiteboard: hold to move it
##   Grip, tap        right click on a screen
##   Grip, hold       move the screen / menu / keyboard / whiteboard under the pointer;
##                    while moving, stick up/down (or reaching out / pulling
##                    the hand in) pushes it away / pulls it in and stick
##                    left/right resizes a screen
##   Stick            scroll the screen or the menu under the pointer
##   Stick click      middle click
##   A / X            show / hide the keyboard
##   B / Y            show / hide the menu
##
## Builds its own laser, cursor dot and controller model (the runtime's model
## when it offers one through OpenXRRenderModelManager, a plain one otherwise).
##
## A controller in use always has the pointer, whatever the runtime says about
## hands (the Pico reports hand joints even while the controllers are held).
## One left still for IDLE_HIDE_S (put down) or without a tracked pose gives
## it up and hides; once every controller has, bare hands get the pointer
## (hand_input.gd asks any_in_use()). Moving it or pressing a trigger, grip or
## button takes it back at once.

const TRIGGER_PRESS_THRESHOLD := 0.55
const TRIGGER_RELEASE_THRESHOLD := 0.35
const GRIP_PRESS_THRESHOLD := 0.55
const GRIP_RELEASE_THRESHOLD := 0.35
## A grip held this long on a screen grabs it; a shorter squeeze right-clicks.
const GRIP_HOLD_TO_DRAG_S := 0.28
const STICK_DEADZONE := 0.15
## Wheel units per second at full deflection (120 = one notch); the response
## is quadratic so a light push scrolls slowly.
const SCROLL_SPEED := 1500.0
const PUSH_PULL_SPEED := 1.6   ## metres per second at full deflection
const RESIZE_SPEED := 0.9      ## metres of width per second
## A controller left still this long (put down on the desk) disappears, laser
## included, and stops driving the pointer until it moves again.
## Still in use, a move counts only with some turn too (IDLE_MIN_TURN_RAD,
## for the frozen orientation below): otherwise a controller the Pico lost
## just after it was put down would wander on and never let the hands point.
const IDLE_HIDE_S := 3.0
const IDLE_MOVE_M := 0.01
const IDLE_MIN_TURN_RAD := 0.003  # 0.17°: any hand, never a frozen pose
const IDLE_TURN_RAD := 0.05
## A put-down controller wakes when picked up: moved WAKE_MOVE_M or turned
## WAKE_TURN_RAD away from where it lies, measured against its pose smoothed
## over WAKE_SMOOTH_S, so a slow drift of the tracking never wakes it. One
## frame jumping more than JUMP_M / JUMP_TURN_RAD is the tracking finding it
## again (it lies on the desk), not a hand: it moves the rest pose instead.
## Nor is a move without the least turn: a hand always tilts what it lifts,
## while the Pico (in passthrough) freezes the orientation of a controller its
## cameras lost and lets the position wander, 3-4 cm at a time. Its
## tracking coming back is no pick-up either (the cameras found it on the
## desk); a hand that took it meanwhile moves it, or presses something.
const WAKE_MOVE_M := 0.03
const WAKE_MIN_TURN_RAD := 0.017  # 1°
const WAKE_TURN_RAD := 0.35
const WAKE_SMOOTH_S := 0.3
const JUMP_M := 0.04
const JUMP_TURN_RAD := 0.26
## Short ray shown when the pointer is on nothing.
const IDLE_RAY_M := 0.35
const MAX_RAY_M := 8.0
## Where the ray starts relative to the aim pose: tilted 40° down, as tuned on
## the Pico 4 whose aim pose points above where the controller looks. The tilt
## follows main.gd's ray_angle_deg (the menu's "Ray angle") live; once the
## grip pose places the model, the ray starts at its tip (MODEL_TIP) instead.
const RAY_ORIGIN := Transform3D(
	Basis(Vector3(1, 0, 0), Vector3(0, 0.76604444, -0.6427876), Vector3(0, 0.6427876, 0.76604444)),
	Vector3(0, 0, 0.1))
const POINTER_COLOR := Color(0.93, 0.92, 0.88)
## The controller model's frame in the grip pose (the controller as the
## runtime tracks it in the hand): turned 10° down about the handle's middle,
## as tuned on the Pico 4, so its front end and ring land on the real one's head.
const MODEL_IN_GRIP := Transform3D(
	Basis(Vector3(1, 0, 0), Vector3(0, 0.98480775, -0.17364818), Vector3(0, 0.17364818, 0.98480775)),
	Vector3(0, -0.0034, -0.0113))
## The front end of the model's grip, where the ray starts once the grip pose
## places the model.
const MODEL_TIP := Vector3(0, -0.01, -0.03)

enum Target { NONE, OVERLAY, KEYBOARD, BOARD, PANEL, BAR }

## The instance whose controller drives the pointer.
static var active: Node = null
## Every instance, for any_in_use().
static var _all: Array[Node] = []

@onready var controller: XRController3D = get_parent() as XRController3D
@onready var main_scene: Node = get_node_or_null("/root/Main")

var raycast_origin: Node3D
var _laser: MeshInstance3D
var _dot: MeshInstance3D
var _visual: Node3D
var _render_models: Node3D

var _trigger_pressed := false
var _grip_pressed := false
var _stick := Vector2.ZERO

var _target: Target = Target.NONE
var _panel: Node3D = null
var _uv := Vector2(-1, -1)
var _hit_distance := MAX_RAY_M
## What the grab bar under the pointer moves (Target.BAR).
var _bar_target: Node = null
var _ray_angle := 40.0
## Desktop mouse buttons this controller holds down, and where it last sent
## them (so a release always reaches the host, even off the panel).
var _buttons := 0
var _last_monitor := -1
var _last_pixel := Vector2i.ZERO
var _overlay_pressed := false

var _grip_pending_panel: Node3D = null
var _grip_held_s := 0.0
var _dragging: Node = null   ## panel, overlay or keyboard being moved
var _drag_by_trigger := false   ## grabbed by its bar: the trigger lets go
var _scroll_acc := Vector2.ZERO
var _ui_scroll_s := 0.0

var _idle_ref := Transform3D()
var _idle_s := 0.0
var _rest := Transform3D()      ## where a put-down controller lies (smoothed)
var _last_pose := Transform3D()
var _was_tracked := false
var _jump_logged_ms := -10000
## What this controller does right now, for the log ("pointer", "put down", ...).
var _role := ""
## Strength of the last vibration asked for (tests read it).
var last_buzz := 0.0

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

func _ready() -> void:
	set_process(false)
	if not controller:
		push_error("[VRInput] Parent is not an XRController3D")
		return
	# The controller is still adding its children: build ours next frame.
	_setup.call_deferred()

func _setup() -> void:
	_build_pointer()
	_build_visual()
	set_process(true)
	controller.button_pressed.connect(_on_button_pressed)
	controller.button_released.connect(_on_button_released)
	controller.input_float_changed.connect(_on_input_float_changed)
	controller.input_vector2_changed.connect(_on_input_vector2_changed)
	if active == null and _is_right():
		active = self
	_all.append(self)
	print("[VRInput] Ready tracker=%s" % String(controller.tracker))

func _exit_tree() -> void:
	_all.erase(self)
	if active == self:
		active = null

## True while some controller is in use: bare hands keep off the pointer.
static func any_in_use() -> bool:
	return _all.any(func(v: Node) -> bool: return v.in_use())

## Tracked and not put down (a press resets the idle time, like moving it).
func in_use() -> bool:
	return controller != null and controller.get_has_tracking_data() and _idle_s < IDLE_HIDE_S

func _is_right() -> bool:
	return String(controller.tracker).contains("right")

func _build_pointer() -> void:
	raycast_origin = controller.get_node_or_null("RaycastOrigin")
	if raycast_origin == null:
		raycast_origin = Node3D.new()
		raycast_origin.name = "RaycastOrigin"
		raycast_origin.transform = RAY_ORIGIN
		controller.add_child(raycast_origin)

	# A thin beam fading out towards its tip, 1 m long, scaled to the hit.
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_laser = MeshInstance3D.new()
	_laser.mesh = _beam_mesh()
	_laser.material_override = mat
	_laser.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	raycast_origin.add_child(_laser)

	var dot_mat := StandardMaterial3D.new()
	dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot_mat.albedo_color = POINTER_COLOR
	var sphere := SphereMesh.new()
	sphere.radius = 0.0065
	sphere.height = 0.013
	sphere.radial_segments = 12
	sphere.rings = 6
	_dot = MeshInstance3D.new()
	_dot.mesh = sphere
	_dot.material_override = dot_mat
	_dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	raycast_origin.add_child(_dot)

## Square beam along -Z from 0 to 1 m, opaque-ish at the hand, faint at the tip.
func _beam_mesh() -> ArrayMesh:
	var w := 0.0012
	var corners := [Vector2(-w, -w), Vector2(w, -w), Vector2(w, w), Vector2(-w, w)]
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	for z in [0.0, -1.0]:
		var a := 0.55 if z == 0.0 else 0.08
		for c in corners:
			verts.append(Vector3(c.x, c.y, z))
			colors.append(Color(POINTER_COLOR, a))
	var idx := PackedInt32Array()
	for i in 4:
		var j := (i + 1) % 4
		idx.append_array([i, j, i + 4, j, j + 4, i + 4])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m

## The runtime's own controller model when it provides one; otherwise a
## simple dark grip with a light ring, hidden once a real model shows up.
## _process() keeps it on the grip pose (MODEL_IN_GRIP); it hangs under the
## aim-posed controller only to show and hide with it.
func _build_visual() -> void:
	_visual = controller.get_node_or_null("ControllerVisual")
	if _visual == null:
		_visual = Node3D.new()
		_visual.name = "ControllerVisual"
		_visual.transform = RAY_ORIGIN
		var body_mat := StandardMaterial3D.new()
		body_mat.albedo_color = Color(0.13, 0.13, 0.12)
		body_mat.roughness = 0.55
		var body := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = 0.019
		cap.height = 0.12
		body.mesh = cap
		body.material_override = body_mat
		body.rotation = Vector3(PI / 2.0, 0.0, 0.0)
		body.position = Vector3(0, -0.01, 0.03)
		_visual.add_child(body)
		var ring_mat := StandardMaterial3D.new()
		ring_mat.albedo_color = Color(0.78, 0.76, 0.70)
		ring_mat.roughness = 0.4
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.034
		torus.outer_radius = 0.041
		ring.mesh = torus
		ring.material_override = ring_mat
		ring.rotation = Vector3(deg_to_rad(-20.0), 0.0, 0.0)
		ring.position = Vector3(0, 0.012, -0.035)
		_visual.add_child(ring)
		controller.add_child(_visual)
	var xr := XRServer.find_interface("OpenXR")
	if ClassDB.class_exists("OpenXRRenderModelManager") and xr and xr.is_initialized():
		_render_models = ClassDB.instantiate("OpenXRRenderModelManager")
		_render_models.name = "RenderModels"
		_render_models.set("tracker", 3 if _is_right() else 2)  # RIGHT_HAND / LEFT_HAND
		_render_models.set("make_local_to_pose", "aim")
		controller.add_child(_render_models)

# ---------------------------------------------------------------------------
# Per frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not controller:
		return
	_update_idle(delta)
	var shown := in_use()
	var has_model := is_instance_valid(_render_models) and _render_models.get_child_count() > 0
	_visual.visible = shown and not has_model
	var tracker := XRServer.get_tracker(controller.tracker) as XRPositionalTracker
	var aim: XRPose = tracker.get_pose(&"aim") if tracker else null
	var grip: XRPose = tracker.get_pose(&"grip") if tracker else null
	if aim and grip and grip.has_tracking_data:
		_visual.transform = aim.get_adjusted_transform().affine_inverse() * grip.get_adjusted_transform() * MODEL_IN_GRIP
		raycast_origin.position = _visual.transform * MODEL_TIP
	if is_instance_valid(_render_models):
		_render_models.visible = shown

	# Put down or untracked: let go of everything and leave the pointer to the
	# other controller, or to bare hands once both are down.
	if not shown:
		_release_all()
		raycast_origin.visible = false
		if active == self:
			active = null
		_set_role("put down" if controller.get_has_tracking_data() else "untracked")
		return
	if active == null:
		active = self
	if active != self:
		raycast_origin.visible = false
		_set_role("standby")
		return
	_set_role("pointer")
	raycast_origin.visible = true
	_apply_ray_angle()

	if is_instance_valid(_dragging):
		_update_drag(delta)
	else:
		_update_pointer()
		_update_grip_hold(delta)
		_update_scroll(delta)
	_update_beam()

func _apply_ray_angle() -> void:
	var angle = main_scene.get("ray_angle_deg") if main_scene else null
	if angle == null or is_equal_approx(angle, _ray_angle):
		return
	_ray_angle = angle
	raycast_origin.basis = Basis(Vector3.RIGHT, deg_to_rad(-_ray_angle))

func _ray() -> Array:
	return [raycast_origin.global_position, (-raycast_origin.global_basis.z).normalized()]

func _update_pointer() -> void:
	if not main_scene:
		return
	var ray := _ray()
	var origin: Vector3 = ray[0]
	var dir: Vector3 = ray[1]

	var hit: Dictionary = main_scene.pick(origin, dir) if main_scene.has_method("pick") else {}
	var kind: String = hit.get("kind", "")
	if kind != "keyboard" and main_scene.has_method("leave_keyboard"):
		main_scene.leave_keyboard()
	if kind != "whiteboard" and main_scene.has_method("leave_whiteboard"):
		main_scene.leave_whiteboard()
	_hit_distance = hit.get("distance", MAX_RAY_M)
	match kind:
		"overlay":
			_set_target(Target.OVERLAY, null)
			main_scene.send_ui_pointer_move(hit.get("uv", Vector2(0.5, 0.5)))
			return
		"keyboard":
			_set_target(Target.KEYBOARD, null)
			main_scene.send_keyboard_pointer(origin, dir, _trigger_pressed)
			return
		"whiteboard":
			_set_target(Target.BOARD, null)
			main_scene.send_whiteboard_pointer(origin, dir, _trigger_pressed)
			return
		"bar":
			_set_target(Target.BAR, null)
			_bar_target = hit.get("target")
			if is_instance_valid(hit.get("bar")):
				hit.bar.mark_hovered()
			return
		"panel":
			pass
		_:
			_set_target(Target.NONE, null)
			return

	var panel: Node3D = hit.get("panel")
	_set_target(Target.PANEL, panel)
	_uv = hit.get("uv", Vector2(0.5, 0.5))
	if panel.has_method("mark_hovered"):
		panel.mark_hovered()
	_send_mouse(hit.get("monitor_id", 0), panel.uv_to_pixel(_uv), 0, 0)

## Leaving the overlay mid-press still lets Godot see the release.
func _set_target(t: Target, panel: Node3D) -> void:
	if t != Target.OVERLAY and _overlay_pressed:
		main_scene.send_ui_pointer_button(false, MOUSE_BUTTON_LEFT)
		_overlay_pressed = false
	if t != Target.PANEL:
		_uv = Vector2(-1, -1)
	if t != Target.BAR:
		_bar_target = null
	_target = t
	_panel = panel

func _update_beam() -> void:
	var on_something := _target != Target.NONE or is_instance_valid(_dragging)
	var length := _hit_distance if on_something else IDLE_RAY_M
	_laser.scale = Vector3(1, 1, maxf(length - 0.008, 0.01))
	_dot.visible = on_something
	_dot.position = Vector3(0, 0, -length)
	_dot.scale = Vector3.ONE * (0.7 if (_trigger_pressed or is_instance_valid(_dragging)) else 1.0)

## Mouse event to the host. `extra` adds momentary buttons (a right click).
func _send_mouse(monitor_id: int, pixel: Vector2i, scroll: int, scroll_h: int, extra: int = 0) -> void:
	_last_monitor = monitor_id
	_last_pixel = pixel
	if main_scene and main_scene.has_method("send_mouse_input"):
		main_scene.send_mouse_input(monitor_id, pixel.x, pixel.y, _buttons | extra, scroll, scroll_h)

## A short tick in the hand: clicks, grabs. The action is "haptic" in
## openxr_action_map.tres; the menu's Vibration switch turns it off.
func _buzz(amplitude: float, seconds: float) -> void:
	if main_scene and not main_scene.get("haptics_enabled"):
		return
	last_buzz = amplitude
	controller.trigger_haptic_pulse("haptic", 0.0, amplitude, seconds, 0.0)

## Let go of every desktop button and menu press this controller holds.
func _release_all() -> void:
	if _buttons != 0 and _last_monitor >= 0:
		_buttons = 0
		_send_mouse(_last_monitor, _last_pixel, 0, 0)
	_buttons = 0
	if _overlay_pressed and main_scene:
		main_scene.send_ui_pointer_button(false, MOUSE_BUTTON_LEFT)
		_overlay_pressed = false
	_stop_drag()
	_grip_pending_panel = null
	_target = Target.NONE

# ---------------------------------------------------------------------------
# Grip: short squeeze = right click, hold = grab
# ---------------------------------------------------------------------------

func _update_grip_hold(delta: float) -> void:
	if not is_instance_valid(_grip_pending_panel):
		_grip_pending_panel = null
		return
	_grip_held_s += delta
	if _grip_held_s >= GRIP_HOLD_TO_DRAG_S or _stick.length() > STICK_DEADZONE:
		_start_drag(_grip_pending_panel)
		_grip_pending_panel = null

func _start_drag(thing: Node, by_trigger := false) -> void:
	if not LaserDrag.grab(thing, raycast_origin, _hit_distance, main_scene):
		return
	_dragging = thing
	_drag_by_trigger = by_trigger
	_buzz(0.55, 0.04)

func _stop_drag() -> void:
	LaserDrag.drop(_dragging, main_scene)
	_dragging = null
	_drag_by_trigger = false

func _update_drag(delta: float) -> void:
	if absf(_stick.y) > STICK_DEADZONE and _dragging.has_method("push_pull"):
		_dragging.push_pull(_stick.y * absf(_stick.y) * PUSH_PULL_SPEED * delta)
	if absf(_stick.x) > STICK_DEADZONE and _dragging.has_method("scale_panel"):
		_dragging.scale_panel(_stick.x * absf(_stick.x) * RESIZE_SPEED * delta)
	if _dragging.has_method("get_drag_distance"):
		_hit_distance = _dragging.get_drag_distance()

# ---------------------------------------------------------------------------
# Stick scrolling
# ---------------------------------------------------------------------------

func _update_scroll(delta: float) -> void:
	var s := Vector2(
		_stick.x if absf(_stick.x) > STICK_DEADZONE else 0.0,
		_stick.y if absf(_stick.y) > STICK_DEADZONE else 0.0)
	if s == Vector2.ZERO or _grip_pressed:
		_scroll_acc = Vector2.ZERO
		_ui_scroll_s = 0.0
		return
	if _target == Target.OVERLAY:
		# One wheel step every ~0.1 s, faster when pushed further.
		_ui_scroll_s -= delta
		if _ui_scroll_s <= 0.0 and s.y != 0.0:
			main_scene.send_ui_pointer_scroll(signf(s.y))
			_ui_scroll_s = lerpf(0.16, 0.05, absf(s.y))
		return
	if _target != Target.PANEL or not is_instance_valid(_panel):
		_scroll_acc = Vector2.ZERO
		return
	_scroll_acc += Vector2(-s.x * absf(s.x), s.y * absf(s.y)) * SCROLL_SPEED * delta
	var step := Vector2i(int(_scroll_acc.x), int(_scroll_acc.y))
	if step != Vector2i.ZERO:
		_scroll_acc -= Vector2(step)
		_send_mouse(_last_monitor, _panel.uv_to_pixel(_uv), step.y, step.x)

# ---------------------------------------------------------------------------
# Buttons
# ---------------------------------------------------------------------------

func _is_trigger_action(name: String) -> bool:
	return name in ["trigger_click", "trigger_value", "trigger", "select", "select_click", "select_value"]

func _is_grip_action(name: String) -> bool:
	return name in ["grip_click", "grip_value", "grip", "squeeze", "squeeze_click", "squeeze_value"]

func _on_button_pressed(button_name: String) -> void:
	_idle_s = 0.0  # a press wakes a still controller
	if _is_trigger_action(button_name):
		_set_trigger_state(true)
	elif _is_grip_action(button_name):
		_set_grip_state(true)
	elif button_name == "primary_click":
		if _target == Target.PANEL and _last_monitor >= 0:
			_send_mouse(_last_monitor, _last_pixel, 0, 0, 0x04)
			_send_mouse(_last_monitor, _last_pixel, 0, 0)
	elif button_name == "ax_button":
		if main_scene and main_scene.has_method("toggle_virtual_keyboard"):
			main_scene.toggle_virtual_keyboard()
	elif button_name == "by_button":
		if main_scene and main_scene.has_method("toggle_ui_overlay"):
			main_scene.toggle_ui_overlay()

func _on_button_released(button_name: String) -> void:
	if _is_trigger_action(button_name):
		_set_trigger_state(false)
	elif _is_grip_action(button_name):
		_set_grip_state(false)

func _on_input_float_changed(name: String, value: float) -> void:
	if _is_trigger_action(name):
		_set_trigger_state(value >= (TRIGGER_RELEASE_THRESHOLD if _trigger_pressed else TRIGGER_PRESS_THRESHOLD))
	elif _is_grip_action(name):
		_set_grip_state(value >= (GRIP_RELEASE_THRESHOLD if _grip_pressed else GRIP_PRESS_THRESHOLD))

func _on_input_vector2_changed(name: String, value: Vector2) -> void:
	if name == "primary" or name == "thumbstick":
		_stick = value

## Pressing on the other controller hands the pointer over to it.
func _take_over() -> void:
	if active == self:
		return
	if is_instance_valid(active):
		active._release_all()
		active.raycast_origin.visible = false
	active = self
	_update_pointer()

func _set_trigger_state(pressed: bool) -> void:
	if _trigger_pressed == pressed:
		return
	_trigger_pressed = pressed
	if pressed:
		_idle_s = 0.0  # picked up: it has the pointer again at once
	if not main_scene or not in_use():
		return  # untracked: nothing to aim with
	if pressed:
		_take_over()
		if is_instance_valid(_dragging):
			return  # one thing at a time: the other button already moves something
		if _target != Target.NONE:
			_buzz(0.3, 0.02)
		match _target:
			Target.OVERLAY:
				main_scene.send_ui_pointer_button(true, MOUSE_BUTTON_LEFT)
				_overlay_pressed = true
			Target.PANEL:
				_buttons |= 0x01
				_send_mouse(_last_monitor, _last_pixel, 0, 0)
			Target.BAR:
				_start_drag(_bar_target, true)
			_:
				pass  # the keyboard and whiteboard read the trigger in _update_pointer()
	else:
		if _drag_by_trigger:
			_stop_drag()
		if _overlay_pressed:
			main_scene.send_ui_pointer_button(false, MOUSE_BUTTON_LEFT)
			_overlay_pressed = false
		if _buttons & 0x01:
			_buttons &= ~0x01
			_send_mouse(_last_monitor, _last_pixel, 0, 0)

func _set_grip_state(pressed: bool) -> void:
	if _grip_pressed == pressed:
		return
	_grip_pressed = pressed
	if pressed:
		_idle_s = 0.0
	if not main_scene or not in_use():
		return
	if pressed:
		_take_over()
		_grip_held_s = 0.0
		if is_instance_valid(_dragging):
			return
		match _target:
			Target.OVERLAY:
				_start_drag(main_scene.get("ui_overlay"))
			Target.KEYBOARD:
				_start_drag(main_scene.get("virtual_keyboard"))
			Target.BOARD:
				_start_drag(main_scene.get("whiteboard"))
			Target.BAR:
				_start_drag(_bar_target)
			Target.PANEL:
				_grip_pending_panel = _panel
	else:
		if is_instance_valid(_grip_pending_panel) and _last_monitor >= 0:
			# Short squeeze on a screen: right click where it points.
			_send_mouse(_last_monitor, _last_pixel, 0, 0, 0x02)
			_send_mouse(_last_monitor, _last_pixel, 0, 0)
			_buzz(0.3, 0.02)
		_grip_pending_panel = null
		if not _drag_by_trigger:
			_stop_drag()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Counts how long the controller has sat still (put down after IDLE_HIDE_S).
## A held trigger or grip means it is in a hand, however still. Put down, only
## a real pick-up wakes it (see WAKE_MOVE_M); its tracking coming back keeps
## it in use only if it still was.
func _update_idle(delta: float) -> void:
	var now := controller.global_transform
	var tracked := controller.get_has_tracking_data()
	var woke := tracked and not _was_tracked and _idle_s < IDLE_HIDE_S
	_was_tracked = tracked
	if _idle_s < IDLE_HIDE_S:
		var turned := _turned(now, _idle_ref)
		woke = woke or turned > IDLE_TURN_RAD \
			or (_moved(now, _idle_ref) > IDLE_MOVE_M and turned > IDLE_MIN_TURN_RAD)
		_rest = now
	elif _moved(now, _last_pose) > JUMP_M or _turned(now, _last_pose) > JUMP_TURN_RAD:
		if Time.get_ticks_msec() - _jump_logged_ms > 2000:
			_jump_logged_ms = Time.get_ticks_msec()
			print("[VRInput] %s controller: its pose jumped %.1f cm / %.0f° while put down, ignored" % [
				_side(), _moved(now, _last_pose) * 100.0, rad_to_deg(_turned(now, _last_pose))])
		_rest = now
	elif _turned(now, _rest) > WAKE_TURN_RAD \
			or (_moved(now, _rest) > WAKE_MOVE_M and _turned(now, _rest) > WAKE_MIN_TURN_RAD):
		print("[VRInput] %s controller: picked up (moved %.1f cm, turned %.0f°)" % [
			_side(), _moved(now, _rest) * 100.0, rad_to_deg(_turned(now, _rest))])
		woke = true
	else:
		_rest = _rest.interpolate_with(now, 1.0 - exp(-delta / WAKE_SMOOTH_S))
	_last_pose = now
	if _trigger_pressed or _grip_pressed or woke:
		_idle_ref = now
		_idle_s = 0.0
	else:
		_idle_s += delta

static func _moved(a: Transform3D, b: Transform3D) -> float:
	return a.origin.distance_to(b.origin)

static func _turned(a: Transform3D, b: Transform3D) -> float:
	return a.basis.get_rotation_quaternion().angle_to(b.basis.get_rotation_quaternion())

func _side() -> String:
	return "right" if _is_right() else "left"

func _set_role(role: String) -> void:
	if role != _role:
		_role = role
		print("[VRInput] %s controller: %s (profile %s)" % [_side(), role, _profile()])

func _profile() -> String:
	var t := XRServer.get_tracker(controller.tracker) as XRPositionalTracker
	return t.profile if t else "-"
