## Tests for the themed environment manager (environment_manager.gd).
## Run headlessly via the project test runner:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
##
## Covers: catalogue queries, switching (index/id/next/prev wrap), Environment
## building, applying to a WorldEnvironment, and the weekly rotation schedule.

extends RefCounted

const EnvScript := preload("res://scripts/environment_manager.gd")

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
	print("\n=== Environment Manager Tests ===")
	var passed: Array = []
	var failed: Array = []

	test_catalogue(passed, failed, tree)
	test_switching(passed, failed, tree)
	test_build_and_apply(passed, failed, tree)
	test_weekly_rotation(passed, failed, tree)

	print("\n=== Environment Results: Passed %d / Failed %d ===" % [passed.size(), failed.size()])
	results["passed"] = passed.size()
	results["failed"] = failed.size()
	results["failed_messages"] = failed.duplicate()

func test_catalogue(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: environment catalogue")
	var mgr = EnvScript.new()
	tree.root.add_child(mgr)

	_assert(mgr.get_environment_count() >= 5, "at least 5 themed environments", passed, failed)
	_assert(mgr.get_environment_names().size() == mgr.get_environment_count(),
		"names match count", passed, failed)
	_assert(mgr.get_environment_ids().has("cafe"), "catalogue has a café", passed, failed)
	_assert(mgr.get_environment_ids().has("space"), "catalogue has a space lounge", passed, failed)
	_assert(mgr.index_of_id("starship") >= 0, "index_of_id resolves starship", passed, failed)
	_assert(mgr.index_of_id("nonexistent") == -1, "unknown id returns -1", passed, failed)

	mgr.queue_free()

func test_switching(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: environment switching")
	var mgr = EnvScript.new()
	tree.root.add_child(mgr)

	_assert_eq_int(mgr.get_current_index(), 0, "starts at index 0", passed, failed)

	_assert(mgr.set_environment(2), "set_environment(2) succeeds", passed, failed)
	_assert_eq_int(mgr.get_current_index(), 2, "current index is 2", passed, failed)

	_assert(not mgr.set_environment(999), "out-of-range set rejected", passed, failed)
	_assert_eq_int(mgr.get_current_index(), 2, "index unchanged after rejected set", passed, failed)

	_assert(mgr.set_environment_by_id("cafe"), "set_environment_by_id(cafe) succeeds", passed, failed)
	_assert(mgr.get_current_id() == "cafe", "current id is cafe", passed, failed)
	_assert(not mgr.set_environment_by_id("nope"), "unknown id rejected", passed, failed)

	# next / previous wrap around.
	var count := mgr.get_environment_count()
	mgr.set_environment(count - 1)
	_assert_eq_int(mgr.next_environment(), 0, "next wraps from last to first", passed, failed)
	_assert_eq_int(mgr.previous_environment(), count - 1, "previous wraps from first to last", passed, failed)

	# Signal fires on change.
	var captured := {"idx": -1, "id": ""}
	mgr.environment_changed.connect(func(i, id): captured["idx"] = i; captured["id"] = id)
	mgr.set_environment(1)
	_assert_eq_int(int(captured["idx"]), 1, "environment_changed emits the new index", passed, failed)
	_assert(String(captured["id"]) == mgr.get_current_id(), "signal id matches current", passed, failed)

	mgr.queue_free()

func test_build_and_apply(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: building + applying Environment resources")
	var mgr = EnvScript.new()
	tree.root.add_child(mgr)

	var env := mgr.build_environment(1)
	_assert(env is Environment, "build_environment returns an Environment", passed, failed)
	_assert(env.background_mode == Environment.BG_SKY, "themed environment uses a sky", passed, failed)
	_assert(env.sky != null, "environment has a Sky", passed, failed)

	# Applying to a bound WorldEnvironment updates its resource.
	var we := WorldEnvironment.new()
	tree.root.add_child(we)
	mgr.set_world_environment(we)
	mgr.set_environment_by_id("lodge")
	_assert(we.environment != null, "WorldEnvironment receives an Environment", passed, failed)
	_assert(we.environment.fog_enabled, "lodge enables fog", passed, failed)

	# Passthrough swaps to a transparent (clear) background, then restores the sky.
	mgr.set_passthrough(true)
	_assert(we.environment.background_mode == Environment.BG_CLEAR_COLOR,
		"passthrough uses a clear background", passed, failed)
	_assert(mgr.is_passthrough(), "passthrough flag set", passed, failed)
	mgr.set_passthrough(false)
	_assert(we.environment.background_mode == Environment.BG_SKY,
		"themed sky restored after passthrough off", passed, failed)

	we.queue_free()
	mgr.queue_free()

func test_weekly_rotation(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: weekly rotation schedule")
	var mgr = EnvScript.new()
	tree.root.add_child(mgr)

	var total := mgr.get_environment_count()

	# Starter: 2 environments; Pro: 5. Counts are honoured and clamped.
	_assert_eq_int(mgr.weekly_rotation(2, 0).size(), 2, "Starter rotation has 2 envs", passed, failed)
	_assert_eq_int(mgr.weekly_rotation(5, 0).size(), min(5, total), "Pro rotation has 5 envs", passed, failed)
	_assert_eq_int(mgr.weekly_rotation(999, 0).size(), total, "rotation clamps to catalogue size", passed, failed)
	_assert_eq_int(mgr.weekly_rotation(0, 0).size(), 0, "zero rotation is empty", passed, failed)

	# Deterministic for a given week, and it slides by one each week.
	var wk3a: Array = mgr.weekly_rotation(2, 3)
	var wk3b: Array = mgr.weekly_rotation(2, 3)
	_assert(wk3a == wk3b, "rotation is deterministic for a fixed week", passed, failed)

	var wk0: Array = mgr.weekly_rotation(2, 0)
	var wk1: Array = mgr.weekly_rotation(2, 1)
	_assert(int(wk1[0]) == (int(wk0[0]) + 1) % total, "window slides by one per week", passed, failed)

	# Indices are valid and in range.
	var ok := true
	for idx in mgr.weekly_rotation(total, 2):
		if int(idx) < 0 or int(idx) >= total:
			ok = false
	_assert(ok, "all rotation indices are in range", passed, failed)

	mgr.queue_free()
