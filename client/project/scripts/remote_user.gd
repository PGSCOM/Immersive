## Remote user avatar in the VR space.
## Manages head, hands, and screen panels for another participant.

extends Node3D

## User ID from the signaling server.
var user_id: int = -1

## Display name (for UI, not logged).
var display_name: String = ""

## Head node.
var _head: Node3D = null

## Hand nodes.
var _left_hand: Node3D = null
var _right_hand: Node3D = null

## Screen panels for shared monitors.
var _screen_panels: Dictionary = {}  # monitor_id -> RemoteScreenPanel

func _ready() -> void:
    _head = Node3D.new()
    _head.name = "Head"
    add_child(_head)
    
    _left_hand = Node3D.new()
    _left_hand.name = "LeftHand"
    add_child(_left_hand)
    
    _right_hand = Node3D.new()
    _right_hand.name = "RightHand"
    add_child(_right_hand)

## Update pose from USER_POSE message.
func update_pose(head: Dictionary, left_hand: Dictionary, right_hand: Dictionary) -> void:
    _apply_pose(_head, head)
    _apply_pose(_left_hand, left_hand)
    _apply_pose(_right_hand, right_hand)

func _apply_pose(node: Node3D, pose: Dictionary) -> void:
    var pos := Vector3(pose.get("pos_x", 0.0), pose.get("pos_y", 0.0), pose.get("pos_z", 0.0))
    var rot := Quaternion(pose.get("rot_x", 0.0), pose.get("rot_y", 0.0), pose.get("rot_z", 0.0), pose.get("rot_w", 1.0))
    node.transform.origin = pos
    node.transform.basis = Basis(rot)

## Apply screen layout from REMOTE_SCREEN_LAYOUT message.
func apply_screen_layout(entries: Array) -> void:
    # Remove panels for monitors no longer in layout
    var new_ids: Array = []
    for entry in entries:
        new_ids.append(entry.get("monitor_id", -1))
    
    for existing_id in _screen_panels.keys():
        if not new_ids.has(existing_id):
            _screen_panels[existing_id].queue_free()
            _screen_panels.erase(existing_id)
    
    # Add or update panels
    for entry in entries:
        var mid: int = entry.get("monitor_id", -1)
        if mid < 0:
            continue
        
        if not _screen_panels.has(mid):
            var panel = preload("res://scripts/remote_screen_panel.gd").new()
            panel.name = "ScreenPanel_%d" % mid
            add_child(panel)
            _screen_panels[mid] = panel
        
        _screen_panels[mid].apply_layout_metadata(entry)

## Get all screen panels.
func get_screen_panels() -> Array:
    return _screen_panels.values()

## Get a specific screen panel by monitor ID.
func get_screen_panel_for_monitor(monitor_id: int) -> Node:
    return _screen_panels.get(monitor_id, null)

## Get the head node.
func get_head_node() -> Node3D:
    return _head

## Get the left hand node.
func get_left_hand_node() -> Node3D:
    return _left_hand

## Get the right hand node.
func get_right_hand_node() -> Node3D:
    return _right_hand

## Get display name.
func get_display_name() -> String:
    return display_name
