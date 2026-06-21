## Tests for the in-VR keyboard (virtual_keyboard.gd) and remote-user avatars
## (remote_user.gd) — the previously-unreachable keyboard and the previously
## invisible avatars. Run headlessly via the project test runner:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd

extends RefCounted

func _assert(condition: bool, message: String, passed: Array, failed: Array) -> void:
	if condition:
		passed.append(message)
		print("  PASS: %s" % message)
	else:
		failed.append(message)
		print("  FAIL: %s" % message)

func run_all(results: Dictionary, tree: SceneTree) -> void:
	print("\n=== Keyboard + Avatar Tests ===")
	var passed: Array = []
	var failed: Array = []

	test_keyboard(passed, failed, tree)
	test_avatars(passed, failed, tree)

	print("\n=== Keyboard/Avatar Results: Passed %d / Failed %d ===" % [passed.size(), failed.size()])
	results["passed"] = passed.size()
	results["failed"] = failed.size()
	results["failed_messages"] = failed.duplicate()

func test_keyboard(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: in-VR keyboard is reachable + types via edge detection")
	var kb = load("res://scenes/virtual_keyboard.tscn").instantiate()
	tree.root.add_child(kb)

	_assert(kb.has_method("ray_update"), "keyboard exposes ray_update()", passed, failed)
	_assert(kb.has_method("toggle_visibility"), "keyboard exposes toggle_visibility()", passed, failed)
	_assert(kb.has_method("pointer_update"), "keyboard exposes pointer_update()", passed, failed)

	# Toggling builds the keys and flips visibility.
	var was_visible: bool = kb.visible
	kb.toggle_visibility()
	_assert(kb.visible != was_visible, "toggle_visibility flips visibility", passed, failed)

	var key_a = kb.get_node_or_null("Key_A")
	_assert(key_a != null, "QWERTY keys are built (Key_A present)", passed, failed)
	if key_a == null:
		kb.queue_free()
		return

	# Edge detection: a held press types the key exactly once. Use the key's local
	# position (global transforms are not propagated in the headless harness; the
	# keyboard sits at the origin so local == world here).
	var wp: Vector3 = key_a.position
	var v1: int = kb.pointer_update(wp, true)
	_assert(v1 == 0x41, "pressing 'A' types vk 0x41", passed, failed)
	var v2: int = kb.pointer_update(wp, true)
	_assert(v2 == -1, "holding the press does not re-type", passed, failed)
	kb.pointer_update(wp, false)
	var v3: int = kb.pointer_update(wp, true)
	_assert(v3 == 0x41, "releasing then pressing types again", passed, failed)

	# A ray aimed at the key reports a valid hit (so vr_input/hand_input can drive it).
	var ray_origin: Vector3 = wp + Vector3(0.0, 0.0, 0.5)
	var rhit: Dictionary = kb.ray_update(ray_origin, Vector3(0.0, 0.0, -1.0), false)
	_assert(rhit.get("valid", false), "ray aimed at a key reports a valid hit", passed, failed)

	# A ray nowhere near the board reports no key hit.
	var miss: Dictionary = kb.ray_update(Vector3(5.0, 5.0, 0.5), Vector3(0.0, 0.0, -1.0), false)
	_assert(not miss.get("valid", false), "ray far from any key reports no hit", passed, failed)

	kb.queue_free()

func test_avatars(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: remote-user avatars are visible (meshes + nameplate)")
	var pkg: PackedScene = load("res://scenes/remote_user.tscn") as PackedScene
	if pkg == null:
		_assert(false, "remote_user.tscn loads", passed, failed)
		return
	var user: Node3D = pkg.instantiate()
	tree.root.add_child(user)
	user.display_name = "Alice"

	var head: Node3D = user.get_head_node()
	_assert(head != null, "avatar exposes a head node", passed, failed)
	_assert(_has_mesh_child(head), "avatar head has a visible mesh", passed, failed)

	# Nameplate label reflects the display name.
	var nameplate_ok := false
	for c in head.get_children():
		if c is Label3D and (c as Label3D).text == "Alice":
			nameplate_ok = true
	_assert(nameplate_ok, "nameplate shows the display name", passed, failed)

	_assert(_has_mesh_child(user.get_left_hand_node()), "left hand has a visible mesh", passed, failed)
	_assert(_has_mesh_child(user.get_right_hand_node()), "right hand has a visible mesh", passed, failed)

	# Pose updates still move the (now visible) head.
	if user.has_method("update_pose"):
		user.update_pose(
			{"pos_x": 1.0, "pos_y": 1.6, "pos_z": -2.0, "rot_w": 1.0, "rot_x": 0.0, "rot_y": 0.0, "rot_z": 0.0},
			{"pos_x": 0.0, "pos_y": 1.0, "pos_z": -1.0, "rot_w": 1.0, "rot_x": 0.0, "rot_y": 0.0, "rot_z": 0.0},
			{"pos_x": 0.0, "pos_y": 1.0, "pos_z": -1.0, "rot_w": 1.0, "rot_x": 0.0, "rot_y": 0.0, "rot_z": 0.0})
		_assert(head.transform.origin.distance_to(Vector3(1.0, 1.6, -2.0)) < 0.001,
			"head moves to the pose target", passed, failed)

	user.queue_free()

func _has_mesh_child(node: Node) -> bool:
	if node == null:
		return false
	for c in node.get_children():
		if c is MeshInstance3D:
			return true
	return false
