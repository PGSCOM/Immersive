## The bar under a screen, the menu or the keyboard. Point at it and press
## (trigger or pinch) to move what it hangs from; main.gd::pick() finds it.
## Its hit zone is far larger than the pill drawn, so a hand finds it too.
## It lies in its owner's plane: place it with `position` only, no rotation.

extends Node3D
class_name GrabBar

## Hit zone (width, height) in metres around the pill.
const HIT_SIZE := Vector2(0.30, 0.07)
const COLOR := Color(0.93, 0.92, 0.88)

## Shown whenever its owner is (menu, keyboard); a screen's shows only while
## the screen or the bar is pointed at, or while it moves.
var always_shown := false

var _mat: StandardMaterial3D
var _owner_hover := 0   ## frames left of "the owner is pointed at"
var _hover := 0         ## frames left of "the bar itself is pointed at"

func _init() -> void:
	var pill := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.009
	cap.height = 0.2
	cap.radial_segments = 12
	cap.rings = 2
	pill.mesh = cap
	pill.rotation = Vector3(0.0, 0.0, PI / 2.0)  # lie horizontally
	pill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(COLOR, 0.55)
	pill.material_override = _mat
	add_child(pill)
	visible = false

func _process(_delta: float) -> void:
	var owner_node := get_parent()
	var lit: bool = _hover > 0 or (owner_node.has_method("is_dragging") and owner_node.is_dragging())
	visible = always_shown or lit or _owner_hover > 0
	_mat.albedo_color.a = 0.95 if lit else (0.55 if _owner_hover > 0 else 0.35)
	_hover = maxi(_hover - 1, 0)
	_owner_hover = maxi(_owner_hover - 1, 0)

## A pointer rests on the bar this frame: light it.
func mark_hovered() -> void:
	_hover = 3

## A pointer rests on the owner this frame: show the bar.
func mark_owner_hovered() -> void:
	_owner_hover = 3

## Distance along the ray to the hit zone, or -1 on a miss (or while the
## owner is hidden).
func hit(ray_origin: Vector3, ray_direction: Vector3) -> float:
	if not get_parent().is_visible_in_tree():
		return -1.0
	var o := global_transform.affine_inverse() * ray_origin
	var d := global_basis.inverse() * ray_direction
	if absf(d.z) < 0.0001:
		return -1.0
	var t := -o.z / d.z
	var p := o + d * t
	if t < 0.0 or absf(p.x) > HIT_SIZE.x / 2.0 or absf(p.y) > HIT_SIZE.y / 2.0:
		return -1.0
	return t * ray_direction.length()
