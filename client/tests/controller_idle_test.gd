extends SceneTree
## Controller input (vr_input.gd) against a fake main scene with one screen:
##   - a controller left still disappears (model and laser) and stops driving
##     the pointer, and comes back as soon as it moves;
##   - trigger clicks where it points; releasing off the screen still reaches
##     the PC (no stuck button);
##   - a short grip squeeze right-clicks, a held grip grabs the screen instead
##     (and sends no click);
##   - the trigger on the grab bar under the screen grabs it (no click) until
##     it is let go; a locked layout refuses the grab;
##   - the ray tilt follows main.gd's ray_angle_deg live;
##   - the other controller's trigger takes the pointer over;
##   - bare hands (the hand interaction profile, or a tracked hand) take the
##     pointer and hide that side's model; the controller gets it back.
##
##   godot --headless --xr-mode off --fixed-fps 72 --path client/project \
##       -s "$PWD/client/tests/controller_idle_test.gd"
##
## Prints one ok/FAIL line per check and "RESULT fails=N".

## Stands in for main.gd: a 2 m wide screen 1.5 m ahead (1920x1080) that
## records every mouse event and grab.
const FAKE_MAIN := """
extends Node3D
var sent: Array = []
var haptics_enabled := true
var ray_angle_deg := 40.0
var grabbed := 0
var released := 0
var locked := false
func pick(o: Vector3, d: Vector3) -> Dictionary:
	if d.z > -0.01:
		return {}
	var t := (-1.5 - o.z) / d.z
	var p := o + d * t
	if absf(p.x) <= 1.0 and absf(p.y - 1.25) <= 0.56:
		return {"kind": "panel", "panel": self, "monitor_id": 0, "distance": t,
			"uv": Vector2((p.x + 1.0) / 2.0, (1.81 - p.y) / 1.12)}
	if absf(p.x) <= 0.15 and absf(p.y - 0.63) <= 0.035:
		return {"kind": "bar", "target": self, "distance": t}
	return {}
func ray_to_screen_hit(_o, _d): return {}  # makes LaserDrag treat it as a screen
func can_move_panel(_p) -> bool: return not locked
func uv_to_pixel(uv: Vector2) -> Vector2i: return Vector2i(uv * Vector2(1920, 1080))
func mark_hovered(): pass
func start_drag(_p, _d): grabbed += 1
func stop_drag(): released += 1
func send_mouse_input(_m, x, y, b, _s, _h = 0): sent.append([x, y, b])
func on_layout_changed(): pass
"""

var fails := 0
var main: Node3D
var right: XRController3D
var left: XRController3D

func _initialize() -> void:
	var script := GDScript.new()
	script.source_code = FAKE_MAIN
	script.reload()
	main = Node3D.new()
	main.set_script(script)
	main.name = "Main"
	root.add_child(main)
	var origin := XROrigin3D.new()
	origin.name = "XROrigin3D"
	main.add_child(origin)
	right = _controller(origin, "RightController", &"right_hand", Vector3(0.2, 1.25, -0.3))
	left = _controller(origin, "LeftController", &"left_hand", Vector3(-0.2, 1.25, -0.3))
	_run()

func _controller(parent: Node, n: String, tracker: StringName, pos: Vector3) -> XRController3D:
	var c := XRController3D.new()
	c.name = n
	c.tracker = tracker
	c.position = pos
	var input := Node.new()
	input.set_script(load("res://scripts/vr_input.gd"))
	input.name = "VRInput"
	c.add_child(input)
	parent.add_child(c)
	return c

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _frames(n: int) -> void:
	for i in n:
		await process_frame

## Point the controller's laser (40° tilted ray, see vr_input.RAY_ORIGIN) at
## world point `at` by rotating the controller.
func _aim(c: XRController3D, at: Vector3) -> void:
	var ray: Node3D = c.get_node("RaycastOrigin")
	var want := (at - ray.global_position).normalized()
	var have := (-ray.global_basis.z).normalized()
	var q := Quaternion(have, want)
	c.global_basis = Basis(q) * c.global_basis

func _input(c: XRController3D) -> Node:
	return c.get_node("VRInput")

func _last() -> Array:
	return main.sent.back() if not main.sent.is_empty() else []

func _run() -> void:
	await _frames(3)  # controllers build their laser and model deferred
	var model := right.get_node("ControllerVisual") as Node3D
	var laser := right.get_node("RaycastOrigin") as Node3D
	var r := _input(right)

	# --- Pointing and clicking -------------------------------------------
	_aim(right, Vector3(0, 1.25, -1.5))
	await _frames(3)
	var aim := _last()
	# (_aim() turns the controller about its own origin, not the ray's, so
	# it lands within about a centimetre of the target.)
	check(aim.size() == 3 and absi(aim[0] - 960) <= 20 and absi(aim[1] - 606) <= 20 and aim[2] == 0,
		"laser at the screen centre moves the mouse there -> %s" % [aim])
	r.last_buzz = 0.0
	r._set_trigger_state(true)
	await _frames(1)
	check(_last()[2] == 1, "trigger presses the left button")
	check(r.last_buzz > 0.0, "a click ticks the controller")
	_aim(right, Vector3(3.0, 1.25, -1.5))  # off the screen, still held
	await _frames(3)
	check(_last()[2] == 1, "dragging past the edge keeps the button down")
	r._set_trigger_state(false)
	await _frames(1)
	check(_last()[2] == 0, "release off the screen still lets go on the PC -> %s" % [_last()])

	# --- Grip: short = right click, long = grab -----------------------------
	_aim(right, Vector3(0.2, 1.3, -1.5))
	await _frames(3)
	var mark: int = main.sent.size()
	r._set_grip_state(true)
	await _frames(5)   # ~70 ms
	r._set_grip_state(false)
	await _frames(1)
	# Button changes only (the fake main does not drop repeated moves).
	var clicks: Array = []
	for e in main.sent.slice(mark):
		if clicks.is_empty() or clicks.back() != e[2]:
			clicks.append(e[2])
	check(clicks == [0, 2, 0] or clicks == [2, 0], "short grip squeeze right-clicks -> %s" % [clicks])
	mark = main.sent.size()
	r._set_grip_state(true)
	await _frames(40)  # ~0.55 s
	check(main.grabbed == 1, "held grip grabs the screen")
	check(r.last_buzz > 0.5, "grabbing gives a stronger tick")
	r._set_grip_state(false)
	await _frames(1)
	check(main.released == 1, "letting go of the grip drops it")
	check(main.sent.slice(mark).all(func(e): return e[2] == 0),
		"grabbing sends no mouse button")

	# --- Trigger on the bar under the screen --------------------------------
	_aim(right, Vector3(0.0, 0.63, -1.5))
	await _frames(3)
	mark = main.sent.size()
	r._set_trigger_state(true)
	await _frames(10)
	check(main.grabbed == 2, "trigger on the bar grabs the screen")
	r._set_grip_state(true)
	r._set_grip_state(false)
	await _frames(2)
	check(main.released == 1, "a grip tap meanwhile does not drop it")
	r._set_trigger_state(false)
	await _frames(1)
	check(main.released == 2, "letting go of the trigger drops it")
	check(main.sent.slice(mark).all(func(e): return e[2] == 0), "the bar sends no mouse button")
	main.locked = true
	r._set_trigger_state(true)
	await _frames(3)
	r._set_trigger_state(false)
	await _frames(1)
	check(main.grabbed == 2, "a locked layout refuses the grab")
	main.locked = false

	main.ray_angle_deg = 0.0
	await _frames(2)
	check(laser.transform.basis.z.is_equal_approx(Vector3.BACK), "the ray tilt follows ray_angle_deg live")
	main.ray_angle_deg = 40.0
	await _frames(2)
	check(laser.transform.basis.is_equal_approx(r.RAY_ORIGIN.basis), "40 degrees is the Pico 4 tilt")

	main.haptics_enabled = false
	r.last_buzz = 0.0
	r._set_trigger_state(true)
	r._set_trigger_state(false)
	await _frames(1)
	check(r.last_buzz == 0.0, "no vibration when it is switched off")
	main.haptics_enabled = true

	# --- Hand-over between controllers --------------------------------------
	_aim(left, Vector3(-0.5, 1.25, -1.5))
	await _frames(3)
	check(not left.get_node("RaycastOrigin").visible, "idle controller shows no laser")
	_input(left)._set_trigger_state(true)
	await _frames(2)
	check(left.get_node("RaycastOrigin").visible and not laser.visible,
		"the other trigger takes the pointer over")
	check(_last()[2] == 1 and _last()[0] < 960, "and clicks where it points -> %s" % [_last()])
	_input(left)._set_trigger_state(false)
	await _frames(1)
	r._set_trigger_state(true)
	r._set_trigger_state(false)
	await _frames(2)

	# --- Bare hands take the pointer, a controller gets it back -------------
	var pad := XRControllerTracker.new()  # what OpenXR reports for /user/hand/right
	pad.name = &"right_hand"
	pad.profile = "/interaction_profiles/bytedance/pico4_controller"
	XRServer.add_tracker(pad)
	_aim(right, Vector3(0, 1.25, -1.5))
	await _frames(3)
	check(laser.visible and model.visible, "a controller in use has the pointer")
	pad.profile = "/interaction_profiles/ext/hand_interaction_ext"
	await _frames(2)
	check(not laser.visible and not model.visible,
		"the runtime switched the right side to a bare hand: no laser, no controller model")
	mark = main.sent.size()
	r._set_trigger_state(true)
	await _frames(2)
	r._set_trigger_state(false)
	await _frames(1)
	check(main.sent.slice(mark).all(func(e): return e[2] == 0), "meanwhile a trigger event does not click")
	pad.profile = "/interaction_profiles/bytedance/pico4_controller"
	await _frames(2)
	check(laser.visible and model.visible, "the controller again: it drives the pointer at once")
	XRServer.remove_tracker(pad)
	var hand := XRHandTracker.new()
	hand.name = &"/user/hand_tracker/left"
	hand.has_tracking_data = true  # source UNKNOWN, as on the Pico (no data-source extension)
	XRServer.add_tracker(hand)
	await _frames(2)
	check(not laser.visible, "a camera-tracked hand takes the pointer")
	hand.has_tracking_data = false
	await _frames(2)
	check(laser.visible, "the hand gone, the controller has it back")
	XRServer.remove_tracker(hand)

	# --- Put down: disappears, and comes back when moved -------------------
	await _frames(72)
	right.position.x += 0.001  # ~1 mm of tracking noise
	await _frames(5)
	check(model.visible and laser.visible, "visible while in use")
	await _frames(72 * 3)
	check(not model.visible and not laser.visible, "hidden after 3 s still")
	right.position.x += 0.05
	await _frames(2)
	check(model.visible, "back as soon as it moves")
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
