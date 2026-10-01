## Moving a floating object (screen, menu, keyboard) with a pointer ray.
##
## The point that was grabbed stays `distance` metres along the ray, so the
## object swings with the pointer instead of copying every twist of the wrist.
## That distance follows push_pull() (the stick) and the hand itself: reaching
## out pushes the object away and pulling the hand in brings it closer,
## amplified like the Quest system UI. The object never rolls; it turns to
## face the head, or with `face_me` off keeps the yaw it had relative to the
## pointer. A light filter takes the hand's tremor out, and followers (the
## rest of a screen group) move rigidly with it.

extends RefCounted
class_name LaserDrag

const MIN_DISTANCE := 0.3
const MAX_DISTANCE := 8.0
## Metres along the ray per metre the hand moves away from the shoulder.
const REACH_GAIN := 3.5
## The shoulder is guessed from the head, as in hand_input.gd.
const SHOULDER_DOWN_M := 0.18
const SHOULDER_SIDE_M := 0.17
## Time constant of the smoothing filter.
const SMOOTH_S := 0.05

## main.gd's "Screens turn to face me while moving" setting.
static var face_me := true

var target: Node3D
var pointer: Node3D
var distance: float = 1.0
## Target origin relative to the grabbed point, in the target's own basis.
var _offset_local := Vector3.ZERO
var _reach := 0.0
var _side := 1.0          ## which shoulder: +1 right, -1 left
var _front := Vector3.BACK ## target's +Z when grabbed
var _yaw0 := 0.0          ## pointer yaw when grabbed
var _followers: Array = [] ## [node, transform relative to target]

## Start moving `thing` with `pointer`; false when it cannot move (not
## draggable, or a screen while main.gd says the layout is locked).
static func grab(thing: Node, p_pointer: Node3D, hit_distance: float, main: Node) -> bool:
	if not is_instance_valid(thing) or not thing.has_method("start_drag"):
		return false
	if thing.has_method("ray_to_screen_hit") and main and main.has_method("can_move_panel") \
			and not main.can_move_panel(thing):
		return false
	thing.start_drag(p_pointer, hit_distance)
	return true

## Let go of `thing`; a screen then gets main.gd's snapping, and the layout is saved.
static func drop(thing: Node, main: Node) -> void:
	if not is_instance_valid(thing):
		return
	thing.stop_drag()
	if not main:
		return
	if thing.has_method("ray_to_screen_hit") and main.has_method("on_panel_drag_ended"):
		main.on_panel_drag_ended(thing)
	if main.has_method("on_layout_changed"):
		main.on_layout_changed()

## `pointer` casts its ray along -Z; it hit `target` `hit_distance` away
## (<= 0: use the distance to the target's origin).
func _init(p_target: Node3D, p_pointer: Node3D, hit_distance: float = -1.0) -> void:
	target = p_target
	pointer = p_pointer
	if hit_distance <= 0.0:
		hit_distance = pointer.global_position.distance_to(target.global_position)
	distance = clampf(hit_distance, MIN_DISTANCE, MAX_DISTANCE)
	_offset_local = target.global_basis.inverse() * (target.global_position - _grab_point())
	var cam := _camera()
	if cam:
		_side = 1.0 if (pointer.global_position - cam.global_position).dot(cam.global_basis.x) >= 0.0 else -1.0
	_reach = _reach_now()
	_front = target.global_basis.z
	_yaw0 = _pointer_yaw()

## Other objects that move rigidly with the target (the rest of its group).
func add_followers(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n) and n != target:
			_followers.append([n, target.global_transform.affine_inverse() * n.global_transform])

func is_valid() -> bool:
	return is_instance_valid(target) and is_instance_valid(pointer)

## Call every frame while the grab lasts (delta 0: no smoothing).
func update(delta: float = 0.0) -> void:
	if not is_valid():
		return
	var reach := _reach_now()
	push_pull((reach - _reach) * REACH_GAIN)
	_reach = reach
	var grab_at := _grab_point()
	var basis: Basis
	if face_me:
		var cam := _camera()
		basis = facing_basis(grab_at, cam.global_position if cam else pointer.global_position)
	else:
		basis = facing_basis(grab_at, grab_at + _front.rotated(Vector3.UP, _pointer_yaw() - _yaw0))
	var want := Transform3D(basis, grab_at + basis * _offset_local)
	var k := 1.0 if delta <= 0.0 else 1.0 - exp(-delta / SMOOTH_S)
	var t := target.global_transform.interpolate_with(want, k)
	target.global_transform = Transform3D(facing_basis(t.origin, t.origin + t.basis.z), t.origin)
	for f in _followers:
		if is_instance_valid(f[0]):
			f[0].global_transform = target.global_transform * f[1]

func push_pull(delta_m: float) -> void:
	distance = clampf(distance + delta_m, MIN_DISTANCE, MAX_DISTANCE)

func _grab_point() -> Vector3:
	return pointer.global_position - pointer.global_basis.z.normalized() * distance

func _camera() -> Camera3D:
	return target.get_viewport().get_camera_3d() if target.is_inside_tree() else null

## Hand (pointer) to estimated shoulder distance; 0 without a head to guess from.
func _reach_now() -> float:
	var cam := _camera()
	if not cam:
		return 0.0
	var right := cam.global_basis.x
	right.y = 0.0
	var shoulder := cam.global_position + Vector3.DOWN * SHOULDER_DOWN_M \
		+ right.normalized() * SHOULDER_SIDE_M * _side
	return pointer.global_position.distance_to(shoulder)

func _pointer_yaw() -> float:
	var f := -pointer.global_basis.z
	return atan2(-f.x, -f.z)

## Upright basis whose +Z (the front of screens, menu and keyboard) points
## from `pos` towards `look_from`: yaw and pitch only, never roll.
static func facing_basis(pos: Vector3, look_from: Vector3) -> Basis:
	var z := look_from - pos
	if z.length_squared() < 0.0001:
		z = Vector3.BACK
	z = z.normalized()
	var x := Vector3.UP.cross(z)
	if x.length_squared() < 0.0001:
		x = Vector3.RIGHT
	x = x.normalized()
	return Basis(x, z.cross(x), z)
