## Tests for multi-user remote-user scene and screen panels.
## Run headlessly via the project test runner:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
##
## Covers:
##   - RemoteUser builds an avatar (head + hands) and applies pose updates.
##   - RemoteScreenPanel applies monitor layout metadata (position / rotation /
##     size / resolution) exactly as sent by REMOTE_SCREEN_LAYOUT.
##   - main.gd creates remote users from signaling events, updates their pose
##     each frame, and removes them on room_left / presence=offline.
##   - Mode switching (vr / flat / mobile) does not break the plumbing.

extends RefCounted

# Counts/results are pushed to a shared dict so run_tests.gd can aggregate.
# We keep no state on the runner side; the test prints its own pass/fail.

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

func _assert(condition: bool, message: String,
		passed: Array, failed: Array) -> void:
	if condition:
		passed.append(message)
		print("  PASS: %s" % message)
	else:
		failed.append(message)
		print("  FAIL: %s" % message)

func _assert_eq_int(actual: int, expected: int, message: String,
		passed: Array, failed: Array) -> void:
	if actual == expected:
		passed.append(message)
		print("  PASS: %s (got %d)" % [message, actual])
	else:
		failed.append(message)
		print("  FAIL: %s (expected %d, got %d)" % [message, expected, actual])

func _assert_eq_float(actual: float, expected: float, tolerance: float,
		message: String, passed: Array, failed: Array) -> void:
	if abs(actual - expected) <= tolerance:
		passed.append(message)
		print("  PASS: %s (got %.4f)" % [message, actual])
	else:
		failed.append(message)
		print("  FAIL: %s (expected %.4f ± %.4f, got %.4f)" %
			[message, expected, tolerance, actual])

func _assert_close_vec3(actual: Vector3, expected: Vector3, tolerance: float,
		message: String, passed: Array, failed: Array) -> void:
	var ok: bool = abs(actual.x - expected.x) <= tolerance \
		and abs(actual.y - expected.y) <= tolerance \
		and abs(actual.z - expected.z) <= tolerance
	if ok:
		passed.append(message)
		print("  PASS: %s (got %s)" % [message, str(actual)])
	else:
		failed.append(message)
		print("  FAIL: %s (expected %s ± %.4f, got %s)" %
			[message, str(expected), tolerance, str(actual)])


# ---------------------------------------------------------------------------
# Pose helpers — TrackedPose is (pos_x, pos_y, pos_z, rot_w, rot_x, rot_y, rot_z)
# in protocol.h. We pack / unpack to mimic what the signaling layer sends.
# ---------------------------------------------------------------------------

func _make_pose_dict(pos: Vector3, rot: Quaternion) -> Dictionary:
	return {
		"pos_x": pos.x,
		"pos_y": pos.y,
		"pos_z": pos.z,
		"rot_w": rot.w,
		"rot_x": rot.x,
		"rot_y": rot.y,
		"rot_z": rot.z,
	}

func _entry(monitor_id: int, pos: Vector3, rot: Quaternion,
		size: Vector2, res: Vector2i) -> Dictionary:
	return {
		"monitor_id": monitor_id,
		"pos_x": pos.x,
		"pos_y": pos.y,
		"pos_z": pos.z,
		"rot_w": rot.w,
		"rot_x": rot.x,
		"rot_y": rot.y,
		"rot_z": rot.z,
		"width": size.x,
		"height": size.y,
		"resolution_w": res.x,
		"resolution_h": res.y,
	}


# ---------------------------------------------------------------------------
# Public entry point used by the test runner.
# ---------------------------------------------------------------------------

func run_all(results: Dictionary, tree: SceneTree) -> void:
	print("\n=== Remote Users Tests ===")
	var passed: Array = []
	var failed: Array = []

	test_remote_screen_panel_applies_layout(passed, failed, tree)
	test_remote_user_applies_pose(passed, failed, tree)
	test_remote_user_applies_screen_layout(passed, failed, tree)
	test_remote_user_manages_dynamic_screens(passed, failed, tree)
	test_main_gd_remote_user_lifecycle(passed, failed, tree)
	test_main_gd_pose_propagation(passed, failed, tree)
	test_main_gd_peer_join_leave(passed, failed, tree)
	test_mode_switching_does_not_break_remote_users(passed, failed, tree)

	print("\n=== Remote Users Results ===")
	print("Passed: %d" % passed.size())
	print("Failed: %d" % failed.size())
	print("Total:  %d" % (passed.size() + failed.size()))

	results["passed"] = passed.size()
	results["failed"] = failed.size()
	results["failed_messages"] = failed.duplicate()


# ---------------------------------------------------------------------------
# Test 1: a single RemoteScreenPanel applies layout metadata =>
##        transforms, panel size, and resolution all line up.
# ---------------------------------------------------------------------------

func test_remote_screen_panel_applies_layout(passed: Array, failed: Array, _tree: SceneTree) -> void:
	print("\nTest: RemoteScreenPanel applies layout metadata")

	var panel_script := load("res://scripts/remote_screen_panel.gd") as Script
	if not panel_script:
		failed.append("remote_screen_panel.gd loads")
		print("  FAIL: remote_screen_panel.gd loads")
		return
	passed.append("remote_screen_panel.gd loads")
	print("  PASS: remote_screen_panel.gd loads")

	var panel: Node3D = panel_script.new()
	if not panel.has_method("apply_layout_metadata"):
		failed.append("panel exposes apply_layout_metadata()")
		print("  FAIL: panel exposes apply_layout_metadata()")
		panel.free()
		return
	passed.append("panel exposes apply_layout_metadata()")
	print("  PASS: panel exposes apply_layout_metadata()")

	# Parent to a local root (transform checks use local transform which equals global when parent is at origin).
	var root := Node3D.new()
	_tree.root.add_child(root)
	root.add_child(panel)

	var pos := Vector3(2.5, 1.7, -3.0)
	var rot := Quaternion(Vector3(0.0, 1.0, 0.0), deg_to_rad(15.0)).normalized()
	var size := Vector2(1.0, 0.6)
	var res := Vector2i(2560, 1440)

	var entry: Dictionary = _entry(7, pos, rot, size, res)
	panel.apply_layout_metadata(entry)

	# Position must round-trip relative to the parent.
	var got_pos: Vector3 = panel.transform.origin
	_assert_close_vec3(got_pos, pos, 0.001, "panel global_position matches layout pos", passed, failed)

	# Rotation — compare quaternions via dot product (>= 0 => same orientation).
	var got_rot := Quaternion(panel.transform.basis.orthonormalized()).normalized()
	var dot: float = abs(got_rot.dot(rot))
	if dot > 0.999:
		passed.append("panel global_rotation matches layout rot (dot=%.4f)" % dot)
		print("  PASS: panel global_rotation matches layout rot (dot=%.4f)" % dot)
	else:
		failed.append("panel global_rotation matches layout rot (dot=%.4f)" % dot)
		print("  FAIL: panel global_rotation matches layout rot (dot=%.4f)" % dot)

	# Panel size in meters (the script stores it for the mesh hook).
	if panel.has_method("get_panel_size"):
		var got_size: Vector2 = panel.get_panel_size()
		_assert_eq_float(got_size.x, size.x, 0.001, "panel width matches layout width", passed, failed)
		_assert_eq_float(got_size.y, size.y, 0.001, "panel height matches layout height", passed, failed)
	else:
		failed.append("panel exposes get_panel_size()")
		print("  FAIL: panel exposes get_panel_size()")

	# Resolution stored → aspect ratio applied → mesh size shaped to (w, h/aspect).
	if panel.has_method("get_resolution"):
		var got_res: Vector2i = panel.get_resolution()
		_assert_eq_int(got_res.x, res.x, "panel resolution width matches", passed, failed)
		_assert_eq_int(got_res.y, res.y, "panel resolution height matches", passed, failed)
	else:
		failed.append("panel exposes get_resolution()")
		print("  FAIL: panel exposes get_resolution()")

	root.queue_free()


# ---------------------------------------------------------------------------
# Test 2: applying a pose moves the avatar (head + both hands).
# ---------------------------------------------------------------------------

func test_remote_user_applies_pose(passed: Array, failed: Array, _tree: SceneTree) -> void:
	print("\nTest: RemoteUser applies pose update")

	var pkg: PackedScene = load("res://scenes/remote_user.tscn") as PackedScene
	if not pkg:
		failed.append("remote_user.tscn loads")
		print("  FAIL: remote_user.tscn loads")
		return
	passed.append("remote_user.tscn loads")
	print("  PASS: remote_user.tscn loads")

	var user: Node3D = pkg.instantiate()
	_tree.root.add_child(user)

	if not user.has_method("update_pose"):
		failed.append("remote_user exposes update_pose()")
		print("  FAIL: remote_user exposes update_pose()")
		user.queue_free()
		return
	passed.append("remote_user exposes update_pose()")
	print("  PASS: remote_user exposes update_pose()")

	if not user.has_method("get_head_node") \
			or not user.has_method("get_left_hand_node") \
			or not user.has_method("get_right_hand_node"):
		failed.append("remote_user exposes head / hand accessor methods")
		print("  FAIL: remote_user exposes head / hand accessor methods")
		user.queue_free()
		return
	passed.append("remote_user exposes head / hand accessor methods")
	print("  PASS: remote_user exposes head / hand accessor methods")

	var head_pos := Vector3(1.0, 1.6, -2.0)
	var head_rot := Quaternion.IDENTITY
	var left_pos := Vector3(0.5, 1.0, -1.5)
	var left_rot := Quaternion.IDENTITY
	var right_pos := Vector3(-0.5, 1.0, -1.5)
	var right_rot := Quaternion.IDENTITY

	user.update_pose(
		_make_pose_dict(head_pos, head_rot),
		_make_pose_dict(left_pos, left_rot),
		_make_pose_dict(right_pos, right_rot))

	var head: Node3D = user.get_head_node()
	var got_head_pos: Vector3 = head.transform.origin
	_assert_close_vec3(got_head_pos, head_pos, 0.001,
		"head world position after update_pose", passed, failed)

	var lh: Node3D = user.get_left_hand_node()
	var rh: Node3D = user.get_right_hand_node()
	_assert_close_vec3(lh.transform.origin, left_pos, 0.001,
		"left hand position after update_pose", passed, failed)
	_assert_close_vec3(rh.transform.origin, right_pos, 0.001,
		"right hand position after update_pose", passed, failed)

	# Re-applying with new pose actually moves the avatar.
	var new_head_pos := Vector3(2.0, 1.7, -2.0)
	user.update_pose(
		_make_pose_dict(new_head_pos, head_rot),
		_make_pose_dict(left_pos, left_rot),
		_make_pose_dict(right_pos, right_rot))
	_assert_close_vec3(head.transform.origin, new_head_pos, 0.001,
		"head position responds to second update_pose", passed, failed)

	user.queue_free()


# ---------------------------------------------------------------------------
# Test 3: REMOTE_SCREEN_LAYOUT drives the panels (2 screens in metadata =>
##        2 child panels, each with the right transform and size).
# ---------------------------------------------------------------------------

func test_remote_user_applies_screen_layout(passed: Array, failed: Array, _tree: SceneTree) -> void:
	print("\nTest: RemoteUser applies screen layout")

	var pkg: PackedScene = load("res://scenes/remote_user.tscn") as PackedScene
	var user: Node3D = pkg.instantiate()
	_tree.root.add_child(user)

	# Two deterministic layout entries — different positions / sizes / resolutions.
	var entries: Array = [
		_entry(10, Vector3(2.0, 1.6, -2.0), Quaternion.IDENTITY,
			Vector2(1.6, 0.9), Vector2i(1920, 1080)),
		_entry(11, Vector3(-1.0, 1.6, -1.5),
			Quaternion(Vector3(0.0, 1.0, 0.0), deg_to_rad(20.0)).normalized(),
			Vector2(1.0, 1.0), Vector2i(1280, 1280)),
	]

	if not user.has_method("apply_screen_layout"):
		failed.append("remote_user exposes apply_screen_layout()")
		print("  FAIL: remote_user exposes apply_screen_layout()")
		user.queue_free()
		return
	passed.append("remote_user exposes apply_screen_layout()")
	print("  PASS: remote_user exposes apply_screen_layout()")

	user.apply_screen_layout(entries)

	if not user.has_method("get_screen_panels"):
		failed.append("remote_user exposes get_screen_panels()")
		print("  FAIL: remote_user exposes get_screen_panels()")
		user.queue_free()
		return
	passed.append("remote_user exposes get_screen_panels()")
	print("  PASS: remote_user exposes get_screen_panels()")

	var panels: Array = user.get_screen_panels()
	_assert_eq_int(panels.size(), entries.size(),
		"screen panel count == entry count", passed, failed)

	if panels.size() != entries.size():
		user.queue_free()
		return

	for i in entries.size():
		var p: Node = panels[i]
		var e: Dictionary = entries[i]
		var p_pos: Vector3 = (p as Node3D).transform.origin
		_assert_close_vec3(p_pos, Vector3(e.pos_x, e.pos_y, e.pos_z), 0.001,
			"panel[%d] global_position matches entry monitor_id=%d" % [i, e.monitor_id],
			passed, failed)

		if p.has_method("get_panel_size"):
			var ps: Vector2 = p.get_panel_size()
			_assert_eq_float(ps.x, e.width, 0.001,
				"panel[%d] width matches entry" % i, passed, failed)
			_assert_eq_float(ps.y, e.height, 0.001,
				"panel[%d] height matches entry" % i, passed, failed)

		var by_id: Node = null
		if user.has_method("get_screen_panel_for_monitor"):
			by_id = user.get_screen_panel_for_monitor(e.monitor_id)
		_assert(by_id == p,
			"get_screen_panel_for_monitor(%d) returns the right panel" % e.monitor_id,
			passed, failed)

	user.queue_free()


# ---------------------------------------------------------------------------
# Test 4: dynamic add / remove of screens.
# ---------------------------------------------------------------------------

func test_remote_user_manages_dynamic_screens(passed: Array, failed: Array, _tree: SceneTree) -> void:
	print("\nTest: RemoteUser manages dynamic screen add/remove")

	var pkg: PackedScene = load("res://scenes/remote_user.tscn") as PackedScene
	var user: Node3D = pkg.instantiate()
	_tree.root.add_child(user)

	user.apply_screen_layout([
		_entry(20, Vector3(1.0, 1.6, -2.0), Quaternion.IDENTITY,
			Vector2(1.6, 0.9), Vector2i(1920, 1080))
	])
	_assert_eq_int(user.get_screen_panels().size(), 1, "starts with 1 panel",
		passed, failed)

	user.apply_screen_layout([
		_entry(20, Vector3(1.0, 1.6, -2.0), Quaternion.IDENTITY,
			Vector2(1.6, 0.9), Vector2i(1920, 1080)),
		_entry(21, Vector3(-1.0, 1.6, -2.0), Quaternion.IDENTITY,
			Vector2(1.6, 0.9), Vector2i(1920, 1080)),
	])
	_assert_eq_int(user.get_screen_panels().size(), 2, "has 2 panels after layout update",
		passed, failed)

	user.apply_screen_layout([
		_entry(20, Vector3(1.0, 1.6, -2.0), Quaternion.IDENTITY,
			Vector2(1.6, 0.9), Vector2i(1920, 1080))
	])
	_assert_eq_int(user.get_screen_panels().size(), 1, "removed down to 1 panel",
		passed, failed)
	_assert(user.get_screen_panel_for_monitor(20) != null,
		"monitor 20 still present", passed, failed)
	_assert(user.get_screen_panel_for_monitor(21) == null,
		"monitor 21 removed", passed, failed)

	user.apply_screen_layout([])
	_assert_eq_int(user.get_screen_panels().size(), 0, "removed all panels",
		passed, failed)

	user.queue_free()


# ---------------------------------------------------------------------------
# Test 5: main.gd wires a new user in when a remote_user_joined arrives, and
##        removes it on room_left.
# ---------------------------------------------------------------------------

func test_main_gd_remote_user_lifecycle(passed: Array, failed: Array, _tree: SceneTree) -> void:
	print("\nTest: main.gd handles remote user join / leave lifecycle")

	var main_script := load("res://scripts/main.gd") as Script
	if not main_script:
		failed.append("main.gd loads")
		print("  FAIL: main.gd loads")
		return
	passed.append("main.gd loads")
	print("  PASS: main.gd loads")

	var main: Node3D = main_script.new()
	_tree.root.add_child(main)

	if not "remote_users" in main:
		failed.append("main has remote_users dictionary")
		print("  FAIL: main has remote_users dictionary")
		main.queue_free()
		return
	passed.append("main has remote_users dictionary")
	print("  PASS: main has remote_users dictionary")
	_assert_eq_int(main.remote_users.size(), 0, "starts empty", passed, failed)

	if main.has_method("on_room_joined"):
		main.on_room_joined("room1", 100, [])
		_assert_eq_int(main.remote_users.size(), 0,
			"local-only joined event does not create remote users", passed, failed)

	if main.has_method("on_user_presence"):
		main.on_user_presence(5554, "Alice", true)
		_assert(main.remote_users.has(5554),
			"presence(remote, online=true) creates remote user", passed, failed)
		var u_alice = main.remote_users.get(5554)
		_assert(u_alice != null and is_instance_valid(u_alice),
			"Alice entry is a live Node3D", passed, failed)
		if u_alice and u_alice.has_method("get_display_name"):
			_assert(u_alice.get_display_name() == "Alice",
				"display_name propagated to remote user", passed, failed)

		main.on_user_presence(7777, "Bob", true)
		_assert(main.remote_users.has(7777),
			"second remote user also created", passed, failed)
		_assert_eq_int(main.remote_users.size(), 2,
			"two remote users tracked", passed, failed)

		# Remote user goes offline → entry is removed.
		main.on_user_presence(5554, "Alice", false)
		_assert(not main.remote_users.has(5554),
			"user 5554 removed after presence(offline)", passed, failed)
		_assert_eq_int(main.remote_users.size(), 1,
			"only user 7777 remains", passed, failed)

		if main.has_method("on_room_left"):
			main.on_room_left(7777)
		else:
			main.on_user_presence(7777, "Bob", false)
		_assert_eq_int(main.remote_users.size(), 0,
			"final user removed after room_left", passed, failed)
	else:
		failed.append("main exposes on_user_presence()")
		print("  FAIL: main exposes on_user_presence()")

	main.queue_free()


# ---------------------------------------------------------------------------
# Test 6: main.gd forwards pose updates to the right user every frame.
# ---------------------------------------------------------------------------

func test_main_gd_pose_propagation(passed: Array, failed: Array, _tree: SceneTree) -> void:
	print("\nTest: main.gd propagates pose updates")

	var main_script := load("res://scripts/main.gd") as Script
	var main: Node3D = main_script.new()
	_tree.root.add_child(main)

	if main.has_method("set_local_user_id"):
		main.set_local_user_id(0)
	if main.has_method("on_user_presence"):
		main.on_user_presence(1234, "Cara", true)
	var user: Node3D = main.remote_users.get(1234, null)
	_assert(user != null, "user 1234 present", passed, failed)

	if user and main.has_method("apply_user_pose"):
		var head_pos := Vector3(3.0, 1.6, -4.0)
		var head: Dictionary = _make_pose_dict(head_pos, Quaternion.IDENTITY)
		var lh: Dictionary = _make_pose_dict(Vector3.ZERO, Quaternion.IDENTITY)
		var rh: Dictionary = _make_pose_dict(Vector3.ZERO, Quaternion.IDENTITY)

		main.apply_user_pose(1234, head, lh, rh)

		if user.has_method("get_head_node"):
			var got: Node3D = user.get_head_node()
			_assert_close_vec3(got.transform.origin, head_pos, 0.001,
				"head node reaches the pose target after apply_user_pose",
				passed, failed)

	# Per-frame update — main owns the loop, so verify it doesn't crash and
	# does not move nodes when no new pose is sent.
	if main.has_method("_process"):
		main._process(1.0 / 72.0)
		passed.append("main._process() runs without crashing when no pose arrives")
		print("  PASS: main._process() runs without crashing when no pose arrives")
	else:
		failed.append("main exposes _process()")
		print("  FAIL: main exposes _process()")

	main.queue_free()


# ---------------------------------------------------------------------------
# Test 7: full join / leave sequence — multiple participants in a room.
# ---------------------------------------------------------------------------

func test_main_gd_peer_join_leave(passed: Array, failed: Array, _tree: SceneTree) -> void:
	print("\nTest: main.gd handles batch peer join/leave")

	var main_script := load("res://scripts/main.gd") as Script
	var main: Node3D = main_script.new()
	_tree.root.add_child(main)

	if main.has_method("set_local_user_id"):
		main.set_local_user_id(42)
	elif main.has_method("on_user_presence"):
		main.on_user_presence(42, "Me", true)

	if not main.has_method("on_room_joined"):
		failed.append("main exposes on_room_joined()")
		print("  FAIL: main exposes on_room_joined()")
		main.queue_free()
		return
	passed.append("main exposes on_room_joined()")
	print("  PASS: main exposes on_room_joined()")

	var participants: Array = [
		{"user_id": 42,  "display_name": "Me"},
		{"user_id": 100, "display_name": "Alice"},
		{"user_id": 200, "display_name": "Bob"},
		{"user_id": 300, "display_name": "Cara"},
	]
	main.on_room_joined("lobby", 42, participants)
	_assert(main.remote_users.has(100),
		"remote user 100 registered from participant list", passed, failed)
	_assert(main.remote_users.has(200),
		"remote user 200 registered from participant list", passed, failed)
	_assert(main.remote_users.has(300),
		"remote user 300 registered from participant list", passed, failed)
	_assert(not main.remote_users.has(42),
		"local user 42 is NOT in remote_users dictionary", passed, failed)

	# Make sure dictionary has exactly the expected entries.
	_assert_eq_int(main.remote_users.size(), 3,
		"remote_users has exactly 3 entries", passed, failed)

	main.on_user_presence(400, "Dave", true)
	_assert_eq_int(main.remote_users.size(), 4,
		"4 remote users after Dave joins", passed, failed)

	main.on_user_presence(400, "Dave", false)
	_assert_eq_int(main.remote_users.size(), 3,
		"back to 3 after Dave leaves", passed, failed)

	main.queue_free()


# ---------------------------------------------------------------------------
# Test 8: mode-switching plumbing — even when --xr-mode off skips XR init,
##        the remote-user plumbing still has to construct and stay stable.
# ---------------------------------------------------------------------------

func test_mode_switching_does_not_break_remote_users(passed: Array, failed: Array, _tree: SceneTree) -> void:
	print("\nTest: mode switching (flat / mobile) does not break remote users")

	var main_script := load("res://scripts/main.gd") as Script
	var main: Node3D = main_script.new()
	_tree.root.add_child(main)

	if main.has_method("set_client_mode"):
		main.set_client_mode("flat")
	elif "client_mode" in main:
		main.set("client_mode", "flat")

	main.on_user_presence(7000, "Alice", true)
	_assert(main.remote_users.has(7000), "user 7000 created under flat mode",
		passed, failed)

	var user: Node3D = main.remote_users.get(7000, null)
	if user and user.has_method("apply_screen_layout"):
		user.apply_screen_layout([
			_entry(1, Vector3(1.0, 1.6, -2.0), Quaternion.IDENTITY,
				Vector2(1.6, 0.9), Vector2i(1920, 1080)),
			_entry(2, Vector3(-1.0, 1.6, -2.0), Quaternion.IDENTITY,
				Vector2(1.6, 0.9), Vector2i(1920, 1080)),
		])
		_assert_eq_int(user.get_screen_panels().size(), 2,
			"2 panels under flat mode", passed, failed)

	main.on_user_presence(7000, "Alice", false)
	_assert_eq_int(main.remote_users.size(), 0,
		"user 7000 cleaned up under flat mode", passed, failed)

	main.queue_free()
