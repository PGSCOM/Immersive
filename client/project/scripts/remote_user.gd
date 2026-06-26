## Remote user avatar in the VR space.
## Manages head, hands, screen panels, and per-panel MJPEG decoders for another
## participant. When video frames arrive (via on_video_frame()), they are handed
## to a SoftwareVideoDecoder that runs on a WorkerThreadPool thread; _process()
## polls the decoder each frame and uploads the result to the panel.

extends Node3D

## Preloaded so the type resolves even when this script is compiled before the
## global class registry is populated (e.g. running the headless test suite on a
## fresh import, where the bare class_name fails with "Could not find type").
## Shadows the global SoftwareVideoDecoder class_name with an equivalent ref.
const SoftwareVideoDecoder := preload("res://scripts/software_video_decoder.gd")

## User ID from the signaling server.
var user_id: int = -1

## Display name (for UI, not logged). Updates the floating nameplate on assignment.
var display_name: String = "" : set = _set_display_name

## Head node.
var _head: Node3D = null

## Hand nodes.
var _left_hand: Node3D = null
var _right_hand: Node3D = null

## Floating name label above the head.
var _nameplate: Label3D = null

## Screen panels for shared monitors.
var _screen_panels: Dictionary = {}  # monitor_id -> RemoteScreenPanel

## MJPEG decoders — one per active panel.  Mirrors the _sw_decoders dict in
## main.gd but lives here so the avatar owns its own decode lifecycle.
var _decoders: Dictionary = {}  # monitor_id -> SoftwareVideoDecoder

func _init() -> void:
	var avatar_color := Color(0.30, 0.60, 0.95)

	_head = Node3D.new()
	_head.name = "Head"
	add_child(_head)
	var head_mesh := MeshInstance3D.new()
	var head_box := BoxMesh.new()
	head_box.size = Vector3(0.18, 0.22, 0.16)
	head_mesh.mesh = head_box
	head_mesh.material_override = _avatar_material(avatar_color)
	_head.add_child(head_mesh)

	# Floating nameplate above the head (billboarded, no depth test so it is
	# always readable). Text is filled in when display_name is assigned.
	_nameplate = Label3D.new()
	_nameplate.font_size = 28
	_nameplate.modulate = Color(0.85, 0.92, 1.0)
	_nameplate.no_depth_test = true
	_nameplate.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_nameplate.position = Vector3(0.0, 0.22, 0.0)
	_nameplate.text = display_name
	_head.add_child(_nameplate)

	_left_hand = Node3D.new()
	_left_hand.name = "LeftHand"
	add_child(_left_hand)
	_left_hand.add_child(_make_hand_mesh(avatar_color))

	_right_hand = Node3D.new()
	_right_hand.name = "RightHand"
	add_child(_right_hand)
	_right_hand.add_child(_make_hand_mesh(avatar_color))

## Build a simple hand cube for the avatar.
func _make_hand_mesh(color: Color) -> MeshInstance3D:
	var hand_mesh := MeshInstance3D.new()
	var hand_box := BoxMesh.new()
	hand_box.size = Vector3(0.07, 0.04, 0.10)
	hand_mesh.mesh = hand_box
	hand_mesh.material_override = _avatar_material(color)
	return hand_mesh

## Unshaded, slightly emissive material so avatars read clearly in any environment.
func _avatar_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.emission_enabled = true
	mat.emission = Color(color.r * 0.4, color.g * 0.4, color.b * 0.4)
	mat.emission_energy_multiplier = 0.6
	return mat

func _set_display_name(value: String) -> void:
	display_name = value
	if _nameplate:
		_nameplate.text = value

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

## Poll decoders and upload finished frames to their panels (call every frame).
func _process(_delta: float) -> void:
	for mid in _decoders.keys():
		var dec: SoftwareVideoDecoder = _decoders[mid]
		var img: Image = dec.get_decoded_image()
		if img == null:
			continue
		var panel = _screen_panels.get(mid)
		if panel and panel.has_method("update_decoded_image"):
			panel.update_decoded_image(img)

## Feed an encoded MJPEG frame for one of this user's shared monitors.
##
## Thread-safe (SoftwareVideoDecoder.submit is guarded by a mutex). The
## decoder is created on first call; if the monitor has no panel yet the frame
## is silently dropped (the panel and decoder lifecycle are tied together via
## apply_screen_layout).
func on_video_frame(monitor_id: int, frame_data: PackedByteArray) -> void:
	if not _screen_panels.has(monitor_id):
		return  # panel not yet created — layout hasn't arrived yet

	if not _decoders.has(monitor_id):
		var dec := SoftwareVideoDecoder.new()
		var panel = _screen_panels[monitor_id]
		var res: Vector2i = panel.get_resolution() if panel.has_method("get_resolution") \
			else Vector2i(1920, 1080)
		if dec.open(SoftwareVideoDecoder.CODEC_MJPEG, res.x, res.y):
			_decoders[monitor_id] = dec
		else:
			return  # codec not supported (should never happen for MJPEG)

	(_decoders[monitor_id] as SoftwareVideoDecoder).submit(frame_data)

## Apply screen layout from REMOTE_SCREEN_LAYOUT message.
## Panels are parented to the head node so their local-transform offsets
## (which are head-relative from the sender) follow the avatar as it moves.
func apply_screen_layout(entries: Array) -> void:
	# Remove panels (and their decoders) for monitors no longer in layout.
	var new_ids: Array = []
	for entry in entries:
		new_ids.append(entry.get("monitor_id", -1))

	for existing_id in _screen_panels.keys():
		if not new_ids.has(existing_id):
			_screen_panels[existing_id].queue_free()
			_screen_panels.erase(existing_id)
			if _decoders.has(existing_id):
				(_decoders[existing_id] as SoftwareVideoDecoder).close()
				_decoders.erase(existing_id)

	# Add or update panels (parented to head so they move with the avatar).
	for entry in entries:
		var mid: int = entry.get("monitor_id", -1)
		if mid < 0:
			continue

		if not _screen_panels.has(mid):
			var panel = preload("res://scripts/remote_screen_panel.gd").new()
			panel.name = "ScreenPanel_%d" % mid
			_head.add_child(panel)
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

## Close all decoders. Called implicitly via apply_screen_layout([]) when the
## remote user stops sharing, and from queue_free paths.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for mid in _decoders.keys():
			(_decoders[mid] as SoftwareVideoDecoder).close()
		_decoders.clear()
