## Moving a floating object (screen, menu, keyboard) with a pointer ray.
##
## The point that was grabbed stays `distance` metres along the ray, so the
## object swings with the pointer instead of copying every twist of the wrist;
## it keeps facing the head and never rolls. push_pull() moves it along the ray.

extends RefCounted
class_name LaserDrag

const MIN_DISTANCE := 0.3
const MAX_DISTANCE := 6.0

var target: Node3D
var pointer: Node3D
var distance: float = 1.0
## Target origin relative to the grabbed point, in the target's own basis.
var _offset_local := Vector3.ZERO

## `pointer` casts its ray along -Z; it hit `target` `hit_distance` away
## (<= 0: use the distance to the target's origin).
func _init(p_target: Node3D, p_pointer: Node3D, hit_distance: float = -1.0) -> void:
	target = p_target
	pointer = p_pointer
	if hit_distance <= 0.0:
		hit_distance = pointer.global_position.distance_to(target.global_position)
	distance = clampf(hit_distance, MIN_DISTANCE, MAX_DISTANCE)
	_offset_local = target.global_basis.inverse() * (target.global_position - _grab_point())

func is_valid() -> bool:
	return is_instance_valid(target) and is_instance_valid(pointer)

## Call every frame while the grab lasts.
func update() -> void:
	if not is_valid():
		return
	var grab := _grab_point()
	var camera := target.get_viewport().get_camera_3d()
	var head := camera.global_position if camera else pointer.global_position
	var basis := facing_basis(grab, head)
	target.global_transform = Transform3D(basis, grab + basis * _offset_local)

func push_pull(delta_m: float) -> void:
	distance = clampf(distance + delta_m, MIN_DISTANCE, MAX_DISTANCE)

func _grab_point() -> Vector3:
	return pointer.global_position - pointer.global_basis.z.normalized() * distance

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
