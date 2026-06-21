## Mobile client for Immersive-2 multi-user rooms.
## Touch-friendly UI for phone users joining the same rooms as VR users.

extends Node3D

## Signaling client for room management.
var signaling: Node = null

## Local user ID from signaling server.
var local_user_id: int = -1

## Dictionary of remote users: user_id -> RemoteUser node
var remote_users: Dictionary = {}

## Touch input state
var _touch_dragging: bool = false
var _last_touch_pos: Vector2 = Vector2.ZERO

func _ready() -> void:
	print("[MobileClient] Mobile client started")
	_init_signaling()

func _init_signaling() -> void:
	signaling = preload("res://scripts/signaling_client.gd").new()
	signaling.name = "SignalingClient"
	add_child(signaling)
	
	signaling.connected_to_signaling.connect(_on_connected)
	signaling.room_joined.connect(_on_room_joined)
	signaling.user_presence.connect(_on_user_presence)
	signaling.user_pose_received.connect(_on_user_pose)

func connect_to_room(url: String, room_id: String, display_name: String) -> void:
	signaling.connect_to_signaling(url)
	await signaling.connected_to_signaling
	signaling.send_room_join(room_id, display_name)

func _on_connected() -> void:
	print("[MobileClient] Connected to signaling server")

func _on_room_joined(room_id: String, user_id: int, participants: Array) -> void:
	local_user_id = user_id
	print("[MobileClient] Joined room %s as user %d" % [room_id, user_id])
	
	for p in participants:
		var pid: int = p.get("user_id", 0)
		if pid != local_user_id:
			_add_remote_user(pid, p.get("display_name", ""))

func _on_user_presence(user_id: int, display_name: String, is_online: bool) -> void:
	# The signaling server only relays presence for *other* users (it excludes
	# the sender), so every update here is a remote join/leave.
	if is_online:
		_add_remote_user(user_id, display_name)
	else:
		_remove_remote_user(user_id)

func _on_user_pose(user_id: int, head: Dictionary, left_hand: Dictionary, right_hand: Dictionary) -> void:
	if remote_users.has(user_id):
		remote_users[user_id].update_pose(head, left_hand, right_hand)

func _add_remote_user(user_id: int, display_name: String) -> void:
	if remote_users.has(user_id):
		return
	var user = preload("res://scripts/remote_user.gd").new()
	user.name = "RemoteUser_%d" % user_id
	user.user_id = user_id
	user.display_name = display_name
	add_child(user)
	remote_users[user_id] = user
	print("[MobileClient] Remote user joined: %s (ID: %d)" % [display_name, user_id])

func _remove_remote_user(user_id: int) -> void:
	if remote_users.has(user_id):
		remote_users[user_id].queue_free()
		remote_users.erase(user_id)
		print("[MobileClient] Remote user left: ID %d" % user_id)

# Touch input handling
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_touch_dragging = event.pressed
		_last_touch_pos = event.position
	elif event is InputEventScreenDrag:
		if _touch_dragging:
			var delta: Vector2 = event.position - _last_touch_pos
			_handle_touch_drag(delta)
			_last_touch_pos = event.position

func _handle_touch_drag(delta: Vector2) -> void:
	# Rotate camera based on touch drag
	var sensitivity: float = 0.005
	rotate_y(-delta.x * sensitivity)
