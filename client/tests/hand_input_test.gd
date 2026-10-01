extends SceneTree
## Feeds hand_input.gd fake trackers and checks:
##   - the fallback ray (shoulder -> index knuckle): a pinch clicks exactly
##     where the hand was pointing, without drifting or dragging, and turning
##     or tilting the head does not move it;
##   - the runtime's hand ray (hand interaction profile aim pose) wins over the
##     fallback, and its pinch value clicks when the finger joints are gone;
##   - a hand tracker replaced by a new one (session restart) still works;
##   - a pinch on the grab bar under the screen moves it (no click reaches the
##     PC) while a long pinch on the screen stays a click; pinches click the menu;
##   - the other hand's palm turned to the face shows the menu mark and a short
##     pinch toggles the menu (a long one or a palm turned away does not).
##
##   godot --headless --xr-mode off --fixed-fps 72 --path client/project \
##       -s "$PWD/client/tests/hand_input_test.gd"
##
## Prints one ok/FAIL line per check and "RESULT fails=N".

## Stands in for main.gd: one 2 x 1.6 m monitor panel 1.5 m ahead (1920x1080)
## with a grab bar zone under it that moves `box` through a real LaserDrag,
## and a menu zone to its left.
const FAKE_MAIN := """
extends Node3D
var sent: Array = []
var ui: Array = []
var pointer_hand := "right"
var grabbed := 0
var released := 0
var toggles := 0
var box := Node3D.new()
var drag: LaserDrag = null
func _ready(): add_child(box); box.position = Vector3(0.0, 0.5, -1.5)
func _process(delta): if drag: drag.update(delta)
func pick(o: Vector3, d: Vector3) -> Dictionary:
	if d.z > -0.01:
		return {}
	var t := (-1.5 - o.z) / d.z
	var p := o + d * t
	if absf(p.x) <= 1.0 and p.y >= 0.6 and p.y <= 2.2:
		return {"kind": "panel", "panel": self, "monitor_id": 0, "distance": t,
			"uv": Vector2((p.x + 1.0) / 2.0, (2.2 - p.y) / 1.6)}
	if absf(p.x) <= 0.3 and absf(p.y - 0.5) <= 0.05:
		return {"kind": "bar", "target": self, "distance": t}
	if p.x < -1.1 and p.x > -1.9 and absf(p.y - 1.4) < 0.4:
		return {"kind": "overlay", "distance": t, "uv": Vector2(0.5, 0.5)}
	return {}
func uv_to_pixel(uv: Vector2) -> Vector2i: return Vector2i(uv * Vector2(1920, 1080))
func send_mouse_input(_m, x, y, b, _s, _h = 0): sent.append([x, y, b])
func send_ui_pointer_move(_uv): pass
func send_ui_pointer_button(pressed, _b): ui.append(pressed)
func start_drag(p, dist):
	grabbed += 1
	drag = LaserDrag.new(box, p, dist)
func stop_drag():
	released += 1
	drag = null
func get_drag_distance() -> float: return drag.distance if drag else 0.0
func toggle_ui_overlay(): toggles += 1
"""

const HAND_PROFILE := "/interaction_profiles/ext/hand_interaction_ext"
## Eyes at 1.6 m; the neck pivot and right shoulder that hand_input.gd guesses
## from them (NECK_OFFSET, SHOULDER_OFFSET).
const EYES := Vector3(0, 1.6, 0)
const NECK := Vector3(0, 1.52, 0.10)
## Index knuckle straight ahead of the right shoulder (0.16, 1.38, 0.10):
## aims at pixel (1113, 553).
const KNUCKLE := Vector3(0.16, 1.38, -0.45)
## Lower: the ray from the shoulder meets the bar zone (y 0.5 at z -1.5).
const BAR_KNUCKLE := Vector3(0.16, 1.0775, -0.45)
## Further left: the ray lands on the menu zone (x -1.5 at z -1.5).
const MENU_KNUCKLE := Vector3(-0.41, 1.38, -0.45)

var main: Node3D
var head: Camera3D
var hand := XRHandTracker.new()
var fails := 0
var input: Node

func _initialize() -> void:
	var script := GDScript.new()
	script.source_code = FAKE_MAIN
	script.reload()
	main = Node3D.new()
	main.set_script(script)
	main.name = "Main"
	root.add_child(main)
	head = Camera3D.new()
	head.position = EYES
	main.add_child(head)
	head.current = true
	hand = _new_hand(&"/user/hand_tracker/right")
	input = load("res://scripts/hand_input.gd").new()
	main.add_child(input)
	_run()

func _new_hand(tracker_name: StringName) -> XRHandTracker:
	var h := XRHandTracker.new()
	h.name = tracker_name
	h.has_tracking_data = true
	h.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	XRServer.add_tracker(h)
	return h

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _joint(h: XRHandTracker, joint: int, pos: Vector3) -> void:
	h.set_hand_joint_transform(joint, Transform3D(Basis(), pos))
	h.set_hand_joint_flags(joint, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)

## Open hand (finger straight) or pinching with `gap` metres between the tips.
## The index curls toward the thumb to pinch, which is what used to swing the
## old finger-direction ray; the knuckle stays put.
func _pose(knuckle: Vector3, gap: float) -> void:
	var tip := knuckle + (Vector3(0, 0, -0.08) if gap > 0.04 else Vector3(-0.03, -0.04, -0.05))
	_joint(hand, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, knuckle)
	_joint(hand, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP, tip)
	_joint(hand, XRHandTracker.HAND_JOINT_THUMB_TIP, tip + Vector3(0, -gap, 0))

## A hand whose palm (centre `c`) faces along `n`, fingers up, built from joint
## positions only: wrist, palm, index and little knuckles, pinch tips.
func _palm(h: XRHandTracker, left: bool, c: Vector3, n: Vector3, gap: float) -> void:
	n = n.normalized()
	var f := (Vector3.UP - n * n.dot(Vector3.UP)).normalized()
	var thumb_side := n.cross(f) if left else f.cross(n)
	_joint(h, XRHandTracker.HAND_JOINT_WRIST, c - f * 0.04)
	_joint(h, XRHandTracker.HAND_JOINT_PALM, c)
	_joint(h, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, c + f * 0.04 + thumb_side * 0.025)
	_joint(h, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL, c + f * 0.04 - thumb_side * 0.025)
	var tip := c + f * 0.08 + n * 0.03
	_joint(h, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP, tip)
	_joint(h, XRHandTracker.HAND_JOINT_THUMB_TIP, tip + thumb_side * gap)

## Turn the head by `yaw`/`pitch`/`roll` (radians) about the neck, as a real
## head does: the eyes swing, the neck pivot stays.
func _turn_head(yaw: float, pitch: float, roll: float) -> void:
	var b := Basis.from_euler(Vector3(pitch, yaw, roll))
	head.global_transform = Transform3D(b, NECK - b * (NECK - EYES))

func _last() -> Array:
	return main.sent.back()

func _near(a: Array, b: Array) -> bool:
	return absi(a[0] - b[0]) <= 3 and absi(a[1] - b[1]) <= 3

func _run() -> void:
	_pose(KNUCKLE, 0.08)
	await _frames(40)
	var aim := _last()
	check(aim[2] == 0 and _near(aim, [1113, 553]), "open hand points straight ahead -> %s" % [aim])

	# --- Looking around does not move the ray ------------------------------
	for turn in [[0.4, 0.0, 0.0], [-0.35, -0.3, 0.0], [0.2, 0.25, 0.15]]:
		_turn_head(turn[0], turn[1], turn[2])
		await _frames(30)
		check(_near(_last(), aim), "head turned %s rad: the ray stays -> %s" % [turn, _last()])
	_turn_head(0.0, 0.0, 0.0)
	await _frames(30)

	var mark: int = main.sent.size()
	_pose(KNUCKLE, 0.005)
	await _frames(3)
	var press: Array = main.sent.slice(mark).filter(func(e): return e[2] == 1)
	check(not press.is_empty() and press[0][0] == aim[0] and press[0][1] == aim[1],
		"pinch clicks where the hand pointed -> %s" % [press.slice(0, 1)])

	mark = main.sent.size()
	for i in 20:
		var shake := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.002
		_pose(KNUCKLE + shake, 0.005)
		await _frames(1)
	var held: Array = main.sent.slice(mark)
	check(held.all(func(e): return e == [aim[0], aim[1], 1]),
		"2 mm hand shake while pinching does not drag -> %s" % [held.slice(-1)])

	_pose(KNUCKLE, 0.025)
	await _frames(3)
	check(_last()[2] == 1, "half-open pinch (25 mm) still holds the click")

	# The glitches seen on a real Pico 4 mid-pinch: tips jolt apart for two
	# frames, or drop out of tracking (thumb hidden behind the index).
	mark = main.sent.size()
	_pose(KNUCKLE, 0.08)
	await _frames(2)
	_pose(KNUCKLE, 0.005)
	await _frames(2)
	hand.set_hand_joint_flags(XRHandTracker.HAND_JOINT_THUMB_TIP, 0)
	await _frames(20)
	_pose(KNUCKLE, 0.005)
	await _frames(2)
	check(main.sent.slice(mark).all(func(e): return e[2] == 1),
		"2-frame tracking glitches and a hidden thumb do not release the click")

	mark = main.sent.size()
	_pose(KNUCKLE, 0.08)
	await _frames(15)
	var release: Array = main.sent.slice(mark).filter(func(e): return e[2] == 0)
	check(release.slice(0, 1) == [[aim[0], aim[1], 0]],
		"release lands on the press spot -> %s" % [release.slice(0, 1)])

	_pose(KNUCKLE, 0.025)
	await _frames(3)
	check(_last()[2] == 0, "25 mm from open does not click")

	_pose(KNUCKLE, 0.005)
	await _frames(3)
	for i in 10:
		_pose(KNUCKLE + Vector3(0.01 * (i + 1), 0, 0), 0.005)
		await _frames(2)
	await _frames(20)
	check(_last()[2] == 1 and _last()[0] > aim[0] + 200, "pinch and move drags -> %s" % [_last()])

	_pose(KNUCKLE + Vector3(0.5, 0, 0), 0.08)
	await _frames(40)
	check(not input._laser.visible, "no laser when the hand points off the panel")
	_pose(KNUCKLE, 0.08)
	await _frames(40)
	check(input._laser.visible, "laser back when it points at the panel")

	# --- A long pinch on the screen stays a click, never a grab -----------
	_pose(KNUCKLE, 0.005)
	await _frames(150)  # ~2 s
	check(_last()[2] == 1 and main.grabbed == 0, "a 2 s pinch on the screen is still a held click, not a grab")
	_pose(KNUCKLE, 0.08)
	await _frames(15)
	check(_last()[2] == 0, "and lets go on the PC")

	# --- Pinch on the bar grabs and moves the screen ------------------------
	_pose(BAR_KNUCKLE, 0.08)
	await _frames(40)
	var mark2: int = main.sent.size()
	var box0: Vector3 = main.box.global_position
	_pose(BAR_KNUCKLE, 0.005)
	await _frames(3)
	check(main.grabbed == 1, "a pinch on the bar grabs the screen")
	var d0: float = main.get_drag_distance()
	for i in 20:  # sweep right by 10 cm and reach 8 cm further out
		_pose(BAR_KNUCKLE + Vector3(0.005 * (i + 1), 0, -0.004 * (i + 1)), 0.005)
		await _frames(2)
	await _frames(30)
	var moved: Vector3 = main.box.global_position - box0
	check(moved.x > 0.15, "the grabbed screen follows the hand (not frozen by the click slop) -> %.2f m" % moved.x)
	check(main.get_drag_distance() > d0 + 0.15, "reaching out pushes it away (%.2f -> %.2f m)" % [d0, main.get_drag_distance()])
	check(main.sent.slice(mark2).all(func(e): return e[2] == 0), "moving by the bar sends no mouse button")
	_pose(BAR_KNUCKLE, 0.08)
	await _frames(15)
	check(main.released == 1, "opening the pinch drops it")

	# --- Pinch on the menu -------------------------------------------------
	_pose(MENU_KNUCKLE, 0.08)
	await _frames(30)
	_pose(MENU_KNUCKLE, 0.005)
	await _frames(5)
	_pose(MENU_KNUCKLE, 0.08)
	await _frames(15)
	check(main.ui == [true, false], "a pinch on the menu presses and releases its button -> %s" % [main.ui])

	# --- The runtime's hand ray (XR_EXT_hand_interaction) ---------------------
	var ctrl := XRControllerTracker.new()
	ctrl.name = &"right_hand"
	ctrl.profile = HAND_PROFILE
	var from := Vector3(0.2, 1.3, -0.4)
	var at := Vector3(-0.5, 1.8, -1.5)  # pixel (480, 270)
	ctrl.set_pose(&"aim", Transform3D(Basis.looking_at(at - from), from), Vector3.ZERO, Vector3.ZERO,
		XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	XRServer.add_tracker(ctrl)
	_pose(KNUCKLE, 0.08)
	await _frames(5)
	check(_near(_last(), [480, 270]) and _last()[2] == 0,
		"with the hand profile the runtime's aim pose is the ray -> %s" % [_last()])
	_pose(KNUCKLE, 0.005)
	await _frames(3)
	check(_near(_last(), [480, 270]) and _last()[2] == 1, "and the finger pinch clicks there -> %s" % [_last()])
	_pose(KNUCKLE, 0.08)
	await _frames(15)
	check(_last()[2] == 0, "and lets go")
	hand.has_tracking_data = false  # joints gone, the runtime still sees a hand
	ctrl.set_input(&"pinch", 0.9)
	await _frames(3)
	check(_near(_last(), [480, 270]) and _last()[2] == 1, "no joints: the runtime's pinch value clicks -> %s" % [_last()])
	ctrl.set_input(&"pinch", 0.6)
	await _frames(15)
	check(_last()[2] == 1, "a half-open runtime pinch (0.6) still holds")
	ctrl.set_input(&"pinch", 0.1)
	await _frames(15)
	check(_last()[2] == 0, "an open runtime pinch lets go")
	ctrl.profile = "/interaction_profiles/bytedance/pico4_controller"
	await _frames(3)
	check(not input._point_tracked, "a controller again: the hand pointer stops")
	XRServer.remove_tracker(ctrl)

	# --- A new hand tracker (the session restarted) is picked up ------------
	XRServer.remove_tracker(hand)
	hand = _new_hand(&"/user/hand_tracker/right")
	_pose(KNUCKLE, 0.08)
	await _frames(40)
	mark = main.sent.size()
	_pose(KNUCKLE, 0.005)
	await _frames(3)
	check(main.sent.slice(mark).any(func(e): return _near(e, aim) and e[2] == 1),
		"a replaced hand tracker is followed, not a stale one -> %s" % [main.sent.slice(-1)])
	_pose(KNUCKLE, 0.08)
	await _frames(15)

	# --- Palm menu on the other hand ----------------------------------------
	var left := _new_hand(&"/user/hand_tracker/left")
	var palm_at := Vector3(-0.08, 1.4, -0.38)
	_palm(left, true, palm_at, palm_at.direction_to(EYES), 0.08)
	await _frames(5)
	check(input._palm_mark != null and input._palm_mark.visible, "left palm turned to the face shows the menu mark")
	var mark_pos: Vector3 = input._palm_mark.global_position if input._palm_mark else Vector3.ZERO
	check(mark_pos.distance_to(EYES) < palm_at.distance_to(EYES), "the mark floats between the palm and the eyes")
	_palm(left, true, palm_at, palm_at.direction_to(EYES), 0.005)
	await _frames(10)
	check(main.toggles == 0, "the menu waits for the pinch to open (a long hold is the headset's)")
	_palm(left, true, palm_at, palm_at.direction_to(EYES), 0.08)
	await _frames(15)
	check(main.toggles == 1, "a short pinch on the palm mark opens the menu")
	_palm(left, true, palm_at, palm_at.direction_to(EYES), 0.005)
	await _frames(72)  # 1 s
	_palm(left, true, palm_at, palm_at.direction_to(EYES), 0.08)
	await _frames(15)
	check(main.toggles == 1, "a 1 s pinch does not toggle it")
	_palm(left, true, palm_at, -palm_at.direction_to(EYES), 0.08)
	await _frames(5)
	check(not input._palm_mark.visible, "palm turned away: no mark")
	_palm(left, true, palm_at, -palm_at.direction_to(EYES), 0.005)
	await _frames(5)
	_palm(left, true, palm_at, -palm_at.direction_to(EYES), 0.08)
	await _frames(15)
	check(main.toggles == 1, "and a pinch does nothing")
	_turn_head(1.2, 0.0, 0.0)  # looking far to the side
	_palm(left, true, palm_at, palm_at.direction_to(head.global_position), 0.08)
	await _frames(5)
	check(not input._palm_mark.visible, "a palm the eyes do not look at shows no mark")
	_turn_head(0.0, 0.0, 0.0)
	XRServer.remove_tracker(left)

	# --- Point with the left hand: the right palm opens the menu -------------
	main.pointer_hand = "left"
	var mark3: int = main.sent.size()
	var rpalm := Vector3(0.08, 1.4, -0.38)
	_palm(hand, false, rpalm, rpalm.direction_to(EYES), 0.08)
	await _frames(5)
	_palm(hand, false, rpalm, rpalm.direction_to(EYES), 0.005)
	await _frames(10)
	_palm(hand, false, rpalm, rpalm.direction_to(EYES), 0.08)
	await _frames(15)
	check(main.toggles == 2 and main.sent.slice(mark3).all(func(e): return e[2] == 0),
		"pointing with the left hand: a tap on the right palm opens the menu, no click")
	main.pointer_hand = "right"
	_pose(KNUCKLE, 0.08)
	await _frames(40)

	_pose(KNUCKLE, 0.005)
	await _frames(3)
	hand.has_tracking_data = false
	await _frames(3)
	check(_last()[2] == 0, "losing the hand releases the click")

	XRServer.remove_tracker(hand)
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
