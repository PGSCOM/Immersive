## A single passthrough portal — a resizable, repositionable "window" that reveals
## the real world through the headset cameras (mixed reality). Mirrors Immersed's
## passthrough portals: rectangle (e.g. a keyboard tray), square, and circle
## shapes that can be placed and resized in VR.
##
## Rendering uses shaders/portal.gdshader (a transparent depth-writing cutout);
## the geometry/management contract here is what the test suite exercises.

extends MeshInstance3D
class_name Im2Portal

const PORTAL_SHADER_PATH := "res://shaders/portal.gdshader"

## Supported portal shapes.
enum Shape { RECTANGLE, SQUARE, CIRCLE }

## Clamp limits for a portal's size in metres.
const MIN_SIZE := 0.10
const MAX_SIZE := 2.50

var _shape: Shape = Shape.RECTANGLE
var _size: Vector2 = Vector2(0.5, 0.3)

## True when this portal is anchored to the physical keyboard location (it then
## stays put so the user always sees their real keyboard when they look down).
var _is_keyboard_portal: bool = false

# Drag state (grip-repositioning), mirrors screen_panel.gd.
var _is_dragging: bool = false
var _drag_controller: Node3D = null
var _drag_offset: Transform3D

func _ready() -> void:
	set_process(true)

func _process(_delta: float) -> void:
	if _is_dragging and is_instance_valid(_drag_controller):
		global_transform = _drag_controller.global_transform * _drag_offset

## Configure the portal's shape and size, rebuilding the mesh + material.
func setup(shape: Shape, size: Vector2) -> void:
	_shape = shape
	set_size(size)

## Set the portal shape (rebuilds the mesh/material to match).
func set_shape(shape: Shape) -> void:
	_shape = shape
	_rebuild()

func get_shape() -> Shape:
	return _shape

## Resize the portal (square keeps a 1:1 aspect; metres, clamped to [MIN,MAX]).
func set_size(size: Vector2) -> void:
	var w: float = clampf(size.x, MIN_SIZE, MAX_SIZE)
	var h: float = clampf(size.y, MIN_SIZE, MAX_SIZE)
	if _shape == Shape.SQUARE or _shape == Shape.CIRCLE:
		h = w  # square + circle are 1:1
	_size = Vector2(w, h)
	_rebuild()

func get_size() -> Vector2:
	return _size

## Mark this portal as the keyboard portal (anchored to the real keyboard).
func set_keyboard_portal(enabled: bool) -> void:
	_is_keyboard_portal = enabled

func is_keyboard_portal() -> bool:
	return _is_keyboard_portal

# ---------------------------------------------------------------------------
# Grip drag — reposition the portal in 3D (called from vr_input.gd)
# ---------------------------------------------------------------------------

func start_drag(controller: Node3D) -> void:
	if not is_instance_valid(controller):
		return
	_is_dragging = true
	_drag_controller = controller
	_drag_offset = controller.global_transform.affine_inverse() * global_transform

func stop_drag() -> void:
	_is_dragging = false
	_drag_controller = null

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _rebuild() -> void:
	var plane := PlaneMesh.new()
	plane.orientation = PlaneMesh.FACE_Z
	plane.size = _size
	mesh = plane

	var mat := material_override as ShaderMaterial
	if mat == null:
		mat = ShaderMaterial.new()
		var shader := load(PORTAL_SHADER_PATH) as Shader
		if shader:
			mat.shader = shader
		material_override = mat
	mat.set_shader_parameter("is_circle", 1 if _shape == Shape.CIRCLE else 0)
