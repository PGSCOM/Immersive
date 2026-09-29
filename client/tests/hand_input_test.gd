extends SceneTree
## Feeds hand_input.gd a fake tracked right hand and checks that a pinch clicks
## exactly where the hand was pointing, without drifting or dragging.
##
##   godot --headless --xr-mode off --fixed-fps 72 --path client/project \
##       -s "$PWD/client/tests/hand_input_test.gd"
##
## Prints one ok/FAIL line per check and "RESULT fails=N".

## Stands in for main.gd: one 2 x 1.6 m monitor panel 1.5 m ahead (1920x1080).
const FAKE_MAIN := """
extends Node3D
var sent: Array = []
func get_ui_hit_from_ray(_o, _d): return {}
func send_keyboard_pointer(_o, _d, _p): return false
func get_panel_hit_from_ray(o: Vector3, d: Vector3) -> Dictionary:
	var t := (-1.5 - o.z) / d.z
	var p := o + d * t
	return {"valid": true, "panel": self, "monitor_id": 0, "distance": t,
		"uv": Vector2((p.x + 1.0) / 2.0, (2.2 - p.y) / 1.6)}
func uv_to_pixel(uv: Vector2) -> Vector2i: return Vector2i(uv * Vector2(1920, 1080))
func send_mouse_input(_m, x, y, b, _s, _h = 0): sent.append([x, y, b])
"""

## Index knuckle, straight ahead of the right shoulder: aims at pixel (1123, 526).
const KNUCKLE := Vector3(0.17, 1.42, -0.45)

var main: Node3D
var hand := XRHandTracker.new()
var fails := 0

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
	main.add_child(load("res://scripts/hand_input.gd").new())
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

	hand.has_tracking_data = false
	await _frames(3)
	check(_last()[2] == 0, "losing the hand releases the click")

	XRServer.remove_tracker(hand)
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
