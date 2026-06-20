## Remote screen panel for displaying another user's shared monitor.
## Similar to screen_panel.gd but receives video from WebRTC data channel.

extends Node3D

## Monitor ID this panel represents (from the remote user's layout).
var monitor_id: int = -1

## Native resolution of the remote monitor.
var resolution: Vector2i = Vector2i(1920, 1080)

## Panel size in meters (width, height).
var panel_size: Vector2 = Vector2(1.6, 0.9)

## MeshInstance3D that displays the video.
var _mesh: MeshInstance3D = null

## PlaneMesh for the screen.
var _plane: PlaneMesh = null

func _ready() -> void:
    _mesh = MeshInstance3D.new()
    add_child(_mesh)
    
    _plane = PlaneMesh.new()
    _plane.size = panel_size
    _plane.orientation = PlaneMesh.FACE_Z
    _mesh.mesh = _plane

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

## Get the current panel size.
func get_panel_size() -> Vector2:
    return panel_size

## Get the current resolution.
func get_resolution() -> Vector2i:
    return resolution
