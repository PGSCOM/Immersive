extends SceneTree
## Feeds hand_input.gd a fake tracked right hand and checks that a pinch clicks
## exactly where the hand was pointing, without drifting or dragging; that a
## pinch on the grab bar under the screen moves it (no click reaches the PC)
## while a long pinch on the screen stays a click; and that with the left
## hand set to point, the right hand's long pinch opens the menu instead.
##
##   godot --headless --xr-mode off --fixed-fps 72 --path client/project \
##       -s "$PWD/client/tests/hand_input_test.gd"
##
## Prints one ok/FAIL line per check and "RESULT fails=N".

## Stands in for main.gd: one 2 x 1.6 m monitor panel 1.5 m ahead (1920x1080)
## with a grab bar zone under it that moves `box` through a real LaserDrag.
const FAKE_MAIN := """
extends Node3D
var sent: Array = []
var pointer_hand := "right"
var grabbed := 0
var released := 0
var toggles := 0
var box := Node3D.new()
var drag: LaserDrag = null
func _ready(): add_child(box); box.position = Vector3(0.0, 0.5, -1.5)
func _process(delta): if drag: drag.update(delta)
func pick(o: Vector3, d: Vector3) -> Dictionary:
	var t := (-1.5 - o.z) / d.z
	var p := o + d * t
	if absf(p.x) <= 1.0 and p.y >= 0.6 and p.y <= 2.2:
		return {"kind": "panel", "panel": self, "monitor_id": 0, "distance": t,
			"uv": Vector2((p.x + 1.0) / 2.0, (2.2 - p.y) / 1.6)}
	if absf(p.x) <= 0.3 and absf(p.y - 0.5) <= 0.05:
		return {"kind": "bar", "target": self, "distance": t}
	return {}
func uv_to_pixel(uv: Vector2) -> Vector2i: return Vector2i(uv * Vector2(1920, 1080))
func send_mouse_input(_m, x, y, b, _s, _h = 0): sent.append([x, y, b])
func start_drag(p, dist):
	grabbed += 1
	drag = LaserDrag.new(box, p, dist)
func stop_drag():
	released += 1
	drag = null
func get_drag_distance() -> float: return drag.distance if drag else 0.0
func toggle_ui_overlay(): toggles += 1
"""

## Index knuckle, straight ahead of the right shoulder: aims at pixel (1123, 526).
const KNUCKLE := Vector3(0.17, 1.42, -0.45)
## Lower: the ray from the shoulder meets the bar zone (y 0.5 at z -1.5).
const BAR_KNUCKLE := Vector3(0.17, 1.144, -0.45)

var main: Node3D
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
	var head := Camera3D.new()
	head.position = Vector3(0, 1.6, 0)
	main.add_child(head)
	head.current = true
	hand.name = &"/user/hand_tracker/right"
	hand.has_tracking_data = true
	hand.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	XRServer.add_tracker(hand)
	input = load("res://scripts/hand_input.gd").new()
	main.add_child(input)
	_run()

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _frames(n: int) -> void:
	for i in n:
		await process_frame

## Open hand (finger straight) or pinching with `gap` metres between the tips.
## The index curls toward the thumb to pinch, which is what used to swing the
## old finger-direction ray; the knuckle stays put.
func _pose(knuckle: Vector3, gap: float) -> void:
	var tip := knuckle + (Vector3(0, 0, -0.08) if gap > 0.04 else Vector3(-0.03, -0.04, -0.05))
	for j in [[XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, knuckle],
			[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP, tip],
			[XRHandTracker.HAND_JOINT_THUMB_TIP, tip + Vector3(0, -gap, 0)]]:
		hand.set_hand_joint_transform(j[0], Transform3D(Basis(), j[1]))
		hand.set_hand_joint_flags(j[0], XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)

func _last() -> Array:
	return main.sent.back()

func _run() -> void:
	_pose(KNUCKLE, 0.08)
	await _frames(40)
	var aim := _last()
	check(aim[2] == 0 and absi(aim[0] - 1123) <= 3 and absi(aim[1] - 526) <= 3,
		"open hand points straight ahead -> %s" % [aim])

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

	# --- Point with the left hand: the right one opens the menu -------------
	main.pointer_hand = "left"
	mark2 = main.sent.size()
	_pose(KNUCKLE, 0.005)
	await _frames(60)  # ~0.8 s
	check(main.toggles == 1 and main.sent.slice(mark2).all(func(e): return e[2] == 0),
		"pointing with the left hand: a long right pinch opens the menu, no click")
	_pose(KNUCKLE, 0.08)
	await _frames(15)
	main.pointer_hand = "right"
	await _frames(40)

	hand.has_tracking_data = false
	await _frames(3)
	check(_last()[2] == 0, "losing the hand releases the click")

	XRServer.remove_tracker(hand)
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
