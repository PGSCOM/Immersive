extends SceneTree
## Feeds hand_input.gd fake trackers and checks:
##   - the ray (shoulder -> index knuckle): a pinch clicks exactly where the
##     hand was pointing, without drifting or dragging, and turning or tilting
##     the head does not move it; the beam starts at the knuckle and ends on
##     the cursor, also when it points sideways or the click slop holds it;
##   - how far the One Euro filter trails a steady sweep (ms) and how much
##     jitter it keeps (printed as "measure" lines, and bounded);
##   - a hand that comes back already pinched does not click until it opens;
##   - a hand tracker replaced by a new one (session restart) still works;
##   - a pinch on the grab bar under the screen moves it (no click reaches the
##     PC) while a long pinch on the screen stays a click; pinches click the menu;
##   - turning the hand turns what it holds, about the point held, and an arm
##     sweep (hand and ray turning together) does not turn it twice;
##   - fingers parting with a jolt end a drag where it was;
##   - thumb + middle finger: a short pinch right-clicks, held and moved it
##     scrolls the screen (touch-like) or the menu, the pointer holding still;
##   - a fingertip on a panel (main.finger_touch) rests the ray;
##   - the other hand's palm turned to the face shows the menu mark and a short
##     pinch toggles the menu (a long one or a palm turned away does not);
##   - the hand's silhouette sits on the palm joint; in passthrough it takes
##     the stencil-masked material, or hides with passthrough_hands off; it
##     hides while a controller is in use;
##   - the Pico case, with real vr_input.gd controllers: hand joints reported
##     (source unknown) while a controller is held and moving do nothing, and
##     the controller clicks; controllers put down (still, or untracked) give
##     the hand the pointer; picking one up (moving it, or its trigger) takes
##     it back at once; over and over.
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
var passthrough_enabled := false
var passthrough_hands := true
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
var wheel: Array = []
var ui_scroll := 0.0
var touching := false
func send_mouse_input(_m, x, y, b, s, h = 0):
	sent.append([x, y, b])
	if s or h:
		wheel.append([s, h])
func send_ui_pointer_scroll(d): ui_scroll += d
func finger_touch(_who, _tip) -> bool: return touching
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
## Where the controller in the Pico section points: about pixel (400, 540),
## well left of the hand's (1113, 553).
const CTRL_TARGET := Vector3(-0.6, 1.4, -1.5)
const CTRL_AT := Vector3(0.25, 1.2, -0.3)

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

## The palm joint turned to `b` (orientation reported, as on a headset).
func _palm_turn(b: Basis) -> void:
	hand.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, Transform3D(b, Vector3.ZERO))
	hand.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM,
		XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID)

## Index straight, thumb and middle tips `gap` apart.
func _pose_mid(knuckle: Vector3, gap: float) -> void:
	var tip := knuckle + Vector3(-0.01, -0.05, -0.04)
	_joint(hand, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, knuckle)
	_joint(hand, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP, knuckle + Vector3(0, 0, -0.08))
	_joint(hand, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP, tip)
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

## [start, tip] of the hand's beam (a 1 m box along -Z, stretched).
func _beam() -> Array:
	var t: Transform3D = input._laser.global_transform
	return [t * Vector3(0, 0, 0.5), t * Vector3(0, 0, -0.5)]

## The beam starts at `knuckle` and its tip is the cursor dot (1 mm).
func _beam_on(knuckle: Vector3) -> bool:
	var b := _beam()
	return input._laser.visible and b[0].distance_to(knuckle) < 0.001 \
		and b[1].distance_to(input._cursor.global_position) < 0.001

## Point a controller's laser (40° tilted ray) at `at` by turning it.
func _aim(c: XRController3D, at: Vector3) -> void:
	var ray: Node3D = c.get_node("RaycastOrigin")
	var q := Quaternion((-ray.global_basis.z).normalized(), (at - ray.global_position).normalized())
	c.global_basis = Basis(q) * c.global_basis

## A controller in a hand: it moves a little all the time (1.2 cm steps).
func _hold(c: XRController3D, n: int) -> void:
	for i in n:
		if i % 6 == 0:
			c.position.y += 0.012 if (i / 6) % 2 == 0 else -0.012
		await process_frame

## The real filter (72 Hz) on a steady sweep at `deg_s`: ms it trails once settled.
func _lag_ms(deg_s: float) -> float:
	input._dir_filtered = Vector3.ZERO
	var raw := Vector3.FORWARD
	var out := raw
	for i in 216:  # 3 s
		raw = Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(deg_s) * i / 72.0)
		out = input._filter_direction(raw, 1.0 / 72.0)
	return rad_to_deg(out.angle_to(raw)) / deg_s * 1000.0

## A still hand whose knuckle the tracker reports with `sigma` m of noise per
## axis, 60 times a second (the Pico's high-frequency hand tracking), seen at
## 72 Hz for a minute: [raw, filtered] RMS ray error in mrad.
func _jitter_mrad(sigma: float) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var shoulder := NECK + Vector3(0.16, -0.14, 0.0)
	var truth := (KNUCKLE - shoulder).normalized()
	input._dir_filtered = Vector3.ZERO
	var noise := Vector3.ZERO
	var sums := [0.0, 0.0]
	for i in 4392:  # 61 s, the first second not counted
		if floori(i * 60.0 / 72.0) != floori((i - 1) * 60.0 / 72.0):
			noise = Vector3(rng.randfn(0, sigma), rng.randfn(0, sigma), rng.randfn(0, sigma))
		var raw := (KNUCKLE + noise - shoulder).normalized()
		var out: Vector3 = input._filter_direction(raw, 1.0 / 72.0)
		if i >= 72:
			sums[0] += raw.angle_to(truth) ** 2
			sums[1] += out.angle_to(truth) ** 2
	return [sqrt(sums[0] / 4320.0) * 1000.0, sqrt(sums[1] / 4320.0) * 1000.0]

func _run() -> void:
	# --- How much the ray filter lags and shakes ----------------------------
	var lags := {}
	for s in [5, 10, 30, 60, 120]:
		lags[s] = _lag_ms(s)
		print("measure  filter lag at %3d°/s: %5.1f ms" % [s, lags[s]])
	var jit := _jitter_mrad(0.0015)
	print("measure  jitter, still hand with 1.5 mm noise: raw %.2f mrad -> %.2f mrad (%d %%)" % [
		jit[0], jit[1], roundi(jit[1] / jit[0] * 100.0)])
	input._dir_filtered = Vector3.ZERO
	check(lags[5] < 45.0 and lags[10] < 32.0, "slow aim: the ray trails by %.0f ms at 5°/s, %.0f ms at 10°/s" % [lags[5], lags[10]])
	check(lags[60] < 12.0, "steady sweep: %.1f ms behind at 60°/s" % lags[60])
	check(jit[1] < jit[0] * 0.3, "a still hand: the filter keeps under 30 %% of the jitter")

	_pose(KNUCKLE, 0.08)
	await _frames(40)
	var aim := _last()
	check(aim[2] == 0 and _near(aim, [1113, 553]), "open hand points straight ahead -> %s" % [aim])
	check(_beam_on(KNUCKLE), "the beam runs from the index knuckle to the cursor")

	# --- The hand's silhouette ----------------------------------------------
	var palm_basis := Basis(Vector3.UP, 0.4)
	_palm_turn(palm_basis)
	await _frames(2)
	var shape: Node3D = input._hands[1]
	check(is_instance_valid(shape) and shape.visible and not is_instance_valid(input._hands[0])
		and shape.global_transform.is_equal_approx(Transform3D(palm_basis, Vector3.ZERO)),
		"the right hand's silhouette sits on its palm joint (no left hand tracked: none drawn)")
	main.passthrough_enabled = true
	await _frames(2)
	var mat: ShaderMaterial = input._hand_meshes[1].material_override
	check(shape.visible and mat == input._hand_material(true) and mat.shader.code.contains("stencil_mode read")
		and mat.next_pass.shader == mat.shader,
		"passthrough: drawn only where the stencil is marked (both passes)")
	main.passthrough_hands = false
	await _frames(2)
	check(not shape.visible, "passthrough with the hands switched off: not drawn")
	main.passthrough_enabled = false
	await _frames(2)
	check(shape.visible and input._hand_meshes[1].material_override == input._hand_material(false),
		"back in VR: drawn everywhere again, switch or not")
	main.passthrough_hands = true
	input._show_hands(false)
	check(not shape.visible, "a controller in use hides it")
	hand.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
	await _frames(2)
	check(not shape.visible, "no palm orientation: not drawn")

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
	var nudged := KNUCKLE + Vector3(0.008, 0.0, 0.0)  # ~0.8°, inside the click slop
	_pose(nudged, 0.005)
	await _frames(3)
	check(_last() == [aim[0], aim[1], 1] and _beam_on(nudged),
		"the click slop holds the aim, and the beam still starts at the knuckle")

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
	check(_beam_on(MENU_KNUCKLE), "pointing 45° to the side, the beam still starts at the knuckle and ends on the cursor")
	_pose(MENU_KNUCKLE, 0.005)
	await _frames(5)
	_pose(MENU_KNUCKLE, 0.08)
	await _frames(15)
	check(main.ui == [true, false], "a pinch on the menu presses and releases its button -> %s" % [main.ui])

	# --- Turning the hand turns what it holds -------------------------------
	_pose(BAR_KNUCKLE, 0.08)
	_palm_turn(Basis())
	await _frames(40)
	_pose(BAR_KNUCKLE, 0.005)
	await _frames(3)
	check(main.grabbed == 2, "a pinch on the bar grabs the screen again")
	var held_at := Vector3(0.16, 0.5, -1.5)  # where the ray meets the bar
	var held_local: Vector3 = main.box.to_local(held_at)
	var b0: Basis = main.box.global_basis
	for i in 10:  # a 30° turn of the wrist over 140 ms
		_palm_turn(Basis(Vector3.UP, deg_to_rad(3.0 * (i + 1))))
		await _frames(1)
	await _frames(40)
	var yaw := rad_to_deg(b0.z.signed_angle_to(main.box.global_basis.z, Vector3.UP))
	check(absf(yaw - 30.0) < 2.0, "turning the hand 30° turns the held screen 30° -> %.1f°" % yaw)
	check(main.box.to_global(held_local).distance_to(held_at) < 0.02,
		"about the point held -> %.3f m off" % main.box.to_global(held_local).distance_to(held_at))
	var shoulder := NECK + Vector3(0.16, -0.14, 0.0)
	var sweep := Basis(Vector3.UP, deg_to_rad(20.0))
	_pose(shoulder + sweep * (BAR_KNUCKLE - shoulder), 0.005)
	_palm_turn(sweep * Basis(Vector3.UP, deg_to_rad(30.0)))
	await _frames(60)
	yaw = rad_to_deg(b0.z.signed_angle_to(main.box.global_basis.z, Vector3.UP))
	check(absf(yaw - 50.0) < 3.0, "sweeping the arm 20° (hand turning with it) adds 20°, not 40° -> %.1f°" % yaw)
	_palm_turn(sweep * Basis(Vector3.UP, deg_to_rad(30.0)) * Basis(Vector3.FORWARD, deg_to_rad(20.0)))
	await _frames(40)
	var roll := rad_to_deg(asin(main.box.global_basis.x.normalized().y))
	check(absf(absf(roll) - 20.0) < 3.0, "rolling the hand 20° rolls it -> %.1f°" % roll)
	_pose(shoulder + sweep * (BAR_KNUCKLE - shoulder), 0.08)
	await _frames(15)
	check(main.released == 2, "opening the pinch drops it")
	hand.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM, 0)

	# --- Letting go of a drag does not jolt it ---------------------------------
	_pose(KNUCKLE, 0.08)
	await _frames(40)
	_pose(KNUCKLE, 0.005)
	await _frames(3)
	var dragged_to := KNUCKLE + Vector3(0.1, 0, 0)
	for i in 10:
		_pose(KNUCKLE + Vector3(0.01 * (i + 1), 0, 0), 0.005)
		await _frames(2)
	await _frames(30)
	var before: Array = _last()
	mark = main.sent.size()
	for i in 6:  # the fingers part while the hand jolts 2 cm
		_pose(dragged_to + Vector3(0.02 * (i + 1) / 6.0, 0.0, 0.0), 0.08)
		await _frames(1)
	await _frames(15)
	release = main.sent.slice(mark).filter(func(e): return e[2] == 0)
	check(before[2] == 1 and release.slice(0, 1) == [[before[0], before[1], 0]],
		"the drag ends where it was, not where the parting fingers jolt it -> %s, %s" % [before, release.slice(0, 1)])

	# --- Middle finger: right click and scroll -------------------------------
	_pose(KNUCKLE, 0.08)
	await _frames(40)
	mark = main.sent.size()
	_pose_mid(KNUCKLE, 0.005)
	await _frames(5)
	_pose_mid(KNUCKLE, 0.08)
	await _frames(15)
	var tapped: Array = main.sent.slice(mark)
	check(tapped.any(func(e): return _near(e, aim) and e[2] == 2) and not tapped.any(func(e): return e[2] == 1)
		and _last()[2] == 0, "a short middle pinch right-clicks where the hand points -> %s" % [tapped])
	var wheel_mark: int = main.wheel.size()
	mark = main.sent.size()
	_pose_mid(KNUCKLE, 0.005)
	await _frames(3)
	for i in 20:
		_pose_mid(KNUCKLE + Vector3(0, 0.005 * (i + 1), 0), 0.005)
		await _frames(1)
	await _frames(5)
	var during: Array = main.sent.slice(mark)
	_pose_mid(KNUCKLE + Vector3(0, 0.1, 0), 0.08)
	await _frames(15)
	var units := 0
	for w in main.wheel.slice(wheel_mark):
		units += w[0]
	check(units < -900 and units > -1200, "held and moved 10 cm up, it drags the page up -> %d wheel units" % units)
	check(during.all(func(e): return _near(e, aim) and e[2] == 0), "the pointer holds still and nothing clicks")
	_pose(MENU_KNUCKLE, 0.08)
	await _frames(40)
	_pose_mid(MENU_KNUCKLE, 0.005)
	await _frames(3)
	for i in 20:
		_pose_mid(MENU_KNUCKLE + Vector3(0, -0.005 * (i + 1), 0), 0.005)
		await _frames(1)
	_pose_mid(MENU_KNUCKLE + Vector3(0, -0.1, 0), 0.08)
	await _frames(15)
	check(main.ui_scroll >= 7.0, "on the menu it scrolls the menu -> %d notches" % main.ui_scroll)
	hand.set_hand_joint_flags(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP, 0)

	# --- A fingertip on a panel rests the ray --------------------------------
	_pose(KNUCKLE, 0.08)
	await _frames(40)
	main.touching = true
	mark = main.sent.size()
	_pose(KNUCKLE, 0.005)
	await _frames(5)
	check(not input._laser.visible and main.sent.slice(mark).all(func(e): return e[2] == 0),
		"a fingertip touching a panel: no beam, and the pinch clicks nothing")
	main.touching = false
	_pose(KNUCKLE, 0.08)
	await _frames(40)
	check(input._laser.visible, "lifted away, the hand points again")

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

	# --- A hand that comes back already pinched does not click ---------------
	mark = main.sent.size()
	_pose(KNUCKLE, 0.018)
	hand.has_tracking_data = true
	await _frames(30)
	check(not main.sent.slice(mark).is_empty() and main.sent.slice(mark).all(func(e): return e[2] == 0),
		"a hand back in view already pinched (18 mm) points but does not click")
	_pose(KNUCKLE, 0.08)
	await _frames(15)
	_pose(KNUCKLE, 0.005)
	await _frames(3)
	check(_near(_last(), aim) and _last()[2] == 1, "once it has opened, its pinch clicks")
	_pose(KNUCKLE, 0.08)
	await _frames(15)

	# --- The Pico: hand joints while the controllers are in use ---------------
	# Its runtime reports both hands' joints, source unknown, even while the
	# controllers are held or lying on the desk. Real vr_input.gd controllers.
	hand.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN
	left = _new_hand(&"/user/hand_tracker/left")
	left.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN
	var xr_origin := XROrigin3D.new()
	xr_origin.name = "XROrigin3D"
	main.add_child(xr_origin)
	main.move_child(xr_origin, 0)  # processed before HandInput, as in main.tscn
	var pad := XRControllerTracker.new()
	pad.name = &"right_hand"
	pad.profile = "/interaction_profiles/bytedance/pico4_controller"
	pad.set_pose(&"default", Transform3D(Basis(), CTRL_AT), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	XRServer.add_tracker(pad)
	var ctrl := XRController3D.new()
	ctrl.tracker = &"right_hand"
	var vr := Node.new()
	vr.set_script(load("res://scripts/vr_input.gd"))
	ctrl.add_child(vr)
	xr_origin.add_child(ctrl)
	await _frames(3)  # vr_input builds its laser deferred
	_aim(ctrl, CTRL_TARGET)
	await _hold(ctrl, 6)
	check(_last()[0] < 800 and not input._owns,
		"a held controller has the pointer although hand joints are reported -> %s" % [_last()])

	for round in 3:
		# Held and moving: a hand pinch and a palm tap do nothing.
		_pose(KNUCKLE, 0.08)
		mark = main.sent.size()
		var toggles: int = main.toggles
		await _hold(ctrl, 12)
		_pose(KNUCKLE, 0.005)
		_palm(left, true, palm_at, palm_at.direction_to(EYES), 0.005)
		await _hold(ctrl, 12)
		_pose(KNUCKLE, 0.08)
		_palm(left, true, palm_at, palm_at.direction_to(EYES), 0.08)
		await _hold(ctrl, 24)
		check(not input._owns and not input._laser.visible and main.sent.slice(mark).all(func(e): return e[0] < 800),
			"round %d: controller held: the hand's pinch sends nothing, no hand beam" % round)
		check(main.toggles == toggles and not input._palm_mark.visible,
			"round %d: and the palm menu neither shows nor opens" % round)
		vr._set_trigger_state(true)
		await _hold(ctrl, 2)
		check(_last()[2] == 1 and _last()[0] < 800, "round %d: the controller's trigger clicks where it points -> %s" % [round, _last()])
		vr._set_trigger_state(false)
		await _hold(ctrl, 2)
		check(_last()[2] == 0, "round %d: and lets go" % round)

		# Put down (still for 3 s, or no longer tracked), both hands looking
		# pinched as the Pico reports them on the desk: the pointing hand gets
		# the pointer and points but clicks only once it has opened, and the
		# palm's pinch is no menu tap.
		_pose(KNUCKLE, 0.018)
		_palm(left, true, palm_at, palm_at.direction_to(EYES), 0.005)
		mark = main.sent.size()
		if round == 2:
			pad.invalidate_pose(&"default")
			await _frames(2)
			check(input._owns and not vr.raycast_origin.visible,
				"round 2: a controller that loses tracking is put down at once")
		else:
			await _frames(72 * 3 - 30)
			check(not input._owns, "round %d: 2.6 s still: still the controller's" % round)
			await _frames(36)
			check(input._owns and not vr.raycast_origin.visible,
				"round %d: still for 3 s: the controller hides, the hand has the pointer" % round)
		check(main.sent.slice(mark).all(func(e): return e[2] == 0), "round %d: the already-pinched hand does not click" % round)
		_pose(KNUCKLE, 0.08)
		_palm(left, true, palm_at, palm_at.direction_to(EYES), 0.08)
		await _frames(20)
		check(main.toggles == toggles, "round %d: nor does the palm's pinch, opening, toggle the menu" % round)
		check(_near(_last(), aim) and _last()[2] == 0 and input._laser.visible, "round %d: the hand points -> %s" % [round, _last()])
		_pose(KNUCKLE, 0.005)
		await _frames(3)
		check(_near(_last(), aim) and _last()[2] == 1, "round %d: and its pinch clicks" % round)
		if round == 0:
			_palm(left, true, palm_at, palm_at.direction_to(EYES), 0.005)
			await _frames(5)
			_palm(left, true, palm_at, palm_at.direction_to(EYES), 0.08)
			await _frames(15)
			check(main.toggles == toggles + 1, "round 0: the palm menu works again")

		# Picked up while the hand still pinches: the controller has it in
		# the very next frame and the hand's click is let go on the PC.
		var how: String = ["moved", "trigger pressed, not moved", "tracked again"][round]
		if round == 0:  # lifted by a hand, 1.5 cm a frame: 3 cm is not a pick-up yet
			for i in 2:
				ctrl.position += Vector3(0.0, 0.015, 0.0)
				ctrl.rotate_object_local(Vector3.RIGHT, 0.01)  # a hand tilts what it lifts
				await process_frame
			check(input._owns, "round 0: lifted 3 cm: still the hand's")
		mark = main.sent.size()
		match round:
			0:
				ctrl.position += Vector3(0.0, 0.015, 0.0)
				ctrl.rotate_object_local(Vector3.RIGHT, 0.01)
			1:
				vr._set_trigger_state(true)
			2:
				pad.set_pose(&"default", Transform3D(ctrl.basis, CTRL_AT + Vector3(0.0, 0.05, 0.0)),
					Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		await _frames(1)
		var after: Array = main.sent.slice(mark)
		check(not input._owns and vr.raycast_origin.visible and not input._laser.visible,
			"round %d: picked up (%s): the controller has the pointer at once" % [round, how])
		check(after.any(func(e): return _near(e, aim) and e[2] == 0) and not after.any(func(e): return e[0] > 800 and e[2] == 1),
			"round %d: the hand's click is let go -> %s" % [round, after])
		if round == 1:
			check(after.any(func(e): return e[0] < 800 and e[2] == 1), "round 1: and the trigger clicks there and then")
			vr._set_trigger_state(false)
		_pose(KNUCKLE, 0.08)

	XRServer.remove_tracker(pad)
	XRServer.remove_tracker(left)
	XRServer.remove_tracker(hand)
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
