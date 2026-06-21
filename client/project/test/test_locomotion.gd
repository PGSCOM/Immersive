## Tests for teleport + snap-turn locomotion (locomotion.gd).
## Run headlessly via the project test runner:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
##
## Covers the pure transform/geometry helpers (floor ray target, teleport origin
## delta keeping height, snap-turn rotation about the camera pivot).

extends RefCounted

const LocoScript := preload("res://scripts/locomotion.gd")

func _assert(condition: bool, message: String, passed: Array, failed: Array) -> void:
	if condition:
		passed.append(message)
		print("  PASS: %s" % message)
	else:
		failed.append(message)
		print("  FAIL: %s" % message)

func _close_vec(a: Vector3, b: Vector3, tol: float = 0.001) -> bool:
	return abs(a.x - b.x) <= tol and abs(a.y - b.y) <= tol and abs(a.z - b.z) <= tol

func run_all(results: Dictionary, _tree: SceneTree) -> void:
	print("\n=== Locomotion Tests ===")
	var passed: Array = []
	var failed: Array = []

	test_floor_target(passed, failed)
	test_teleport_transform(passed, failed)
	test_snap_turn_transform(passed, failed)

	print("\n=== Locomotion Results: Passed %d / Failed %d ===" % [passed.size(), failed.size()])
	results["passed"] = passed.size()
	results["failed"] = failed.size()
	results["failed_messages"] = failed.duplicate()

func test_floor_target(passed: Array, failed: Array) -> void:
	print("\nTest: floor ray target")

	# From 1.6 m high, aiming down-forward at 45° hits the floor 1.6 m ahead.
	var dir := Vector3(0.0, -1.0, -1.0).normalized()
	var hit := LocoScript.floor_target(Vector3(0.0, 1.6, 0.0), dir, 0.0)
	_assert(hit.get("valid", false), "down-forward ray hits the floor", passed, failed)
	if hit.get("valid", false):
		var p: Vector3 = hit["point"]
		_assert(abs(p.y) < 0.001, "hit point is on the floor plane", passed, failed)
		_assert(abs(p.z + 1.6) < 0.01, "hit lands 1.6 m ahead (z ≈ -1.6)", passed, failed)

	# A ray pointing up never hits the floor below.
	var up := LocoScript.floor_target(Vector3(0.0, 1.6, 0.0), Vector3(0.0, 1.0, -1.0).normalized(), 0.0)
	_assert(not up.get("valid", false), "upward ray yields no floor target", passed, failed)

	# A ray parallel to the floor never hits.
	var par := LocoScript.floor_target(Vector3(0.0, 1.6, 0.0), Vector3(0.0, 0.0, -1.0), 0.0)
	_assert(not par.get("valid", false), "horizontal ray yields no floor target", passed, failed)

	# Custom floor height is honoured.
	var raised := LocoScript.floor_target(Vector3(0.0, 2.0, 0.0), Vector3(0.0, -1.0, 0.0), 0.5)
	_assert(raised.get("valid", false) and abs(float(raised["point"].y) - 0.5) < 0.001,
		"custom floor height respected", passed, failed)

func test_teleport_transform(passed: Array, failed: Array) -> void:
	print("\nTest: teleport keeps height, moves only X/Z")

	# Origin at world zero; camera offset +0.2 in X and at 1.6 m height.
	var origin := Transform3D(Basis(), Vector3.ZERO)
	var camera_global := Vector3(0.2, 1.6, 0.0)
	var target := Vector3(3.0, 0.0, -4.0)

	var new_origin := LocoScript.teleport_origin_transform(origin, camera_global, target)

	# The camera should now sit over the target on X/Z (its world pos = origin + local
	# camera offset; here the local camera offset is camera_global - origin.origin).
	var camera_local := camera_global - origin.origin
	var new_camera_world := new_origin.origin + camera_local
	_assert(abs(new_camera_world.x - target.x) < 0.001, "camera X over target after teleport", passed, failed)
	_assert(abs(new_camera_world.z - target.z) < 0.001, "camera Z over target after teleport", passed, failed)
	_assert(abs(new_camera_world.y - camera_global.y) < 0.001, "camera height unchanged", passed, failed)
	_assert(new_origin.basis.is_equal_approx(origin.basis), "orientation unchanged by teleport", passed, failed)

func test_snap_turn_transform(passed: Array, failed: Array) -> void:
	print("\nTest: snap-turn rotates about the camera pivot")

	var origin := Transform3D(Basis(), Vector3(1.0, 0.0, 0.0))
	var pivot := Vector3(0.0, 1.6, 0.0)  # camera world position

	# A 90° turn about the pivot keeps the camera world position fixed.
	var turned := LocoScript.snap_turn_transform(origin, pivot, 90.0)
	# The camera is a child of the origin; its world position is origin * cam_local.
	# After turning about the pivot (= camera position), it must stay at the pivot.
	var cam_local := origin.affine_inverse() * pivot
	var cam_after := turned * cam_local
	_assert(_close_vec(cam_after, pivot, 0.01), "camera stays at pivot through a snap-turn", passed, failed)

	# The basis is rotated by 90° about Y (a forward -Z maps toward -X).
	var fwd_before := -origin.basis.z
	var fwd_after := -turned.basis.z
	_assert(abs(fwd_before.angle_to(fwd_after) - deg_to_rad(90.0)) < 0.01,
		"view direction rotated by 90°", passed, failed)

	# Default increment is the comfort 30°.
	_assert(abs(LocoScript.SNAP_TURN_DEGREES - 30.0) < 0.001, "default snap-turn is 30°", passed, failed)

	# Two opposite turns cancel out.
	var there := LocoScript.snap_turn_transform(origin, pivot, 30.0)
	var back := LocoScript.snap_turn_transform(there, pivot, -30.0)
	_assert(back.is_equal_approx(origin), "opposite snap-turns cancel", passed, failed)
