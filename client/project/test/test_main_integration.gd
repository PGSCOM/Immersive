## Integration tests for main.gd's world-feature + multi-user wiring.
## Run headlessly via the project test runner:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
##
## Instantiates the real main.gd controller (bare, as the harness does) and checks
## that the new managers are created and that the public feature actions
## (environment cycle, portals, keyboard portal, whiteboard) and the multi-user
## signal wiring (presence → avatar, pose → update, leave → removal) work end to
## end. XR nodes are absent here, so this exercises the null-safe paths.

extends RefCounted

func _assert(condition: bool, message: String, passed: Array, failed: Array) -> void:
	if condition:
		passed.append(message)
		print("  PASS: %s" % message)
	else:
		failed.append(message)
		print("  FAIL: %s" % message)

func _pose() -> Dictionary:
	return {"pos_x": 1.0, "pos_y": 1.6, "pos_z": -2.0, "rot_w": 1.0, "rot_x": 0.0, "rot_y": 0.0, "rot_z": 0.0}

func run_all(results: Dictionary, tree: SceneTree) -> void:
	print("\n=== main.gd Integration Tests ===")
	var passed: Array = []
	var failed: Array = []

	var main: Node3D = load("res://scripts/main.gd").new()
	tree.root.add_child(main)
	# This harness defers _ready(); force the one-time setup (idempotent guard).
	main._ready()

	# Managers are created during _ready().
	_assert(main.portal_manager != null, "portal_manager created", passed, failed)
	_assert(main.environment_manager != null, "environment_manager created", passed, failed)
	_assert(main.locomotion != null, "locomotion created", passed, failed)
	_assert(main.signaling_client != null, "signaling_client created", passed, failed)
	_assert(main.webrtc_manager != null, "webrtc_manager created", passed, failed)
	_assert(main.multiuser != null, "multiuser manager created", passed, failed)

	# Environment cycling.
	if main.environment_manager:
		var before: int = main.environment_manager.get_current_index()
		main.cycle_environment()
		_assert(main.environment_manager.get_current_index() != before,
			"cycle_environment advances the environment", passed, failed)

	# Passthrough portals.
	var p = main.add_passthrough_portal(0)
	_assert(p != null, "add_passthrough_portal returns a portal", passed, failed)
	_assert(main.portal_manager.get_portal_count() == 1, "portal registered with the manager", passed, failed)

	var kb = main.create_keyboard_portal()
	_assert(kb != null and kb.is_keyboard_portal(), "keyboard portal created + flagged", passed, failed)
	_assert(main.portal_manager.has_keyboard_portal(), "manager tracks the keyboard portal", passed, failed)

	# Whiteboard toggle.
	main.toggle_whiteboard()
	_assert(main.whiteboard != null and main.whiteboard.visible, "whiteboard created + shown", passed, failed)
	main.toggle_whiteboard()
	_assert(not main.whiteboard.visible, "whiteboard hidden on second toggle", passed, failed)

	# Drawing a local stroke (board sits at the origin in the headless harness, so a
	# ray down -Z from +Z hits its centre) commits one stroke; a remote stroke + a
	# remote clear are applied via the multi-user wiring.
	main.toggle_whiteboard()  # show again
	if main.is_whiteboard_active():
		main.draw_on_whiteboard(Vector3(0, 0, 1), Vector3(0, 0, -1), true)
		main.draw_on_whiteboard(Vector3(0, 0, 1), Vector3(0, 0, -1), true)
		main.draw_on_whiteboard(Vector3(0, 0, 1), Vector3(0, 0, -1), false)
		_assert(main.whiteboard.get_stroke_count() == 1, "local whiteboard stroke committed", passed, failed)
	main._on_remote_whiteboard_stroke(99, {"user_id": 99, "color": [0.0, 1.0, 0.0], "points": [0.2, 0.2, 0.8, 0.8]})
	_assert(main.whiteboard.get_stroke_count() >= 2, "remote whiteboard stroke applied", passed, failed)
	main._on_remote_whiteboard_clear(99)
	_assert(main.whiteboard.get_stroke_count() == 0, "remote whiteboard clear applied", passed, failed)

	# Multi-user wiring: presence → avatar, pose → update, leave → removal.
	main.multiuser.remote_presence.emit(55, "Zoe", true)
	_assert(main.remote_users.has(55), "multiuser presence wired to avatar creation", passed, failed)

	main.multiuser.remote_pose.emit(55, _pose(), _pose(), _pose())
	var avatar = main.remote_users.get(55, null)
	if avatar and avatar.has_method("get_head_node"):
		var head: Node3D = avatar.get_head_node()
		_assert(head.transform.origin.distance_to(Vector3(1.0, 1.6, -2.0)) < 0.001,
			"multiuser pose wired to avatar movement", passed, failed)

	main.multiuser.user_left.emit(55)
	_assert(not main.remote_users.has(55), "user_left removes the avatar", passed, failed)

	# Pose broadcast is a safe no-op when not in a room (no crash, no send).
	main._broadcast_local_pose(1.0)
	_assert(main.multiuser.get_local_user_id() == -1, "pose broadcast inert outside a room", passed, failed)

	# Snap-turn / teleport public methods are null-safe without XR nodes.
	main.snap_turn(30.0)
	main.teleport_to(Vector3(1, 0, 1))
	passed.append("snap_turn / teleport_to are null-safe without XR")
	print("  PASS: snap_turn / teleport_to are null-safe without XR")

	main.queue_free()

	print("\n=== main.gd Integration Results: Passed %d / Failed %d ===" % [passed.size(), failed.size()])
	results["passed"] = passed.size()
	results["failed"] = failed.size()
	results["failed_messages"] = failed.duplicate()
