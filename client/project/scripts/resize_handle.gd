## A corner handle of a screen: bring the pointer near a corner and a small
## bracket appears just outside it; grab it (trigger or pinch, like a grab
## bar) and drag to resize the screen, keeping its aspect ratio with the
## opposite corner fixed. main.gd::pick() finds it as a "bar" hit, so
## controllers and hands grab it through LaserDrag.grab() like any bar.
## Its zone lies outside the screen: the desktop's own corner pixels still
## belong to the desktop. One per corner, children of a ScreenPanel, placed
## by it (see ScreenPanel._place_decorations).

extends Node3D
class_name ResizeHandle

const COLOR := Color(0.93, 0.92, 0.88)
## Arm length and thickness of the bracket, and how far outside the corner it stands.
const ARM_M := 0.07
const RADIUS_M := 0.004
const OFFSET_M := 0.02
## The zone is a ball, its centre this far outside the corner on each axis.
const ZONE_OUT_M := 0.05
const HIT_RADIUS_M := 0.09
## The bracket shows when the ray passes this close to the zone centre.
const SHOW_RADIUS_M := 0.25
## Time constant of the size filter (hand tremor).
const SMOOTH_S := 0.05

## (+1 right / -1 left, +1 top / -1 bottom).
var corner := Vector2.ONE

var _mat: StandardMaterial3D
var _near := 0    ## frames left of "the ray passes close"
var _hover := 0   ## frames left of "the handle itself is pointed at"

var _pointer: Node3D = null
var _distance := 1.0
# State captured at grab time, in the screen's frame then.
var _start := Transform3D.IDENTITY
var _anchor := Vector3.ZERO        ## the opposite corner
var _diag := Vector2.ONE           ## anchor -> dragged corner
var _corner_z := 0.0               ## depth of the dragged corner (curved screens bulge)
var _grab_off := Vector2.ZERO      ## where the pointer was relative to that corner
var _anchor_world := Vector3.ZERO
var _w0 := 1.0
var _s := 1.0                      ## filtered scale factor

func _init(p_corner: Vector2 = Vector2.ONE) -> void:
	corner = p_corner
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(COLOR, 0.5)
	var o := Vector2(corner.x, corner.y) * OFFSET_M
	# A bracket: one arm along the top/bottom edge, one along the side.
	_arm(Vector3(o.x - corner.x * ARM_M / 2.0, o.y, 0.0), true)
	_arm(Vector3(o.x, o.y - corner.y * ARM_M / 2.0, 0.0), false)
	visible = false

func _arm(at: Vector3, horizontal: bool) -> void:
	var m := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = RADIUS_M
	cap.height = ARM_M
	cap.radial_segments = 8
	cap.rings = 2
	m.mesh = cap
	m.position = at
	m.rotation = Vector3(0.0, 0.0, PI / 2.0 if horizontal else 0.0)
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m.material_override = _mat
	add_child(m)

func _process(delta: float) -> void:
	if _pointer:
		_resize(delta)
	var lit := _hover > 0 or _pointer != null
	visible = lit or _near > 0
	_mat.albedo_color.a = 0.95 if lit else 0.5
	_hover = maxi(_hover - 1, 0)
	_near = maxi(_near - 1, 0)

func is_resize_handle() -> bool:
	return true

## A pointer rests on the handle this frame: light it.
func mark_hovered() -> void:
	_hover = 3

## Where the ray comes closest to the zone's centre: shows the bracket when it
## is near, and returns the distance along the ray when it is inside the zone,
## else -1 (also -1 while the screen is hidden).
func probe(ray_origin: Vector3, ray_direction: Vector3) -> float:
	if not get_parent().is_visible_in_tree():
		return -1.0
	var c := to_global(Vector3(corner.x, corner.y, 0.0) * ZONE_OUT_M)
	var dir := ray_direction.normalized()
	var t := maxf((c - ray_origin).dot(dir), 0.0)
	var miss := (ray_origin + dir * t).distance_to(c)
	if miss > SHOW_RADIUS_M:
		return -1.0
	_near = 3
	return t if miss <= HIT_RADIUS_M else -1.0

# ---------------------------------------------------------------------------
# Grab to resize (the same calls LaserDrag.grab() / drop() make)
# ---------------------------------------------------------------------------

func start_drag(pointer: Node3D, hit_distance: float = -1.0) -> void:
	var p := get_parent()
	_pointer = pointer
	_distance = hit_distance if hit_distance > 0.0 else 1.0
	_start = p.global_transform
	_w0 = p.panel_width
	_s = 1.0
	var u := 0.5 + 0.5 * corner.x
	var v := 0.5 - 0.5 * corner.y
	var dragged: Vector3 = p.local_point(u, v)
	_anchor = p.local_point(1.0 - u, 1.0 - v)
	_anchor_world = p.to_global(_anchor)
	_diag = Vector2(dragged.x - _anchor.x, dragged.y - _anchor.y)
	_corner_z = dragged.z
	var at := _plane_point(_corner_z)
	_grab_off = (at - Vector2(dragged.x, dragged.y)) if is_finite(at.x) else Vector2.ZERO

func stop_drag() -> void:
	_pointer = null

func is_dragging() -> bool:
	return _pointer != null

## Length of the pointer's ray: it reaches the screen's plane.
func get_drag_distance() -> float:
	return _distance

## Where the pointer's ray crosses the plane z = `z` of the screen's frame at
## grab time (x, y there); NAN when it points away from it.
func _plane_point(z: float) -> Vector2:
	var o := _start.affine_inverse() * _pointer.global_position
	var d := _start.basis.inverse() * (-_pointer.global_basis.z)
	if absf(d.z) < 0.0001 or (z - o.z) / d.z < 0.0:
		return Vector2(NAN, NAN)
	var t := (z - o.z) / d.z
	_distance = t
	return Vector2(o.x + d.x * t, o.y + d.y * t)

func _resize(delta: float) -> void:
	var p := get_parent()
	var at := _plane_point(_corner_z)
	if not is_finite(at.x):
		return
	# Projected on the diagonal, so it grows the same whichever way it is pulled.
	var s := (at - _grab_off - Vector2(_anchor.x, _anchor.y)).dot(_diag) / _diag.dot(_diag)
	var k := 1.0 if delta <= 0.0 else 1.0 - exp(-delta / SMOOTH_S)
	_s = lerpf(_s, s, k)
	p.set_panel_width(_w0 * maxf(_s, 0.01))
	# The opposite corner stays where it was.
	var u := 0.5 - 0.5 * corner.x
	var v := 0.5 + 0.5 * corner.y
	var anchor_now: Vector3 = p.local_point(u, v)
	p.global_transform = Transform3D(_start.basis, _anchor_world - _start.basis * anchor_now)
