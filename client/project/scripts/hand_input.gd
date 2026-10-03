## Hand-tracking input for Immersive-2 (Pico 4 + SteamVR + Quest).
##
## Lets the user drive the virtual desktop with bare hands — no controllers:
##   • Pointing hand (main.gd's pointer_hand, right by default) — point with
##     the arm; pinch (thumb + index) = left click, hold-and-move = click-drag,
##     on the screens, the menu and the keyboard, whichever is nearest along
##     the ray (main.gd::pick). A pinch on the bar under a screen, the menu or
##     the keyboard moves it until the pinch opens; reaching out / pulling the
##     hand in pushes it away / brings it closer (LaserDrag). A pinch on a
##     screen itself always stays a mouse click or drag, however long.
##   • Either hand — touch the whiteboard with the index fingertip to draw on
##     it (main.gd's whiteboard_touch); while it does, the pointing hand's ray
##     rests.
##   • Other hand — turn its palm towards your face and a menu mark shows next
##     to it; a short pinch toggles the menu (as on the Quest). A long pinch is
##     left to the headset's own gestures.
##
## Everything comes from the finger joints (XR_EXT_hand_tracking, Godot's
## XRHandTracker, looked up every frame). The ray runs from an estimated
## shoulder through the index knuckle and the beam starts at that knuckle; the
## shoulder hangs off the body rather than the head (see _shoulder_ray()).
##
## A controller in use always wins: the hands only get the pointer while
## vr_input.gd's any_in_use() is false (every controller put down or not
## tracked). The Pico reports hand joints (source unknown) even while the
## controllers are held or lying on the desk, so the joints alone decide
## nothing. A pinch that is already closed when the hands get the pointer
## must open before it clicks.
##
## Requirements:
##   • project setting  xr/openxr/extensions/hand_tracking = true  (project.godot)
##   • Pico:  <meta-data android:name="handtracking" android:value="1"/> in the
##            Android manifest (added by addons/im2_decoder/im2_decoder.gd)
##   • Quest: export preset xr_features/hand_tracking >= 1

extends Node

const VRInput := preload("res://scripts/vr_input.gd")

## Thumb-tip to index-tip distance that starts a pinch, and the wider one that
## ends it (the gap keeps a half-closed pinch from flickering).
const PINCH_PRESS_M := 0.02
const PINCH_RELEASE_M := 0.035
## The pinch must look open this long before it lets go. Pico drops or jolts
## the finger tips for a frame or two mid-pinch (the thumb hides behind the
## index), which used to release the click after ~30 ms and re-press it.
const PINCH_RELEASE_HOLD_S := 0.12
## Fallback ray: neck pivot from the eyes (head space, +Z = back) and the
## shoulder from the neck (torso space, X mirrored for the left hand). The
## neck pivot does not move when the head turns or nods, and the torso keeps
## its yaw until the head turns more than TORSO_FOLLOW_RAD (~35°) away, so
## looking around never swings the ray.
const NECK_OFFSET := Vector3(0.0, -0.08, 0.10)
const SHOULDER_OFFSET := Vector3(0.16, -0.14, 0.0)
const TORSO_FOLLOW_RAD := 0.61
## One Euro filter on the ray direction (a unit vector, so speed ~ rad/s):
## steady when the hand is still, little lag when it moves. At 72 Hz it trails
## a steady sweep by ~41 ms at 5°/s, 28 ms at 10°/s, 9 ms at 60°/s and keeps
## ~27 % of the knuckle's jitter (hand_input_test.gd measures both; the old
## 1.0 / 4.0 kept the same jitter and trailed by 57 / 42 / 16 ms). Raise BETA
## if it trails, lower MIN_CUTOFF if it shakes at rest.
const FILTER_MIN_CUTOFF := 0.5
const FILTER_BETA := 10.0
## A pinch holds the ray still until the hand moves this far (~1.5°), so a click
## never turns into a tiny drag (breaks double-clicks, selects text).
const CLICK_SLOP_RAD := 0.026
const MAX_RAY_LENGTH := 8.0
## Palm menu: the palm faces the eyes within ~53° and the eyes look at it
## within ~41°; the mark floats this far off the palm; a pinch held longer
## than MENU_TAP_MAX_S is not a tap (the headset's own long-pinch gestures).
const PALM_FACING_COS := 0.6
const PALM_LOOK_COS := 0.75
const PALM_MARK_OFFSET_M := 0.05
const MENU_TAP_MAX_S := 0.7

@onready var main_scene: Node = get_node_or_null("/root/Main")
@onready var xr_origin: XROrigin3D = get_node_or_null("/root/Main/XROrigin3D")

# Pointing-hand state.
var _point_left: bool = false       # the left hand points (main.gd pointer_hand)
var _pinch_active: bool = false     # button held down on a target
var _point_pinching: bool = false   # fingers pinched (with hysteresis)
var _point_armed: bool = false      # seen open since the hand got the pointer
var _point_tracked: bool = false
var _owns: bool = false             # no controller in use: the hands point
var _knuckle: Vector3 = Vector3.ZERO  # where the beam starts this frame
var _press_origin: Vector3 = Vector3.ZERO
var _press_dir: Vector3 = Vector3.FORWARD
var _dragging: bool = false
var _on_overlay: bool = false
var _last_monitor_id: int = 0
var _last_pixel: Vector2i = Vector2i.ZERO
## Screen, menu or keyboard moved by a pinch on its bar, and the node that
## carries the ray for LaserDrag.
var _grab: Node = null
var _ray_node: Node3D = null

# One Euro filter state for the ray direction (ZERO = start over).
var _dir_filtered: Vector3 = Vector3.ZERO
var _dir_rate: Vector3 = Vector3.ZERO
var _torso_yaw: float = NAN

# Other hand: palm menu.
var _menu_pinching: bool = false
var _menu_armed: bool = false       # the pinch began on the shown mark
var _menu_pinch_s: float = 0.0
var _open_s: Dictionary = {}  # left (bool) -> seconds its pinch has looked open

# Visuals, created lazily in the world: laser beam + cursor dot, palm mark.
var _laser: MeshInstance3D = null
var _cursor: MeshInstance3D = null
var _palm_mark: Node3D = null
var _palm_mark_mat: StandardMaterial3D = null

var _logged: Dictionary = {}  # what was last printed, per key

func _ready() -> void:
	set_process(true)

func _exit_tree() -> void:
	for n in [_laser, _cursor, _ray_node, _palm_mark]:
		if is_instance_valid(n):
			n.queue_free()

func _process(delta: float) -> void:
	_log_runtime()
	var left_points: bool = main_scene != null and main_scene.get("pointer_hand") == "left"
	if left_points != _point_left:
		_let_go()
		_point_left = left_points
		_menu_pinching = false
		_menu_armed = false

	# Decided afresh every frame, so picking a controller up or putting both
	# down switches at once, back and forth, with nothing to get stuck.
	var owns := not VRInput.any_in_use()
	if owns != _owns:
		_owns = owns
		print("[HandInput] %s" % ("Controllers put down: hands point" if owns else "Controller in use: hands ignored"))
	if not owns:
		_let_go()
		_point_tracked = false
		_menu_pinching = true  # a pinch held across the switch is no tap
		_menu_armed = false
		_show_palm_mark({}, false)
		return

	var tracked := _has_hand(_point_left)
	if tracked != _point_tracked:
		_point_tracked = tracked
		print("[HandInput] %s hand %s" % ["Left" if _point_left else "Right", "tracked" if tracked else "lost"])
	if tracked and _touch_board(_point_left):
		_let_go()  # the fingertip draws: no ray meanwhile
	elif tracked:
		_process_pointing_hand(delta)
	else:
		_let_go()
	if _has_hand(not _point_left):
		_touch_board(not _point_left)

	_process_menu_hand(not _point_left, delta)

## The index fingertip of one hand on (or just in front of) the whiteboard.
func _touch_board(left: bool) -> bool:
	var tracker := hand_tracker(left)
	var tip := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	if not main_scene or not main_scene.has_method("whiteboard_touch") \
			or not _joint_has_valid_position(tracker, tip):
		return false
	return main_scene.whiteboard_touch(int(left), _joint_world_position(tracker, tip))

## The joint tracker of one hand. Looked up every time: Godot replaces it when
## the OpenXR session restarts, and a kept reference would go silently stale.
static func hand_tracker(left: bool) -> XRHandTracker:
	return XRServer.get_tracker(&"/user/hand_tracker/left" if left else &"/user/hand_tracker/right") as XRHandTracker

## The runtime reports this hand's joints, and not as copied from a controller.
## (The Pico says "unknown" for both, hence the controllers' say above.)
func _has_hand(left: bool) -> bool:
	var h := hand_tracker(left)
	return h != null and h.has_tracking_data and h.hand_tracking_source in [
		XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED, XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN]

## The pointing hand went away: drop what it holds, release any click. The
## torso is guessed afresh when it comes back (after a recenter or a turn),
## and a pinch must be seen open before it clicks again.
func _let_go() -> void:
	_point_pinching = false
	_point_armed = false
	_torso_yaw = NAN
	_drop_grab()
	_end_pinch_if_active()
	_hide_pointer_visual()

func _drop_grab() -> void:
	if _grab != null:
		LaserDrag.drop(_grab, main_scene)
	_grab = null

# ---------------------------------------------------------------------------
# Pointing hand
# ---------------------------------------------------------------------------

func _process_pointing_hand(delta: float) -> void:
	var tracker := hand_tracker(_point_left)
	var ray := _shoulder_ray(tracker, _point_left)
	if ray.is_empty():
		_let_go()
		return
	var origin: Vector3 = ray.origin
	var direction := _filter_direction(ray.direction, delta)
	_knuckle = origin

	# A pinch already closed when the hand got the pointer (or came back into
	# view) is not a click: the Pico reports a pinched hand for a controller
	# lying on the desk. It must open first.
	var pinching := _is_pinching(_point_left, _point_pinching, delta)
	if not pinching:
		_point_armed = true
	var should_press := pinching and _point_armed
	var pressed_now := should_press and not _point_pinching
	if should_press != _point_pinching:
		print("[HandInput] Pinch %s (%d mm)" % ["DOWN" if should_press else "UP", _pinch_distance(tracker) * 1000.0])
		if should_press:
			_press_origin = origin
			_press_dir = direction
			_dragging = false
	# Hold the ray where the pinch started (release frame included) until the
	# hand clearly moves away: that is a drag, not a shaky click.
	if (should_press or _point_pinching) and not _dragging:
		if direction.angle_to(_press_dir) > CLICK_SLOP_RAD:
			_dragging = true
		else:
			origin = _press_origin
			direction = _press_dir
	_point_pinching = should_press
	_ensure_pointer_visual()
	if is_instance_valid(_ray_node):
		var up := Vector3.RIGHT if absf(direction.dot(Vector3.UP)) > 0.99 else Vector3.UP
		_ray_node.global_transform = Transform3D(Basis.looking_at(direction, up), origin)

	# A pinch that grabbed a bar moves that thing until the fingers open.
	if _grab != null:
		if should_press and is_instance_valid(_grab):
			var held: float = _grab.get_drag_distance() if _grab.has_method("get_drag_distance") else 1.0
			_update_pointer_visual(origin, direction, held, true)
			return
		_drop_grab()

	if not main_scene or not main_scene.has_method("pick"):
		_hide_pointer_visual()
		return
	var hit: Dictionary = main_scene.pick(origin, direction)
	var kind: String = hit.get("kind", "")
	if kind != "keyboard" and main_scene.has_method("leave_keyboard"):
		main_scene.leave_keyboard()
	if kind != "whiteboard" and main_scene.has_method("leave_whiteboard"):
		main_scene.leave_whiteboard()

	if kind == "overlay":
		_handle_overlay_hit(hit, should_press, origin, direction)
		return
	# Pointer left the overlay — release any held overlay click.
	if _on_overlay:
		if _pinch_active and main_scene.has_method("send_ui_pointer_button"):
			main_scene.send_ui_pointer_button(false, MOUSE_BUTTON_LEFT)
		_on_overlay = false
		_pinch_active = false

	match kind:
		"keyboard":
			main_scene.send_keyboard_pointer(origin, direction, should_press)
			_pinch_active = should_press
			_update_pointer_visual(origin, direction, hit.distance, true)
		"whiteboard":
			_end_pinch_if_active()
			main_scene.send_whiteboard_pointer(origin, direction, should_press)
			_update_pointer_visual(origin, direction, hit.distance, true)
		"bar":
			_end_pinch_if_active()
			if is_instance_valid(hit.get("bar")):
				hit.bar.mark_hovered()
			if pressed_now and LaserDrag.grab(hit.target, _ray_node, hit.distance, main_scene):
				_grab = hit.target
				_dragging = true  # from now on the ray follows the hand: no click slop
			_update_pointer_visual(origin, direction, hit.distance, true)
		"panel":
			_point_at_panel(hit, should_press, origin, direction)
		_:
			_end_pinch_if_active()
			_update_pointer_visual(origin, direction, MAX_RAY_LENGTH, false)

## Mouse on the PC: the pinch is the left button, however long it is held.
func _point_at_panel(hit: Dictionary, should_press: bool, origin: Vector3, direction: Vector3) -> void:
	var panel = hit.get("panel", null)
	if panel == null or not panel.has_method("uv_to_pixel"):
		_update_pointer_visual(origin, direction, MAX_RAY_LENGTH, false)
		return

	var uv: Vector2 = hit.get("uv", Vector2(0.5, 0.5))
	var pixel: Vector2i = panel.uv_to_pixel(uv)
	if panel.has_method("mark_hovered"):
		panel.mark_hovered()
	var monitor_id: int = hit.get("monitor_id", 0)

	if main_scene.has_method("send_mouse_input"):
		main_scene.send_mouse_input(
			monitor_id,
			pixel.x,
			pixel.y,
			0x01 if should_press else 0,
			0)

	_pinch_active = should_press
	_last_monitor_id = monitor_id
	_last_pixel = pixel
	_update_pointer_visual(origin, direction, hit.get("distance", MAX_RAY_LENGTH), true)

## Drive the in-VR overlay menu with the hand pointer.
func _handle_overlay_hit(ui_hit: Dictionary, should_press: bool, origin: Vector3, direction: Vector3) -> void:
	_on_overlay = true
	var uv: Vector2 = ui_hit.get("uv", Vector2(0.5, 0.5))
	if main_scene.has_method("send_ui_pointer_move"):
		main_scene.send_ui_pointer_move(uv)
	if should_press != _pinch_active:
		if main_scene.has_method("send_ui_pointer_button"):
			main_scene.send_ui_pointer_button(should_press, MOUSE_BUTTON_LEFT)
		_pinch_active = should_press
	_update_pointer_visual(origin, direction, ui_hit.get("distance", 1.5), true)

## Release a held pinch (mouse button up / overlay button up) when tracking is
## lost or the pointer leaves every target.
func _end_pinch_if_active() -> void:
	if not _pinch_active:
		return
	if _on_overlay:
		if main_scene and main_scene.has_method("send_ui_pointer_button"):
			main_scene.send_ui_pointer_button(false, MOUSE_BUTTON_LEFT)
	elif main_scene and main_scene.has_method("send_mouse_input"):
		main_scene.send_mouse_input(_last_monitor_id, _last_pixel.x, _last_pixel.y, 0, 0)
	_pinch_active = false
	_on_overlay = false

# ---------------------------------------------------------------------------
# Other hand: palm menu
# ---------------------------------------------------------------------------

## Palm towards the face shows the mark; a short pinch while it shows toggles
## the menu (on release, so a long hold stays the headset's own gesture).
func _process_menu_hand(left: bool, delta: float) -> void:
	var tracked := _has_hand(left)
	var palm := _palm_towards_eyes(hand_tracker(left), left) if tracked else {}
	var was := _menu_pinching
	_menu_pinching = tracked and _is_pinching(left, _menu_pinching, delta)
	if _menu_pinching and not was:
		_menu_armed = not palm.is_empty()
		_menu_pinch_s = 0.0
	elif _menu_pinching:
		_menu_pinch_s += delta
		if _menu_pinch_s > MENU_TAP_MAX_S:
			_menu_armed = false
	elif not tracked:
		_menu_armed = false  # the hand vanished mid-pinch: not a tap
	elif was and _menu_armed:
		_menu_armed = false
		print("[HandInput] Palm menu tapped")
		if main_scene and main_scene.has_method("toggle_ui_overlay"):
			main_scene.toggle_ui_overlay()
	_show_palm_mark(palm, _menu_pinching and _menu_armed)

## {center, normal} of the palm when it faces the eyes and they look at it,
## else {}. The normal comes from joint positions only (wrist, index and
## little-finger knuckles), so no joint-axis convention can flip it.
func _palm_towards_eyes(tracker: XRHandTracker, left: bool) -> Dictionary:
	var head := get_viewport().get_camera_3d()
	var wrist := XRHandTracker.HAND_JOINT_WRIST
	var index := XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL
	var little := XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL
	if head == null or tracker == null or not tracker.has_tracking_data:
		return {}
	for j in [wrist, index, little]:
		if not _joint_has_valid_position(tracker, j):
			return {}
	var w := _joint_world_position(tracker, wrist)
	var i := _joint_world_position(tracker, index)
	var l := _joint_world_position(tracker, little)
	var normal := (i - w).cross(l - w).normalized() * (-1.0 if left else 1.0)
	var center := w.lerp((i + l) * 0.5, 0.5)
	if _joint_has_valid_position(tracker, XRHandTracker.HAND_JOINT_PALM):
		center = _joint_world_position(tracker, XRHandTracker.HAND_JOINT_PALM)
	var to_eyes := (head.global_position - center).normalized()
	if normal.dot(to_eyes) < PALM_FACING_COS or (-head.global_basis.z).dot(-to_eyes) < PALM_LOOK_COS:
		return {}
	return {"center": center, "normal": normal}

## A small three-bar menu mark floating off the palm, facing the eyes; dimmer
## while the pinch on it is held.
func _show_palm_mark(palm: Dictionary, pressed: bool) -> void:
	if palm.is_empty() and not pressed:
		if is_instance_valid(_palm_mark):
			_palm_mark.visible = false
		return
	if not is_instance_valid(_palm_mark):
		if not (main_scene is Node3D):
			return
		_palm_mark_mat = StandardMaterial3D.new()
		_palm_mark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var bar := CapsuleMesh.new()  # rounded ends, 22 x 2.8 mm
		bar.radius = 0.0014
		bar.height = 0.022
		bar.radial_segments = 8
		bar.rings = 2
		_palm_mark = Node3D.new()
		_palm_mark.name = "PalmMenuMark"
		for k in 3:
			var m := MeshInstance3D.new()
			m.mesh = bar
			m.material_override = _palm_mark_mat
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			m.rotation.z = PI / 2.0
			m.position.y = 0.0065 * (k - 1)
			_palm_mark.add_child(m)
		main_scene.add_child(_palm_mark)
	_palm_mark_mat.albedo_color = UiTheme.INK_3 if pressed else UiTheme.INK
	_palm_mark.visible = true
	if palm.is_empty():
		return  # pressed: stays where it was while the hand turns a little
	var pos: Vector3 = palm.center + palm.normal * PALM_MARK_OFFSET_M
	var eyes := get_viewport().get_camera_3d().global_position
	_palm_mark.global_transform = Transform3D(Basis.looking_at(eyes - pos), pos)

# ---------------------------------------------------------------------------
# Ray / pinch math
# ---------------------------------------------------------------------------

## {origin, direction} of the ray from the estimated shoulder through the index
## knuckle, or {} when there is none. It follows the arm, not the finger, so
## curling the index into a pinch does not move it; and the shoulder hangs off
## a neck pivot and a lazy torso yaw, so turning or tilting the head does not
## move it either.
func _shoulder_ray(tracker: XRHandTracker, left: bool) -> Dictionary:
	var knuckle_joint := XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL
	var head := get_viewport().get_camera_3d()
	if head == null or not _joint_has_valid_position(tracker, knuckle_joint):
		return {}
	var knuckle := _joint_world_position(tracker, knuckle_joint)
	var head_basis := head.global_basis.orthonormalized()
	var neck := head.global_position + head_basis * NECK_OFFSET
	var side := Vector3(-1.0 if left else 1.0, 1.0, 1.0)
	var shoulder := neck + Basis(Vector3.UP, _update_torso_yaw(head_basis)) * (SHOULDER_OFFSET * side)
	var direction := knuckle - shoulder
	if direction.length() < 0.01:
		return {}
	return {"origin": knuckle, "direction": direction.normalized()}

## The body's yaw, dragged along only by head turns past TORSO_FOLLOW_RAD.
func _update_torso_yaw(head_basis: Basis) -> float:
	var forward := -head_basis.z
	forward.y = 0.0
	if forward.length() > 0.3:  # not looking straight up or down
		var yaw := atan2(-forward.x, -forward.z)
		if is_nan(_torso_yaw):
			_torso_yaw = yaw
		var d := angle_difference(_torso_yaw, yaw)
		if absf(d) > TORSO_FOLLOW_RAD:
			_torso_yaw = wrapf(_torso_yaw + d - signf(d) * TORSO_FOLLOW_RAD, -PI, PI)
	return 0.0 if is_nan(_torso_yaw) else _torso_yaw

## One Euro filter (Casiez et al. 2012) on the ray direction: the cutoff rises
## with speed, so slow aiming is smoothed hard and fast sweeps barely lag.
func _filter_direction(direction: Vector3, delta: float) -> Vector3:
	if _dir_filtered == Vector3.ZERO or delta <= 0.0:
		_dir_filtered = direction
		_dir_rate = Vector3.ZERO
		return direction
	_dir_rate = _dir_rate.lerp((direction - _dir_filtered) / delta, _euro_alpha(1.0, delta))
	var cutoff := FILTER_MIN_CUTOFF + FILTER_BETA * _dir_rate.length()
	_dir_filtered = _dir_filtered.lerp(direction, _euro_alpha(cutoff, delta)).normalized()
	return _dir_filtered

static func _euro_alpha(cutoff: float, delta: float) -> float:
	return 1.0 / (1.0 + 1.0 / (TAU * cutoff * delta))

## Thumb and index tips together, with hysteresis on `was_pinching` and a
## short hold before letting go (see PINCH_RELEASE_HOLD_S).
func _is_pinching(left: bool, was_pinching: bool, delta: float) -> bool:
	var dist := _pinch_distance(hand_tracker(left))
	if dist < 0.0:
		return was_pinching  # tips not tracked this frame: keep what we had
	if dist < (PINCH_RELEASE_M if was_pinching else PINCH_PRESS_M):
		_open_s[left] = 0.0
		return true
	_open_s[left] = _open_s.get(left, 0.0) + delta
	return was_pinching and _open_s[left] < PINCH_RELEASE_HOLD_S

## Thumb-tip to index-tip distance in metres, or -1 when either is not tracked.
func _pinch_distance(tracker: XRHandTracker) -> float:
	var thumb := XRHandTracker.HAND_JOINT_THUMB_TIP
	var index := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	if not (_joint_has_valid_position(tracker, thumb) and _joint_has_valid_position(tracker, index)):
		return -1.0
	return tracker.get_hand_joint_transform(thumb).origin.distance_to(
		tracker.get_hand_joint_transform(index).origin)

func _joint_has_valid_position(tracker: XRHandTracker, joint: int) -> bool:
	if tracker == null or not tracker.has_tracking_data:
		return false
	var flags: int = tracker.get_hand_joint_flags(joint)
	return (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0

func _joint_world_position(tracker: XRHandTracker, joint: int) -> Vector3:
	return _to_world(tracker.get_hand_joint_transform(joint)).origin

## Tracking space (relative to XROrigin3D) to world.
func _to_world(t: Transform3D) -> Transform3D:
	return xr_origin.global_transform * t if xr_origin else t

# ---------------------------------------------------------------------------
# Logging: what the runtime reports, printed when it changes (adb logcat -s godot)
# ---------------------------------------------------------------------------

func _log_runtime() -> void:
	var xr := XRServer.find_interface("OpenXR")
	if xr and xr.is_initialized():
		_log_once("support", "[HandInput] OpenXR hand tracking %s" % xr.is_hand_tracking_supported())
	for left in [true, false]:
		var h := hand_tracker(left)
		_log_once(left, "[HandInput] %s hand joints %s (source %d)" % [
			"left" if left else "right",
			"tracked" if h and h.has_tracking_data else ("none" if h == null else "-"),
			h.hand_tracking_source if h else -1])

func _log_once(key: Variant, line: String) -> void:
	if _logged.get(key) != line:
		_logged[key] = line
		print(line)

# ---------------------------------------------------------------------------
# Visual pointer (laser beam + cursor dot)
# ---------------------------------------------------------------------------

func _ensure_pointer_visual() -> void:
	if is_instance_valid(_laser):
		return
	if not is_instance_valid(main_scene) or not (main_scene is Node3D):
		return

	_laser = MeshInstance3D.new()
	var beam := BoxMesh.new()
	beam.size = Vector3(0.0024, 0.0024, 1.0)  # 1 m on Z, scaled per-frame to ray length
	_laser.mesh = beam
	_laser.material_override = _make_emissive_material(Color(0.93, 0.92, 0.88, 0.4), true)
	_laser.visible = false
	main_scene.add_child(_laser)

	_cursor = MeshInstance3D.new()
	var dot := SphereMesh.new()
	dot.radius = 0.0065
	dot.height = 0.013
	_cursor.mesh = dot
	_cursor.material_override = _make_emissive_material(Color(0.93, 0.92, 0.88, 1.0), false)
	_cursor.visible = false
	main_scene.add_child(_cursor)

	_ray_node = Node3D.new()
	_ray_node.name = "HandRay"
	main_scene.add_child(_ray_node)

func _make_emissive_material(color: Color, transparent: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b)
	mat.emission_energy_multiplier = 1.5
	if transparent:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat

func _update_pointer_visual(origin: Vector3, direction: Vector3, distance: float, hit: bool) -> void:
	_ensure_pointer_visual()
	if not is_instance_valid(_laser):
		return

	var end := origin + direction * clampf(distance, 0.05, MAX_RAY_LENGTH)
	# The beam starts at the knuckle as it is now, also while the aim is held
	# where a pinch began (the click slop moves `origin` a little off it).
	var beam := end - _knuckle
	if beam.length() < 0.01:
		beam = direction * 0.01
	var up := Vector3.RIGHT if absf(beam.normalized().dot(Vector3.UP)) > 0.99 else Vector3.UP
	# Stretch the 1 m box along its own axis. (Basis.scaled() stretches world Z,
	# which bent the beam off the hand whenever it pointed sideways or down.)
	var oriented := Basis.looking_at(beam, up) * Basis.from_scale(Vector3(1.0, 1.0, beam.length()))
	_laser.global_transform = Transform3D(oriented, _knuckle.lerp(end, 0.5))
	_laser.visible = hit  # a beam into empty space is just noise

	_cursor.visible = hit
	if hit:
		_cursor.global_transform = Transform3D(Basis(), end)

func _hide_pointer_visual() -> void:
	if is_instance_valid(_laser):
		_laser.visible = false
	if is_instance_valid(_cursor):
		_cursor.visible = false
	_dir_filtered = Vector3.ZERO
