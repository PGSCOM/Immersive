## Test runner for Immersive-2.
## Run with: godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
##
## Inline tests run in this SceneTree. External test classes are RefCounted
## subclasses with a `run_all(results, tree)` method, instantiated and called
## directly so they share the same SceneTree (mandatory — every test creates
## Node3Ds that must be parented under tree.root).

extends SceneTree

# Catalogue of external test suites (RefCounted subclasses with run_all()).
const EXTERNAL_SUITES := [
	"res://test/test_remote_users.gd",
	"res://test/test_privacy.gd",
	"res://test/test_hw_decode.gd",
	"res://test/test_portals.gd",
	"res://test/test_environments.gd",
	"res://test/test_locomotion.gd",
	"res://test/test_whiteboard.gd",
	"res://test/test_multiuser.gd",
	"res://test/test_keyboard_avatars.gd",
	"res://test/test_main_integration.gd",
]

# Aggregate result counters across all suites.
var _results: Dictionary = {"passed": 0, "failed": 0, "suites": {}}

func _init() -> void:
	print("=== Immersive-2 Test Suite ===\n")

	_run_inline_suites()
	_run_external_suites()

	print("\n=== Immersive-2 Aggregate Results ===")
	var total_passed := int(_results.get("passed", 0))
	var total_failed := int(_results.get("failed", 0))
	print("Total Passed: %d" % total_passed)
	print("Total Failed: %d" % total_failed)
	if total_failed > 0:
		print("\nFailures by suite:")
		for suite_name in _results["suites"]:
			var data = _results["suites"][suite_name]
			if int(data.get("failed", 0)) > 0:
				print("  - %s: %s" % [suite_name, str(data.get("failed_messages", []))])

	quit(0 if total_failed == 0 else 1)

# ---------------------------------------------------------------------------
# Inline tests (run in this process tree)
# ---------------------------------------------------------------------------

func _run_inline_suites() -> void:
	print("\n--- Inline Suites ---")
	_signal_suite()
	_protocol_suite()

func _signal_suite() -> void:
	print("\nTest: SignalingClient")
	var p: Array = []
	var f: Array = []
	var client = preload("res://scripts/signaling_client.gd").new()
	_assert(client != null, "SignalingClient instantiates", p, f)
	_assert(client.has_signal("connected_to_signaling"), "Has connected_to_signaling signal", p, f)
	_assert(client.has_signal("room_joined"), "Has room_joined signal", p, f)
	_assert(client.has_signal("user_pose_received"), "Has user_pose_received signal", p, f)
	_assert(client.has_signal("remote_screen_layout"), "Has remote_screen_layout signal", p, f)
	_assert(client.has_signal("screen_share_state"), "Has screen_share_state signal", p, f)
	_assert(client.has_signal("user_presence"), "Has user_presence signal", p, f)
	_record("signaling_client", p, f)

func _protocol_suite() -> void:
	print("\nTest: Protocol Constants")
	var p: Array = []
	var f: Array = []
	var proto = preload("res://scripts/protocol_constants.gd").new()
	_assert(proto.PROTOCOL_VERSION == 1, "PROTOCOL_VERSION == 1", p, f)
	_assert(proto.MSG_ROOM_JOIN == 0x50, "MSG_ROOM_JOIN == 0x50", p, f)
	_assert(proto.MSG_USER_POSE == 0x54, "MSG_USER_POSE == 0x54", p, f)
	_assert(proto.MSG_REMOTE_SCREEN_LAYOUT == 0x56, "MSG_REMOTE_SCREEN_LAYOUT == 0x56", p, f)
	_assert(proto.MSG_SCREEN_SHARE_STATE == 0x55, "MSG_SCREEN_SHARE_STATE == 0x55", p, f)
	_record("protocol_constants", p, f)

# ---------------------------------------------------------------------------
# External suites (RefCounted subclasses exposing run_all())
# ---------------------------------------------------------------------------

func _run_external_suites() -> void:
	print("\n--- External Suites ---")
	for suite_path in EXTERNAL_SUITES:
		print("\n--- %s ---" % suite_path)
		var script: Script = load(suite_path)
		if not script:
			print("  FAIL: missing %s" % suite_path)
			_results["suites"][suite_path] = {"passed": 0, "failed": 1, "failed_messages": ["missing script"]}
			_results["failed"] = int(_results["failed"]) + 1
			continue
		var instance: Object = script.new()
		if not instance.has_method("run_all"):
			print("  FAIL: %s has no run_all(results, tree) method" % suite_path)
			_results["suites"][suite_path] = {"passed": 0, "failed": 1, "failed_messages": ["missing run_all()"]}
			_results["failed"] = int(_results["failed"]) + 1
			continue
		var suite_results: Dictionary = {}
		instance.run_all(suite_results, self)
		var p := int(suite_results.get("passed", 0))
		var f_arr: Array = suite_results.get("failed_messages", [])
		_results["suites"][suite_path] = {
			"passed": p,
			"failed": f_arr.size() if f_arr is Array else int(suite_results.get("failed", 0)),
			"failed_messages": f_arr,
		}
		_results["passed"] = int(_results["passed"]) + p
		_results["failed"] = int(_results["failed"]) + (f_arr.size() if f_arr is Array else 0)
		print("  --> %s Passed: %d / Failed: %d" %
			[suite_path, p, f_arr.size() if f_arr is Array else 0])

# ---------------------------------------------------------------------------
# Generic assertion + recording helpers
# ---------------------------------------------------------------------------

func _assert(condition: bool, message: String, passed: Array, failed: Array) -> void:
	if condition:
		passed.append(message)
		print("  PASS: %s" % message)
	else:
		failed.append(message)
		print("  FAIL: %s" % message)

func _record(suite_name: String, passed: Array, failed: Array) -> void:
	var entry := {
		"passed": passed.size(),
		"failed": failed.size(),
		"failed_messages": failed.duplicate(),
	}
	_results["suites"][suite_name] = entry
	_results["passed"] = int(_results["passed"]) + passed.size()
	_results["failed"] = int(_results["failed"]) + failed.size()
