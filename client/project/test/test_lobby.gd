## Tests for the public lobby feature: signal contracts, data-flow wiring, and
## UI populate logic.  All tests run headlessly without a live WebSocket server.
##
## Run with:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd

extends RefCounted

func run_all(results: Dictionary, tree: SceneTree) -> void:
	var p: Array = []
	var f: Array = []

	_test_signaling_client_contracts(p, f)
	_test_multiuser_lobby_contracts(p, f, tree)
	_test_populate_lobby_empty(p, f, tree)
	_test_populate_lobby_with_rooms(p, f, tree)
	_test_populate_lobby_replaces_previous(p, f, tree)
	_test_overlay_lobby_signals(p, f, tree)

	results["passed"] = p.size()
	results["failed"] = f.size()
	results["failed_messages"] = f
	print("[test_lobby] Passed: %d / Failed: %d" % [p.size(), f.size()])

func _assert(cond: bool, msg: String, p: Array, f: Array) -> void:
	if cond:
		p.append(msg)
		print("  PASS: " + msg)
	else:
		f.append(msg)
		print("  FAIL: " + msg)

# ---------------------------------------------------------------------------
# SignalingClient contract
# ---------------------------------------------------------------------------

func _test_signaling_client_contracts(p: Array, f: Array) -> void:
	var sc = preload("res://scripts/signaling_client.gd").new()
	_assert(sc.has_signal("lobby_rooms_received"),
		"SignalingClient has lobby_rooms_received signal", p, f)
	_assert(sc.has_method("send_lobby_list"),
		"SignalingClient has send_lobby_list()", p, f)
	_assert(sc.has_method("send_room_join"),
		"SignalingClient has send_room_join() (with public param)", p, f)

# ---------------------------------------------------------------------------
# MultiuserManager contract
# ---------------------------------------------------------------------------

func _test_multiuser_lobby_contracts(p: Array, f: Array, tree: SceneTree) -> void:
	var mgr = preload("res://scripts/multiuser_manager.gd").new()
	tree.root.add_child(mgr)
	_assert(mgr.has_method("request_lobby"),
		"MultiuserManager.request_lobby() exists", p, f)
	_assert(mgr.has_signal("lobby_rooms_received"),
		"MultiuserManager has lobby_rooms_received signal", p, f)
	_assert(mgr.has_method("join"),
		"MultiuserManager.join() exists (with public param)", p, f)
	mgr.queue_free()

# ---------------------------------------------------------------------------
# populate_lobby: empty list
# ---------------------------------------------------------------------------

func _test_populate_lobby_empty(p: Array, f: Array, tree: SceneTree) -> void:
	var overlay = preload("res://scripts/ui_overlay.gd").new()
	tree.root.add_child(overlay)
	# _ready() builds the UI synchronously; no frame wait needed.
	overlay.populate_lobby([])
	_assert(true, "populate_lobby([]) does not crash", p, f)
	var container: VBoxContainer = overlay._lobby_list_container
	_assert(is_instance_valid(container),
		"_lobby_list_container exists after populate_lobby([])", p, f)
	if is_instance_valid(container):
		# Should contain exactly one Label (the empty-state message).
		_assert(container.get_child_count() == 1,
			"populate_lobby([]) shows exactly 1 child (empty-state label, got %d)" % container.get_child_count(),
			p, f)
	overlay.queue_free()

# ---------------------------------------------------------------------------
# populate_lobby: two rooms → two rows
# ---------------------------------------------------------------------------

func _test_populate_lobby_with_rooms(p: Array, f: Array, tree: SceneTree) -> void:
	var overlay = preload("res://scripts/ui_overlay.gd").new()
	tree.root.add_child(overlay)
	var rooms := [
		{"room_id": "alpha", "user_count": 3},
		{"room_id": "beta",  "user_count": 1},
	]
	overlay.populate_lobby(rooms)
	var container: VBoxContainer = overlay._lobby_list_container
	_assert(is_instance_valid(container),
		"_lobby_list_container exists after populate_lobby(rooms)", p, f)
	if is_instance_valid(container):
		_assert(container.get_child_count() == 2,
			"populate_lobby with 2 rooms produces 2 rows (got %d)" % container.get_child_count(),
			p, f)
	overlay.queue_free()

# ---------------------------------------------------------------------------
# populate_lobby: calling twice replaces the list (no duplicate entries)
# ---------------------------------------------------------------------------

func _test_populate_lobby_replaces_previous(p: Array, f: Array, tree: SceneTree) -> void:
	var overlay = preload("res://scripts/ui_overlay.gd").new()
	tree.root.add_child(overlay)
	overlay.populate_lobby([{"room_id": "first", "user_count": 1}])
	overlay.populate_lobby([
		{"room_id": "a", "user_count": 2},
		{"room_id": "b", "user_count": 4},
		{"room_id": "c", "user_count": 1},
	])
	var container: VBoxContainer = overlay._lobby_list_container
	if is_instance_valid(container):
		_assert(container.get_child_count() == 3,
			"Second populate_lobby() replaces first (3 rows, got %d)" % container.get_child_count(),
			p, f)
	overlay.queue_free()

# ---------------------------------------------------------------------------
# Overlay signal contracts
# ---------------------------------------------------------------------------

func _test_overlay_lobby_signals(p: Array, f: Array, tree: SceneTree) -> void:
	var overlay = preload("res://scripts/ui_overlay.gd").new()
	tree.root.add_child(overlay)
	_assert(overlay.has_signal("lobby_list_requested"),
		"ui_overlay has lobby_list_requested signal", p, f)
	_assert(overlay.has_signal("room_join_requested"),
		"ui_overlay has room_join_requested signal (with public param)", p, f)
	_assert(overlay.has_method("populate_lobby"),
		"ui_overlay has populate_lobby() method", p, f)
	overlay.queue_free()
