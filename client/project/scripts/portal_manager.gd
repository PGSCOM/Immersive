## Manages passthrough portals for Immersive-2 (mixed-reality feature parity with
## Immersed). Holds up to MAX_PORTALS portals of three shapes (rectangle, square,
## circle), supports a dedicated keyboard portal, and lets portals be created,
## resized, repositioned and removed at runtime.
##
## Attach as a child of the main scene. Portals are created as Im2Portal children.

extends Node3D
class_name PortalManager

## Emitted whenever the set of portals changes (count).
signal portals_changed(count: int)

## Maximum simultaneous passthrough portals (matches Immersed's documented limit).
const MAX_PORTALS: int = 5

const PORTAL_SCRIPT := preload("res://scripts/portal.gd")

## Default sizes (metres) per shape.
const DEFAULT_RECT_SIZE := Vector2(0.6, 0.35)
const DEFAULT_SQUARE_SIZE := Vector2(0.4, 0.4)
const DEFAULT_CIRCLE_SIZE := Vector2(0.4, 0.4)
## A keyboard tray is a wide, shallow rectangle anchored at the desk.
const KEYBOARD_PORTAL_SIZE := Vector2(0.5, 0.22)

var _portals: Array[Im2Portal] = []

## The single keyboard portal, if one exists (also counted in _portals).
var _keyboard_portal: Im2Portal = null

## Create a portal of the given shape. Returns the new Im2Portal, or null when the
## MAX_PORTALS limit is reached. `xform` positions it (defaults to ~1 m ahead).
func add_portal(shape: int = Im2Portal.Shape.RECTANGLE,
		size: Vector2 = Vector2.ZERO,
		xform: Transform3D = Transform3D.IDENTITY) -> Im2Portal:
	if _portals.size() >= MAX_PORTALS:
		push_warning("[PortalManager] Maximum portals (%d) reached" % MAX_PORTALS)
		return null

	var portal: Im2Portal = PORTAL_SCRIPT.new()
	add_child(portal)
	var resolved_size := size if size != Vector2.ZERO else _default_size_for(shape)
	portal.setup(shape, resolved_size)
	portal.transform = xform
	_portals.append(portal)
	portals_changed.emit(_portals.size())
	return portal

## Create (or move) the dedicated keyboard portal: a wide rectangle anchored where
## the user's physical keyboard sits, so looking down always shows the real keys.
func create_keyboard_portal(xform: Transform3D = Transform3D.IDENTITY) -> Im2Portal:
	if is_instance_valid(_keyboard_portal):
		if xform != Transform3D.IDENTITY:
			_keyboard_portal.transform = xform
		return _keyboard_portal

	var portal := add_portal(Im2Portal.Shape.RECTANGLE, KEYBOARD_PORTAL_SIZE, xform)
	if portal:
		portal.set_keyboard_portal(true)
		_keyboard_portal = portal
	return portal

## Remove a specific portal. Returns true if it was present.
func remove_portal(portal: Im2Portal) -> bool:
	if portal == null or not _portals.has(portal):
		return false
	_portals.erase(portal)
	if portal == _keyboard_portal:
		_keyboard_portal = null
	if is_instance_valid(portal):
		portal.queue_free()
	portals_changed.emit(_portals.size())
	return true

## Remove every portal.
func clear_portals() -> void:
	for portal in _portals:
		if is_instance_valid(portal):
			portal.queue_free()
	_portals.clear()
	_keyboard_portal = null
	portals_changed.emit(0)

func get_portal_count() -> int:
	return _portals.size()

func get_portals() -> Array:
	return _portals.duplicate()

func has_keyboard_portal() -> bool:
	return is_instance_valid(_keyboard_portal)

func get_keyboard_portal() -> Im2Portal:
	return _keyboard_portal

## Return the closest portal hit by a world-space ray (for grip selection), or
## { valid: false }. On hit: { valid, portal, distance }.
func get_portal_hit_from_ray(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	var best: Im2Portal = null
	var best_t := INF
	for portal in _portals:
		if not is_instance_valid(portal):
			continue
		var r := ray_hit_rect(portal.global_transform, portal.get_size(),
			ray_origin, ray_direction)
		if r.get("valid", false) and float(r["distance"]) < best_t:
			best_t = float(r["distance"])
			best = portal
	if best == null:
		return {"valid": false}
	return {"valid": true, "portal": best, "distance": best_t}

## Pure ray/rectangle intersection in a portal's own frame (the portal is a
## rectangle of `size` centred on `xform`, facing its local Z). Returns
## { valid: bool, distance: float }. Kept static + side-effect-free so the
## geometry is unit-testable without live scene-tree global transforms.
static func ray_hit_rect(xform: Transform3D, size: Vector2,
		ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	var normal: Vector3 = xform.basis.z.normalized()
	var denom: float = ray_direction.dot(normal)
	if absf(denom) < 0.0001:
		return {"valid": false}
	var t: float = (xform.origin - ray_origin).dot(normal) / denom
	if t < 0.0:
		return {"valid": false}
	var local: Vector3 = xform.affine_inverse() * (ray_origin + ray_direction * t)
	if absf(local.x) <= size.x * 0.5 and absf(local.y) <= size.y * 0.5:
		return {"valid": true, "distance": t}
	return {"valid": false}

func _default_size_for(shape: int) -> Vector2:
	match shape:
		Im2Portal.Shape.SQUARE:
			return DEFAULT_SQUARE_SIZE
		Im2Portal.Shape.CIRCLE:
			return DEFAULT_CIRCLE_SIZE
		_:
			return DEFAULT_RECT_SIZE
