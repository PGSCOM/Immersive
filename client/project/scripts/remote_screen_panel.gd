## Remote screen panel for displaying another user's shared monitor.
##
## Placed around a remote user's avatar from the REMOTE_SCREEN_LAYOUT message
## (pose + size + resolution). The panel renders as an unshaded screen-coloured
## surface with a floating label so the viewer can see which monitor is shared and
## where; the live pixels are not streamed peer-to-peer in this build, so this is a
## presence/placeholder surface rather than a second video decode path.

extends Node3D

## Monitor ID this panel represents (from the remote user's layout).
var monitor_id: int = -1

## Native resolution of the remote monitor.
var resolution: Vector2i = Vector2i(1920, 1080)

## Panel size in meters (width, height).
var panel_size: Vector2 = Vector2(1.6, 0.9)

## MeshInstance3D that displays the screen surface.
var _mesh: MeshInstance3D = null

## PlaneMesh for the screen.
var _plane: PlaneMesh = null

## Floating label naming the shared monitor.
var _label: Label3D = null

func _ready() -> void:
	_mesh = MeshInstance3D.new()
	add_child(_mesh)

	_plane = PlaneMesh.new()
	_plane.size = panel_size
	_plane.orientation = PlaneMesh.FACE_Z
	_mesh.mesh = _plane

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.08, 0.10, 0.16)
	mat.emission_enabled = true
	mat.emission = Color(0.10, 0.14, 0.24)
	mat.emission_energy_multiplier = 0.4
	_mesh.material_override = mat

	_label = Label3D.new()
	_label.font_size = 22
	_label.modulate = Color(0.70, 0.82, 1.0)
	_label.no_depth_test = true
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.position = Vector3(0.0, panel_size.y * 0.5 + 0.04, 0.0)
	_mesh.add_child(_label)
	_refresh_label()

## Apply layout metadata from REMOTE_SCREEN_LAYOUT message.
func apply_layout_metadata(entry: Dictionary) -> void:
	monitor_id = entry.get("monitor_id", -1)
	var pos := Vector3(entry.get("pos_x", 0.0), entry.get("pos_y", 0.0), entry.get("pos_z", 0.0))
	var rot := Quaternion(entry.get("rot_x", 0.0), entry.get("rot_y", 0.0), entry.get("rot_z", 0.0), entry.get("rot_w", 1.0))

	transform.origin = pos
	transform.basis = Basis(rot)

	panel_size = Vector2(entry.get("width", 1.6), entry.get("height", 0.9))
	resolution = Vector2i(entry.get("resolution_w", 1920), entry.get("resolution_h", 1080))

	if _plane:
		_plane.size = panel_size
	if _label:
		_label.position = Vector3(0.0, panel_size.y * 0.5 + 0.04, 0.0)
	_refresh_label()

func _refresh_label() -> void:
	if _label:
		_label.text = "🖥 Monitor %d · %d×%d" % [monitor_id, resolution.x, resolution.y]

## Get the current panel size.
func get_panel_size() -> Vector2:
	return panel_size

## Get the current resolution.
func get_resolution() -> Vector2i:
	return resolution
