## Privacy tests for Immersive-2.
## Run headlessly via the project test runner:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
##
## Covers:
##   - Screen sharing toggle works (opt-in per monitor)
##   - Revocation immediately stops sharing
##   - No PII in logs (audit log statements)

extends RefCounted

var _tree: SceneTree = null

# ---------------------------------------------------------------------------
# Entry point — called by run_tests.gd
# ---------------------------------------------------------------------------

func run_all(results: Dictionary, tree: SceneTree) -> void:
	_tree = tree
	var passed: Array = []
	var failed: Array = []

	print('\n=== Privacy Tests ===')

	_test_privacy_manager_instantiates(passed, failed)
	_test_register_monitor(passed, failed)
	_test_share_requires_acknowledgement(passed, failed)
	_test_share_monitor_opt_in(passed, failed)
	_test_unshare_monitor_revokes_immediately(passed, failed)
	_test_revoke_all_sharing(passed, failed)
	_test_max_shared_monitors_limit(passed, failed)
	_test_sharing_summary_ui_data(passed, failed)
	_test_privacy_acknowledgment(passed, failed)
	_test_reset_on_disconnect(passed, failed)
	_test_no_pii_in_logs(passed, failed)
	_test_session_id_ephemeral(passed, failed)

	print('\n  --> Privacy: Passed: %d / Failed: %d' % [passed.size(), failed.size()])
	results["passed"] = passed.size()
	results["failed"] = failed.size()
	results["failed_messages"] = failed.duplicate()

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

func _assert(condition: bool, message: String, passed: Array, failed: Array) -> void:
	if condition:
		passed.append(message)
		print('  PASS: %s' % message)
	else:
		failed.append(message)
		print('  FAIL: %s' % message)

func _assert_eq_int(actual: int, expected: int, message: String,
		passed: Array, failed: Array) -> void:
	if actual == expected:
		passed.append(message)
		print('  PASS: %s (got %d)' % [message, actual])
	else:
		failed.append(message)
		print('  FAIL: %s (expected %d, got %d)' % [message, expected, actual])

func _assert_eq_str(actual: String, expected: String, message: String,
		passed: Array, failed: Array) -> void:
	if actual == expected:
		passed.append(message)
		print('  PASS: %s (got %s)' % [message, actual])
	else:
		failed.append(message)
		print('  FAIL: %s (expected %s, got %s)' % [message, expected, actual])

func _assert_true(condition: bool, message: String,
		passed: Array, failed: Array) -> void:
	_assert(condition, message, passed, failed)

func _assert_false(condition: bool, message: String,
		passed: Array, failed: Array) -> void:
	_assert(not condition, message, passed, failed)

# ---------------------------------------------------------------------------
# Test 1: PrivacyManager instantiates
# ---------------------------------------------------------------------------

func _test_privacy_manager_instantiates(passed: Array, failed: Array) -> void:
	print('\nTest: PrivacyManager instantiates')
	var pm_script := load('res://scripts/privacy_manager.gd') as Script
	_assert(pm_script != null, 'privacy_manager.gd loads as Script', passed, failed)

	var pm: Node = pm_script.new()
	_assert(pm != null, 'PrivacyManager instantiates', passed, failed)
	_assert(pm.has_signal('monitor_share_changed'), 'Has monitor_share_changed signal', passed, failed)
	_assert(pm.has_signal('all_sharing_revoked'), 'Has all_sharing_revoked signal', passed, failed)
	_assert(pm.has_signal('privacy_notice_required'), 'Has privacy_notice_required signal', passed, failed)
	_assert(pm.has_method('share_monitor'), 'Has share_monitor method', passed, failed)
	_assert(pm.has_method('unshare_monitor'), 'Has unshare_monitor method', passed, failed)
	_assert(pm.has_method('revoke_all_sharing'), 'Has revoke_all_sharing method', passed, failed)
	_assert(pm.has_method('is_monitor_shared'), 'Has is_monitor_shared method', passed, failed)
	_assert(pm.has_method('get_shared_monitors'), 'Has get_shared_monitors method', passed, failed)
	_assert(pm.has_method('get_sharing_summary'), 'Has get_sharing_summary method', passed, failed)
	_assert(pm.has_method('reset'), 'Has reset method', passed, failed)
	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 2: Register monitor metadata
# ---------------------------------------------------------------------------

func _test_register_monitor(passed: Array, failed: Array) -> void:
	print('\nTest: Register monitor metadata')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	_tree.root.add_child(pm)

	pm.register_monitor(1, 'Dell U2719D', 2560, 1440)
	pm.register_monitor(2, 'LG 27GN950', 3840, 2160)

	_assert_eq_str(pm.get_monitor_name(1), 'Dell U2719D', 'Monitor 1 name registered', passed, failed)
	_assert_eq_str(pm.get_monitor_name(2), 'LG 27GN950', 'Monitor 2 name registered', passed, failed)
	_assert_eq_str(pm.get_monitor_resolution(1), '2560x1440', 'Monitor 1 resolution registered', passed, failed)
	_assert_eq_str(pm.get_monitor_resolution(2), '3840x2160', 'Monitor 2 resolution registered', passed, failed)

	_assert_eq_str(pm.get_monitor_name(99), 'Monitor 99', 'Unknown monitor gets default name', passed, failed)
	_assert_eq_str(pm.get_monitor_resolution(99), '?x?', 'Unknown monitor gets default resolution', passed, failed)

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test: Share requires privacy-notice acknowledgement (consent gate)
# ---------------------------------------------------------------------------

func _test_share_requires_acknowledgement(passed: Array, failed: Array) -> void:
	print('\nTest: Share requires privacy acknowledgement')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	_tree.root.add_child(pm)

	pm.register_monitor(1, 'Monitor A', 1920, 1080)

	# Array wrapper so the lambda can mutate a counter visible to the test.
	var required: Array = [0]
	pm.privacy_notice_required.connect(func(mid: int):
		required[0] += 1
	)

	_assert_false(pm.is_privacy_acknowledged(), 'Not acknowledged initially', passed, failed)

	# Before acknowledgement: share is blocked and asks for the consent dialog.
	var result: bool = pm.share_monitor(1)
	_assert_false(result, 'share_monitor before ack returns false', passed, failed)
	_assert_false(pm.is_monitor_shared(1), 'Monitor not shared before ack', passed, failed)
	_assert_eq_int(pm.get_shared_count(), 0, 'Nothing shared before ack', passed, failed)
	_assert_eq_int(required[0], 1, 'privacy_notice_required emitted once', passed, failed)

	# After acknowledgement: the same share now succeeds.
	pm.acknowledge_privacy_notice()
	result = pm.share_monitor(1)
	_assert_true(result, 'share_monitor after ack returns true', passed, failed)
	_assert_true(pm.is_monitor_shared(1), 'Monitor shared after ack', passed, failed)
	_assert_eq_int(required[0], 1, 'No further privacy_notice_required after ack', passed, failed)

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 3: Share monitor (opt-in)
# ---------------------------------------------------------------------------

func _test_share_monitor_opt_in(passed: Array, failed: Array) -> void:
	print('\nTest: Share monitor opt-in')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	_tree.root.add_child(pm)

	pm.register_monitor(1, 'Monitor A', 1920, 1080)
	pm.register_monitor(2, 'Monitor B', 1920, 1080)
	pm.register_monitor(3, 'Monitor C', 1920, 1080)
	pm.acknowledge_privacy_notice()  # sharing is gated on the privacy notice

	_assert_false(pm.is_monitor_shared(1), 'Monitor 1 not shared initially', passed, failed)
	_assert_false(pm.is_monitor_shared(2), 'Monitor 2 not shared initially', passed, failed)
	_assert_eq_int(pm.get_shared_count(), 0, 'Shared count is 0 initially', passed, failed)

	var result: bool = pm.share_monitor(1)
	_assert_true(result, 'share_monitor(1) returns true', passed, failed)
	_assert_true(pm.is_monitor_shared(1), 'Monitor 1 is now shared', passed, failed)
	_assert_eq_int(pm.get_shared_count(), 1, 'Shared count is 1', passed, failed)

	result = pm.share_monitor(2)
	_assert_true(result, 'share_monitor(2) returns true', passed, failed)
	_assert_true(pm.is_monitor_shared(2), 'Monitor 2 is now shared', passed, failed)
	_assert_eq_int(pm.get_shared_count(), 2, 'Shared count is 2', passed, failed)

	result = pm.share_monitor(1)
	_assert_true(result, 'share_monitor(1) again returns true (idempotent)', passed, failed)
	_assert_eq_int(pm.get_shared_count(), 2, 'Shared count unchanged', passed, failed)

	result = pm.share_monitor(99)
	_assert_false(result, 'share_monitor(99) returns false for unknown monitor', passed, failed)

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 4: Unshare monitor (immediate revocation)
# ---------------------------------------------------------------------------

func _test_unshare_monitor_revokes_immediately(passed: Array, failed: Array) -> void:
	print('\nTest: Unshare monitor revokes immediately')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	_tree.root.add_child(pm)

	pm.register_monitor(1, 'Monitor A', 1920, 1080)
	pm.register_monitor(2, 'Monitor B', 1920, 1080)
	pm.acknowledge_privacy_notice()  # sharing is gated on the privacy notice

	pm.share_monitor(1)
	pm.share_monitor(2)
	_assert_eq_int(pm.get_shared_count(), 2, 'Two monitors shared', passed, failed)

	var result: bool = pm.unshare_monitor(1)
	_assert_true(result, 'unshare_monitor(1) returns true', passed, failed)
	_assert_false(pm.is_monitor_shared(1), 'Monitor 1 no longer shared immediately', passed, failed)
	_assert_true(pm.is_monitor_shared(2), 'Monitor 2 still shared', passed, failed)
	_assert_eq_int(pm.get_shared_count(), 1, 'Shared count is 1', passed, failed)

	result = pm.unshare_monitor(2)
	_assert_true(result, 'unshare_monitor(2) returns true', passed, failed)
	_assert_false(pm.is_monitor_shared(2), 'Monitor 2 no longer shared immediately', passed, failed)
	_assert_eq_int(pm.get_shared_count(), 0, 'Shared count is 0', passed, failed)

	result = pm.unshare_monitor(1)
	_assert_false(result, 'unshare_monitor(1) again returns false (idempotent)', passed, failed)

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 5: Revoke all sharing (emergency stop)
# ---------------------------------------------------------------------------

func _test_revoke_all_sharing(passed: Array, failed: Array) -> void:
	print('\nTest: Revoke all sharing (emergency stop)')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	_tree.root.add_child(pm)

	pm.register_monitor(1, 'Monitor A', 1920, 1080)
	pm.register_monitor(2, 'Monitor B', 1920, 1080)
	pm.register_monitor(3, 'Monitor C', 1920, 1080)
	pm.acknowledge_privacy_notice()  # sharing is gated on the privacy notice

	pm.share_monitor(1)
	pm.share_monitor(2)
	pm.share_monitor(3)
	_assert_eq_int(pm.get_shared_count(), 3, 'Three monitors shared', passed, failed)

	var signals_received: Array = []
	pm.monitor_share_changed.connect(func(mid: int, shared: bool):
		signals_received.append({'monitor_id': mid, 'shared': shared})
	)
	# Use Array wrapper — GDScript 4 closures capture value types (bool) by value,
	# so mutation inside the lambda wouldn't be visible outside without a ref wrapper.
	var all_revoked_flag: Array = [false]
	pm.all_sharing_revoked.connect(func():
		all_revoked_flag[0] = true
	)

	pm.revoke_all_sharing()

	_assert_true(all_revoked_flag[0], 'all_sharing_revoked signal emitted', passed, failed)
	_assert_eq_int(pm.get_shared_count(), 0, 'All monitors unshared', passed, failed)
	_assert_false(pm.is_monitor_shared(1), 'Monitor 1 unshared', passed, failed)
	_assert_false(pm.is_monitor_shared(2), 'Monitor 2 unshared', passed, failed)
	_assert_false(pm.is_monitor_shared(3), 'Monitor 3 unshared', passed, failed)

	_assert_eq_int(signals_received.size(), 3, 'monitor_share_changed emitted for each monitor', passed, failed)
	for sig in signals_received:
		_assert_false(sig.shared, 'Signal shows shared=false for monitor %d' % sig.monitor_id, passed, failed)

	signals_received.clear()
	all_revoked_flag[0] = false
	pm.revoke_all_sharing()
	_assert_false(all_revoked_flag[0], 'Second revoke_all_sharing does not emit all_sharing_revoked', passed, failed)
	_assert_eq_int(signals_received.size(), 0, 'Second revoke_all_sharing emits no monitor signals', passed, failed)

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 6: Max shared monitors limit
# ---------------------------------------------------------------------------

func _test_max_shared_monitors_limit(passed: Array, failed: Array) -> void:
	print('\nTest: Max shared monitors limit (3)')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	_tree.root.add_child(pm)

	pm.register_monitor(1, 'Monitor 1', 1920, 1080)
	pm.register_monitor(2, 'Monitor 2', 1920, 1080)
	pm.register_monitor(3, 'Monitor 3', 1920, 1080)
	pm.register_monitor(4, 'Monitor 4', 1920, 1080)
	pm.acknowledge_privacy_notice()  # sharing is gated on the privacy notice

	_assert_true(pm.share_monitor(1), 'Share monitor 1', passed, failed)
	_assert_true(pm.share_monitor(2), 'Share monitor 2', passed, failed)
	_assert_true(pm.share_monitor(3), 'Share monitor 3', passed, failed)
	_assert_eq_int(pm.get_shared_count(), 3, 'Three monitors shared', passed, failed)

	var result: bool = pm.share_monitor(4)
	_assert_false(result, 'share_monitor(4) returns false (limit reached)', passed, failed)
	_assert_eq_int(pm.get_shared_count(), 3, 'Shared count still 3', passed, failed)

	pm.unshare_monitor(1)
	result = pm.share_monitor(4)
	_assert_true(result, 'share_monitor(4) works after unsharing one', passed, failed)
	_assert_eq_int(pm.get_shared_count(), 3, 'Shared count back to 3', passed, failed)

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 7: Sharing summary for UI
# ---------------------------------------------------------------------------

func _test_sharing_summary_ui_data(passed: Array, failed: Array) -> void:
	print('\nTest: Sharing summary for UI')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	_tree.root.add_child(pm)

	pm.register_monitor(1, 'Dell U2719D', 2560, 1440)
	pm.register_monitor(2, 'LG 27GN950', 3840, 2160)
	pm.register_monitor(3, 'Samsung Odyssey', 3440, 1440)
	pm.acknowledge_privacy_notice()  # sharing is gated on the privacy notice

	pm.share_monitor(1)
	pm.share_monitor(3)

	var summary: Array = pm.get_sharing_summary()
	_assert_eq_int(summary.size(), 3, 'Summary has 3 entries', passed, failed)

	var m1: Dictionary = summary[0]
	_assert_eq_int(m1.monitor_id, 1, 'Entry 0 monitor_id=1', passed, failed)
	_assert_eq_str(m1.name, 'Dell U2719D', 'Entry 0 name correct', passed, failed)
	_assert_eq_str(m1.resolution, '2560x1440', 'Entry 0 resolution correct', passed, failed)
	_assert_true(m1.shared, 'Entry 0 shared=true', passed, failed)

	var m2: Dictionary = summary[1]
	_assert_eq_int(m2.monitor_id, 2, 'Entry 1 monitor_id=2', passed, failed)
	_assert_false(m2.shared, 'Entry 1 shared=false', passed, failed)

	var m3: Dictionary = summary[2]
	_assert_eq_int(m3.monitor_id, 3, 'Entry 2 monitor_id=3', passed, failed)
	_assert_true(m3.shared, 'Entry 2 shared=true', passed, failed)

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 8: Privacy acknowledgment
# ---------------------------------------------------------------------------

func _test_privacy_acknowledgment(passed: Array, failed: Array) -> void:
	print('\nTest: Privacy acknowledgment')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	_tree.root.add_child(pm)

	_assert_false(pm.is_privacy_acknowledged(), 'Not acknowledged initially', passed, failed)

	pm.acknowledge_privacy_notice()
	_assert_true(pm.is_privacy_acknowledged(), 'Acknowledged after call', passed, failed)

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 9: Reset on disconnect
# ---------------------------------------------------------------------------

func _test_reset_on_disconnect(passed: Array, failed: Array) -> void:
	print('\nTest: Reset clears all state')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	_tree.root.add_child(pm)

	pm.register_monitor(1, 'Monitor A', 1920, 1080)
	pm.register_monitor(2, 'Monitor B', 1920, 1080)
	pm.acknowledge_privacy_notice()  # sharing is gated on the privacy notice
	pm.share_monitor(1)
	pm.share_monitor(2)

	var session_id_before: String = pm.get_session_id()

	pm.reset()

	_assert_eq_int(pm.get_shared_count(), 0, 'Shared count reset to 0', passed, failed)
	_assert_false(pm.is_monitor_shared(1), 'Monitor 1 no longer shared', passed, failed)
	_assert_false(pm.is_monitor_shared(2), 'Monitor 2 no longer shared', passed, failed)
	_assert_false(pm.is_privacy_acknowledged(), 'Privacy acknowledgment reset', passed, failed)
	_assert_eq_int(pm.get_sharing_summary().size(), 0, 'Monitor registry cleared', passed, failed)

	var session_id_after: String = pm.get_session_id()
	_assert(session_id_before != session_id_after, 'New session ID generated after reset', passed, failed)

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 10: No PII in logs (source code audit)
# ---------------------------------------------------------------------------

func _test_no_pii_in_logs(passed: Array, failed: Array) -> void:
	print('\nTest: No PII in privacy_manager.gd log statements')

	var script_path := 'res://scripts/privacy_manager.gd'
	var file := FileAccess.open(script_path, FileAccess.READ)
	_assert(file != null, 'Can open privacy_manager.gd for audit', passed, failed)
	if file == null:
		return

	var content := file.get_as_text()
	file.close()

	# Unambiguous PII patterns — these should never appear in log output strings.
	var pii_patterns := [
		'ip_address', 'identity', 'username', 'password', 'token',
		'email', 'credential', 'certificate', 'pixel_data', 'frame_data',
	]

	var lines := content.split('\n')
	var log_lines: Array = []
	for i in range(lines.size()):
		var line := lines[i].strip_edges()
		if line.begins_with('print(') or line.begins_with('push_warning(') \
				or line.begins_with('push_error('):
			log_lines.append({'line_num': i + 1, 'content': line})

	# Check each log line only for patterns that actually appear in it.
	var violations: Array = []
	for entry: Dictionary in log_lines:
		var lower: String = (entry.get("content", "") as String).to_lower()
		for pattern: String in pii_patterns:
			if pattern in lower:
				violations.append('Line %d contains "%s": %s' % [entry.get("line_num", 0), pattern, entry.get("content", "")])

	_assert(violations.size() == 0,
		'No PII patterns in log statements (%d lines checked, violations: %s)' \
		% [log_lines.size(), str(violations)],
		passed, failed)

	# Verify every log statement includes a session reference (ephemeral ID only).
	var session_violations: Array = []
	for entry: Dictionary in log_lines:
		var lower: String = (entry.get("content", "") as String).to_lower()
		var has_session: bool = 'session=' in lower or '_session_id' in lower or 'priv_' in lower
		if not has_session:
			session_violations.append('Line %d lacks session context: %s' % [entry.get("line_num", 0), entry.get("content", "")])

	_assert(session_violations.size() == 0,
		'All log statements include session context (violations: %s)' % str(session_violations),
		passed, failed)

	print('  Audited %d log statements in privacy_manager.gd' % log_lines.size())

# ---------------------------------------------------------------------------
# Test 11: Session ID is ephemeral (not persisted)
# ---------------------------------------------------------------------------

func _test_session_id_ephemeral(passed: Array, failed: Array) -> void:
	print('\nTest: Session ID is ephemeral')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	_tree.root.add_child(pm)

	var id1: String = pm.get_session_id()
	_assert(id1.begins_with('priv_'), 'Session ID format: priv_<hex>', passed, failed)
	_assert(id1.length() == 13, 'Session ID length 13 (priv_ + 8 hex)', passed, failed)

	pm.reset()
	var id2: String = pm.get_session_id()
	_assert(id2.begins_with('priv_'), 'New session ID same format', passed, failed)
	_assert(id1 != id2, 'Session ID changes on reset', passed, failed)

	pm.queue_free()
