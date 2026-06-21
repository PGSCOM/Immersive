## Teleport + snap-turn locomotion for Immersive-2 (Immersed parity: glowing floor
## points / teleport dots and comfortable turning to move around the room and the
## whiteboard).
##
## The node moves an XROrigin3D so the user can teleport to a floor point and turn
## in fixed increments. The transform math is exposed as pure static helpers so it
## is unit-testable without a live headset / scene tree.
##
## Wiring (done in main.gd / vr_input.gd): push the left thumbstick forward to aim
## the teleport ray, release to teleport; flick it left/right to snap-turn.

extends Node
class_name Locomotion

## Default comfort turn increment, in degrees.
const SNAP_TURN_DEGREES := 30.0

## XR nodes this locomotion drives (set via configure()).
var _origin: XROrigin3D = null
var _camera: XRCamera3D = null

## Floor height (metres) teleport targets snap to.
var _floor_y: float = 0.0

## Bind the XR origin + camera (and optional floor height).
func configure(origin: XROrigin3D, camera: XRCamera3D, floor_y: float = 0.0) -> void:
	_origin = origin
	_camera = camera
	_floor_y = floor_y

## Teleport so the camera ends up over `point` (keeps the user's standing height).
func teleport_to(point: Vector3) -> void:
	if not is_instance_valid(_origin) or not is_instance_valid(_camera):
		return
	_origin.global_transform = teleport_origin_transform(
		_origin.global_transform, _camera.global_transform.origin, point)

## Snap-turn the origin around the camera by `degrees` (default ±SNAP_TURN_DEGREES).
func snap_turn(degrees: float = SNAP_TURN_DEGREES) -> void:
	if not is_instance_valid(_origin) or not is_instance_valid(_camera):
		return
	_origin.global_transform = snap_turn_transform(
		_origin.global_transform, _camera.global_transform.origin, degrees)

## Resolve where a controller ray meets the floor. Returns { valid, point }.
func aim_floor(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	return floor_target(ray_origin, ray_direction, _floor_y)

# ---------------------------------------------------------------------------
# Pure static helpers (unit-tested directly)
# ---------------------------------------------------------------------------

## Intersect a ray with the horizontal floor plane y = floor_y. Returns
## { valid: bool, point: Vector3 }. Only forward (t > 0) hits count, so a ray
## pointing up or parallel to the floor yields no target.
static func floor_target(ray_origin: Vector3, ray_direction: Vector3,
		floor_y: float = 0.0) -> Dictionary:
	var dy := ray_direction.y
	if absf(dy) < 0.0001:
		return {"valid": false}
	var t := (floor_y - ray_origin.y) / dy
	if t <= 0.0:
		return {"valid": false}
	return {"valid": true, "point": ray_origin + ray_direction * t}

## New origin transform so the camera (at camera_global on the XZ plane) ends up
## over target_point, keeping orientation and the user's height (only X/Z move).
static func teleport_origin_transform(origin_xform: Transform3D,
		camera_global: Vector3, target_point: Vector3) -> Transform3D:
	var delta := Vector3(target_point.x - camera_global.x, 0.0,
		target_point.z - camera_global.z)
	return Transform3D(origin_xform.basis, origin_xform.origin + delta)

## New origin transform after turning `degrees` about the vertical axis through
## `pivot_global` (the camera), so the view rotates in place without translating.
static func snap_turn_transform(origin_xform: Transform3D, pivot_global: Vector3,
		degrees: float) -> Transform3D:
	var rot := Basis(Vector3.UP, deg_to_rad(degrees))
	var new_basis := rot * origin_xform.basis
	var new_origin := pivot_global + rot * (origin_xform.origin - pivot_global)
	return Transform3D(new_basis, new_origin)
