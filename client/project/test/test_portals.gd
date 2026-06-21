## Tests for passthrough portals (portal.gd + portal_manager.gd).
## Run headlessly via the project test runner:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
##
## Covers: shape/size geometry, size clamping, the keyboard portal, the
## MAX_PORTALS limit, add/remove/clear, and ray hit-testing.

extends RefCounted

const PortalScript := preload("res://scripts/portal.gd")
const ManagerScript := preload("res://scripts/portal_manager.gd")

func _assert(condition: bool, message: String, passed: Array, failed: Array) -> void:
	if condition:
		passed.append(message)
		print("  PASS: %s" % message)
	else:
		failed.append(message)
		print("  FAIL: %s" % message)

func _assert_eq_int(actual: int, expected: int, message: String,
		passed: Array, failed: Array) -> void:
	_assert(actual == expected, "%s (got %d, expected %d)" % [message, actual, expected],
		passed, failed)

func run_all(results: Dictionary, tree: SceneTree) -> void:
	print("\n=== Passthrough Portal Tests ===")
	var passed: Array = []
	var failed: Array = []

	test_portal_shapes(passed, failed, tree)
	test_portal_size_clamp_and_square(passed, failed, tree)
	test_manager_limit_and_lifecycle(passed, failed, tree)
	test_keyboard_portal(passed, failed, tree)
	test_ray_hit(passed, failed, tree)

	print("\n=== Portal Results: Passed %d / Failed %d ===" % [passed.size(), failed.size()])
	results["passed"] = passed.size()
	results["failed"] = failed.size()
	results["failed_messages"] = failed.duplicate()

func test_portal_shapes(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: Portal builds geometry + material per shape")
	for shape in [PortalScript.Shape.RECTANGLE, PortalScript.Shape.SQUARE, PortalScript.Shape.CIRCLE]:
		var portal = PortalScript.new()
		tree.root.add_child(portal)
		portal.setup(shape, Vector2(0.5, 0.3))
		_assert(portal.mesh is PlaneMesh, "shape %d builds a PlaneMesh" % shape, passed, failed)
		_assert(portal.material_override is ShaderMaterial,
			"shape %d has a ShaderMaterial" % shape, passed, failed)
		var mat: ShaderMaterial = portal.material_override
		var want_circle: int = 1 if shape == PortalScript.Shape.CIRCLE else 0
		_assert_eq_int(int(mat.get_shader_parameter("is_circle")), want_circle,
			"shape %d is_circle param" % shape, passed, failed)
		_assert(portal.get_shape() == shape, "shape %d round-trips via get_shape()" % shape, passed, failed)
		portal.queue_free()

func test_portal_size_clamp_and_square(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: Portal size clamping + square/circle aspect lock")
	var portal = PortalScript.new()
	tree.root.add_child(portal)

	# Rectangle keeps independent w/h, clamped to [MIN, MAX].
	portal.set_shape(PortalScript.Shape.RECTANGLE)
	portal.set_size(Vector2(99.0, 0.001))
	_assert(portal.get_size().x <= PortalScript.MAX_SIZE + 0.0001,
		"width clamped to MAX_SIZE", passed, failed)
	_assert(portal.get_size().y >= PortalScript.MIN_SIZE - 0.0001,
		"height clamped to MIN_SIZE", passed, failed)

	# Square forces 1:1.
	portal.set_shape(PortalScript.Shape.SQUARE)
	portal.set_size(Vector2(0.8, 0.2))
	_assert(abs(portal.get_size().x - portal.get_size().y) < 0.0001,
		"square portal is 1:1", passed, failed)

	# Circle forces 1:1 too.
	portal.set_shape(PortalScript.Shape.CIRCLE)
	portal.set_size(Vector2(0.7, 0.3))
	_assert(abs(portal.get_size().x - portal.get_size().y) < 0.0001,
		"circle portal is 1:1", passed, failed)

	portal.queue_free()

func test_manager_limit_and_lifecycle(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: PortalManager enforces MAX_PORTALS + add/remove/clear")
	var mgr = ManagerScript.new()
	tree.root.add_child(mgr)

	var created: Array = []
	for i in range(ManagerScript.MAX_PORTALS):
		var p = mgr.add_portal(PortalScript.Shape.RECTANGLE)
		_assert(p != null, "portal %d created under the limit" % i, passed, failed)
		created.append(p)
	_assert_eq_int(mgr.get_portal_count(), ManagerScript.MAX_PORTALS,
		"manager holds MAX_PORTALS", passed, failed)

	# One more must be rejected.
	var overflow = mgr.add_portal(PortalScript.Shape.CIRCLE)
	_assert(overflow == null, "portal beyond MAX_PORTALS rejected", passed, failed)
	_assert_eq_int(mgr.get_portal_count(), ManagerScript.MAX_PORTALS,
		"count unchanged after rejected add", passed, failed)

	# Remove one → can add again.
	_assert(mgr.remove_portal(created[0]), "remove_portal returns true", passed, failed)
	_assert_eq_int(mgr.get_portal_count(), ManagerScript.MAX_PORTALS - 1,
		"count decremented after remove", passed, failed)
	_assert(mgr.add_portal(PortalScript.Shape.SQUARE) != null,
		"can add again after a removal", passed, failed)

	# Removing an already-removed portal is false (idempotent).
	_assert(not mgr.remove_portal(created[0]), "remove of already-removed is false", passed, failed)

	mgr.clear_portals()
	_assert_eq_int(mgr.get_portal_count(), 0, "clear_portals empties the set", passed, failed)

	mgr.queue_free()

func test_keyboard_portal(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: keyboard portal is a singleton rectangle")
	var mgr = ManagerScript.new()
	tree.root.add_child(mgr)

	var kb = mgr.create_keyboard_portal()
	_assert(kb != null, "keyboard portal created", passed, failed)
	_assert(kb.is_keyboard_portal(), "flagged as keyboard portal", passed, failed)
	_assert(kb.get_shape() == PortalScript.Shape.RECTANGLE, "keyboard portal is a rectangle", passed, failed)
	_assert(mgr.has_keyboard_portal(), "manager reports a keyboard portal", passed, failed)

	# Calling again returns the SAME portal (no duplicate).
	var kb2 = mgr.create_keyboard_portal()
	_assert(kb2 == kb, "create_keyboard_portal is idempotent", passed, failed)
	_assert_eq_int(mgr.get_portal_count(), 1, "only one portal exists", passed, failed)

	# Removing it clears the keyboard-portal reference.
	mgr.remove_portal(kb)
	_assert(not mgr.has_keyboard_portal(), "keyboard portal reference cleared on remove", passed, failed)

	mgr.queue_free()

func test_ray_hit(_passed: Array, _failed: Array, _tree: SceneTree) -> void:
	print("\nTest: portal ray hit-testing (pure geometry)")
	var passed := _passed
	var failed := _failed

	# A 0.6 x 0.35 rectangle 2 m in front (facing +Z toward the origin).
	var xform := Transform3D(Basis(), Vector3(0.0, 1.5, -2.0))
	var size := Vector2(0.6, 0.35)

	# Ray straight at the portal centre.
	var hit := ManagerScript.ray_hit_rect(xform, size, Vector3(0.0, 1.5, 0.0), Vector3(0.0, 0.0, -1.0))
	_assert(hit.get("valid", false), "ray through centre hits the portal", passed, failed)
	if hit.get("valid", false):
		_assert(abs(float(hit.get("distance", 0.0)) - 2.0) < 0.01, "hit distance ≈ 2 m", passed, failed)

	# Ray pointing away misses.
	var miss := ManagerScript.ray_hit_rect(xform, size, Vector3(0.0, 1.5, 0.0), Vector3(0.0, 0.0, 1.0))
	_assert(not miss.get("valid", false), "ray pointing away misses", passed, failed)

	# Ray offset well outside the rectangle misses.
	var miss2 := ManagerScript.ray_hit_rect(xform, size, Vector3(3.0, 1.5, 0.0), Vector3(0.0, 0.0, -1.0))
	_assert(not miss2.get("valid", false), "ray well outside the rect misses", passed, failed)

	# Edge cases: half-width is 0.3 m, so x=0.29 is inside and x=0.31 is outside.
	var inside := ManagerScript.ray_hit_rect(xform, size, Vector3(0.29, 1.5, 0.0), Vector3(0.0, 0.0, -1.0))
	_assert(inside.get("valid", false), "ray at x=0.29 m is inside the rect", passed, failed)
	var outside := ManagerScript.ray_hit_rect(xform, size, Vector3(0.31, 1.5, 0.0), Vector3(0.0, 0.0, -1.0))
	_assert(not outside.get("valid", false), "ray at x=0.31 m is outside the rect", passed, failed)

	# Parallel ray (in the plane) does not intersect.
	var parallel := ManagerScript.ray_hit_rect(xform, size, Vector3(0.0, 1.5, -2.0), Vector3(1.0, 0.0, 0.0))
	_assert(not parallel.get("valid", false), "ray parallel to the portal plane misses", passed, failed)

	# Empty manager returns invalid from the instance method.
	var mgr = ManagerScript.new()
	_tree.root.add_child(mgr)
	var empty := mgr.get_portal_hit_from_ray(Vector3.ZERO, Vector3(0, 0, -1))
	_assert(not empty.get("valid", false), "empty manager reports no hit", passed, failed)
	mgr.queue_free()
