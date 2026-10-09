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
##   - hand joints reported (source unknown, as on the Pico) never take the
##     pointer from a controller in use;
##   - no interaction profile bound (Godot freezes its pose and buttons) is
##     no controller in use, even with its trigger frozen down, and neither is
##     the simple controller profile while that hand is tracked (a runtime
##     mimicking a controller with the bare hand);
##   - a controller without a tracked pose counts as put down at once (no
##     laser, no model, no clicks, not in use) and is back when tracked again;
##   - a trigger press wakes a put-down controller at once, without moving it,
##     and a controller held still with the trigger down stays in use;
##   - put down, a slow drift of its tracking, a one-frame jump (the cameras
##     finding it again) or its position wandering with the orientation frozen
##     (the Pico in passthrough) does not wake it, a hand lifting it does;
##   - just put down, its position wandering with the orientation frozen does
##     not keep it in use, and lying there its tracking lost and found again
##     does not wake it (the hands keep the pointer);
##   - with a grip pose the model sits on it and the ray starts at the model's
##     tip, still at the ray angle.
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
## What OpenXR reports for each /user/hand/* (tracked, so the controllers are in use).
var pads := {}

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
	var pad := XRControllerTracker.new()
	pad.name = tracker
	pad.profile = "/interaction_profiles/bytedance/pico4_controller"
	pad.set_pose(&"default", Transform3D(Basis(), pos), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	XRServer.add_tracker(pad)
	pads[tracker] = pad
	var c := XRController3D.new()
	c.name = n
	c.tracker = tracker
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

	# --- Hand joints never take the pointer from a controller in use ---------
	var VRInput := load("res://scripts/vr_input.gd")
	var hand := XRHandTracker.new()
	hand.name = &"/user/hand_tracker/right"
	hand.has_tracking_data = true  # source UNKNOWN, as the Pico reports it with controllers held
	XRServer.add_tracker(hand)
	_aim(right, Vector3(0, 1.25, -1.5))
	await _frames(3)
	check(laser.visible and model.visible and VRInput.any_in_use(),
		"hand joints reported: the controller in use keeps the pointer")
	mark = main.sent.size()
	r._set_trigger_state(true)
	await _frames(2)
	r._set_trigger_state(false)
	await _frames(1)
	check(main.sent.slice(mark).any(func(e): return e[2] == 1) and _last()[2] == 0, "and its trigger clicks")

	# --- No profile bound: Godot stops reading it but keeps its last pose and
	# buttons, so it still looks tracked, and held ----------------------------
	r._set_trigger_state(true)
	await _frames(2)
	pads[&"right_hand"].profile = "/interaction_profiles/none"
	await _frames(1)
	check(not r.in_use() and not laser.visible and _last()[2] == 0,
		"no profile bound to it, trigger frozen down: not in use at once, the click let go")
	r._set_trigger_state(false)

	# --- The runtime mimicking a controller with the bare hand ---------------
	# Through the simple controller profile it moves as the hand does and the
	# pinch is its trigger: that is the hand, not a controller in use.
	pads[&"right_hand"].profile = "/interaction_profiles/khr/simple_controller"
	mark = main.sent.size()
	for i in 12:
		right.rotate_y(0.01)
		await process_frame
	r._set_trigger_state(true)
	await _frames(2)
	r._set_trigger_state(false)
	await _frames(1)
	check(not r.in_use() and not laser.visible and main.sent.slice(mark).all(func(e): return e[2] == 0),
		"a tracked hand driving the simple controller profile is no controller in use: no laser, no click")
	hand.has_tracking_data = false
	r._set_trigger_state(true)
	r._set_trigger_state(false)
	await _frames(1)
	check(r.in_use(), "with no hand tracked, a simple controller is a controller")
	hand.has_tracking_data = true
	pads[&"right_hand"].profile = "/interaction_profiles/bytedance/pico4_controller"
	_aim(right, Vector3(0, 1.25, -1.5))
	r._set_trigger_state(true)  # takes the pointer back
	r._set_trigger_state(false)
	await _frames(2)

	# --- No tracked pose: put down at once, back when tracked -----------------
	pads[&"right_hand"].invalidate_pose(&"default")
	await _frames(1)
	check(not laser.visible and not model.visible and not r.in_use(),
		"a controller that loses tracking is put down at once: no laser, no model")
	mark = main.sent.size()
	r._set_trigger_state(true)
	await _frames(2)
	r._set_trigger_state(false)
	await _frames(1)
	check(main.sent.slice(mark).all(func(e): return e[2] == 0) and not r.in_use(),
		"and its trigger clicks nothing (no ray to aim with)")
	pads[&"left_hand"].invalidate_pose(&"default")
	await _frames(1)
	check(not VRInput.any_in_use(), "both untracked: no controller in use (the hands may point)")
	pads[&"right_hand"].set_pose(&"default", Transform3D(right.basis, right.position + Vector3(0, 0.03, 0)),
		Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	await _frames(1)
	check(laser.visible and model.visible and VRInput.any_in_use(), "tracked again in the hand: the pointer is back at once")
	XRServer.remove_tracker(hand)

	# --- Put down: disappears, and comes back when moved -------------------
	await _frames(72)
	right.position.x += 0.001  # ~1 mm of tracking noise
	await _frames(5)
	check(model.visible and laser.visible, "visible while in use")
	await _frames(72 * 3)
	check(not model.visible and not laser.visible, "hidden after 3 s still")
	mark = main.sent.size()
	r._set_trigger_state(true)  # picked up by the trigger, not moved
	await _frames(1)
	check(model.visible and laser.visible and main.sent.slice(mark).any(func(e): return e[2] == 1),
		"a trigger press wakes it at once and clicks")
	await _frames(72 * 4)
	check(laser.visible and _last()[2] == 1, "held perfectly still with the trigger down for 4 s: still in use, still clicking")
	r._set_trigger_state(false)
	await _frames(72 * 3 + 5)
	check(not model.visible, "put down again")
	# Lying on the desk the tracking drifts, and jumps when it finds the
	# controller again: neither is a hand picking it up.
	for i in 72 * 5:
		right.position.x += 0.04 / (72 * 5)
		await process_frame
	check(not model.visible, "a 4 cm drift over 5 s does not wake it")
	right.position.y += 0.06
	await _frames(3)
	check(not model.visible, "a 6 cm jump in one frame does not wake it")
	right.rotate_y(0.4)
	await _frames(3)
	check(not model.visible, "nor does a 23° turn in one frame")
	await _frames(72)
	for i in 3:  # the Pico extrapolating it: 3.6 cm, orientation bit for bit the same
		right.position.x -= 0.012
		await process_frame
	check(not model.visible, "nor does its position wandering with the orientation frozen")
	for i in 4:  # a hand lifting it: 5 cm and 2.3° in 4 frames
		right.position.y += 0.012
		right.rotate_object_local(Vector3.RIGHT, 0.01)
		await process_frame
	check(model.visible, "picked up: back at once")
	# Put down and lost by the Pico at once (passthrough): the orientation
	# frozen, the position wandering 1.2 cm every half second.
	for i in 72 * 4:
		if i % 36 == 0:
			right.position.x += 0.012 if (i / 36) % 2 == 0 else -0.012
		await process_frame
	check(not model.visible and not r.in_use(),
		"just put down, its position wandering with the orientation frozen: put down all the same")
	pads[&"right_hand"].invalidate_pose(&"default")
	await _frames(10)
	pads[&"right_hand"].set_pose(&"default", right.transform, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	await _frames(3)
	check(not model.visible and not r.in_use(), "lying there, its tracking lost and found again does not wake it")

	# --- Model on the grip pose, ray from its tip ---------------------------
	var pad: XRControllerTracker = pads[&"right_hand"]
	var grip := Transform3D(Basis(Vector3.RIGHT, 0.5), Vector3(0, -0.02, 0.05))
	pad.set_pose(&"aim", Transform3D(), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	pad.set_pose(&"grip", grip, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	await _frames(2)
	check(model.transform.is_equal_approx(grip * r.MODEL_IN_GRIP), "the model sits on the grip pose")
	check(laser.position.is_equal_approx(grip * r.MODEL_IN_GRIP * r.MODEL_TIP)
		and laser.basis.is_equal_approx(r.RAY_ORIGIN.basis), "the ray starts at its tip, still tilted 40°")
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
