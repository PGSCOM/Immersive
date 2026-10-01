## Moving a floating object (screen, menu, keyboard) with a pointer ray.
##
## Default: the object is locked to the pointer. Whatever transform it had
## relative to the pointer when grabbed (position AND rotation, roll
## included) stays constant, so it follows the controller on every axis.
## That distance along the ray follows push_pull() (the stick) and the hand
## itself: reaching out pushes the object away and pulling the hand in brings
## it closer, amplified like the Quest system UI. A screen that comes within
## LEVEL_DEG of upright / vertical eases flat, so it is easy to leave level.
##
## With `face_me` on, the grabbed point stays on the ray instead and the
## object turns to face the head (yaw and pitch only, never roll).
## A light filter takes the hand's tremor out, and followers (the rest of a
## screen group) move rigidly with it.

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
## Roll and pitch within this many degrees of level are flattened while moving.
const LEVEL_DEG := 4.0

## main.gd's "Screens face me while moving" setting; off = locked to the pointer.
static var face_me := false

var target: Node3D
var pointer: Node3D
var distance: float = 1.0
## Target origin relative to the grabbed point, in the target's own basis.
var _offset_local := Vector3.ZERO
## Target transform in the pointer's frame when grabbed, and the distance then.
var _rel := Transform3D.IDENTITY
var _d0 := 1.0
var _reach := 0.0
var _side := 1.0          ## which shoulder: +1 right, -1 left
var _followers: Array = [] ## [node, transform relative to target]

## Start moving `thing` with `pointer`; false when it cannot move (not
## draggable, or a screen or its resize handle while main.gd says the layout
## is locked). Anything with start_drag / stop_drag / get_drag_distance can be
## grabbed: a ResizeHandle uses the same calls to resize its screen.
static func grab(thing: Node, p_pointer: Node3D, hit_distance: float, main: Node) -> bool:
	if not is_instance_valid(thing) or not thing.has_method("start_drag"):
		return false
	if (thing.has_method("ray_to_screen_hit") or thing.has_method("is_resize_handle")) \
			and main and main.has_method("can_move_panel") \
			and not main.can_move_panel(thing):
		return false
	thing.start_drag(p_pointer, hit_distance)
	return true

## Let go of `thing`; a screen then snaps to the side main.gd's preview showed, and the layout is saved.
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
	_rel = pointer.global_transform.orthonormalized().affine_inverse() * target.global_transform
	_d0 = distance

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
	var want: Transform3D
	var k := 1.0 if delta <= 0.0 else 1.0 - exp(-delta / SMOOTH_S)
	if face_me:
		var grab_at := _grab_point()
		var cam := _camera()
		var basis := facing_basis(grab_at, cam.global_position if cam else pointer.global_position)
		want = Transform3D(basis, grab_at + basis * _offset_local)
	else:
		var rel := _rel
		rel.origin.z -= distance - _d0  # pushed along the ray
		want = pointer.global_transform.orthonormalized() * rel
		want.basis = level_basis(want.basis)
	var t := target.global_transform.interpolate_with(want, k)
	target.global_transform = Transform3D(facing_basis(t.origin, t.origin + t.basis.z) if face_me \
		else t.basis.orthonormalized(), t.origin)
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

## `b` with roll flattened when within LEVEL_DEG of upright and pitch flattened
## when within LEVEL_DEG of vertical (its front axis +Z is kept otherwise).
static func level_basis(b: Basis) -> Basis:
	var s := sin(deg_to_rad(LEVEL_DEG))
	var z := b.z.normalized()
	var x := b.x.normalized()
	var roll_level := absf(x.y) < s
	if absf(z.y) < s:
		z.y = 0.0
		if z.length_squared() < 0.0001:
			return b
		z = z.normalized()
	x = Vector3.UP.cross(z).normalized() if roll_level and absf(z.y) < 0.99 \
		else (x - z * x.dot(z)).normalized()
	return Basis(x, z.cross(x), z)
