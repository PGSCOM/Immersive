## Privacy tests for Immersive-2.
## Run headlessly with:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
##
## Covers:
##   - Screen sharing toggle works (opt-in per monitor)
##   - Revocation immediately stops sharing
##   - No PII in logs (audit log statements)

extends SceneTree

# ---------------------------------------------------------------------------
# Tiny assertion helpers
# ---------------------------------------------------------------------------

var _passed: int = 0
var _failed: int = 0

func _assert(condition: bool, message: String) -> void:
	if condition:
		_passed += 1
		print('  PASS: %s' % message)
	else:
		_failed += 1
		print('  FAIL: %s' % message)

func _assert_eq_int(actual: int, expected: int, message: String) -> void:
	if actual == expected:
		_passed += 1
		print('  PASS: %s (got %d)' % [message, actual])
	else:
		_failed += 1
		print('  FAIL: %s (expected %d, got %d)' % [message, expected, actual])

func _assert_eq_str(actual: String, expected: String, message: String) -> void:
	if actual == expected:
		_passed += 1
		print('  PASS: %s (got %s)' % [message, actual])
	else:
		_failed += 1
		print('  FAIL: %s (expected %s, got %s)' % [message, expected, actual])

func _assert_true(condition: bool, message: String) -> void:
	_assert(condition, message)

func _assert_false(condition: bool, message: String) -> void:
	_assert(not condition, message)

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

func _init() -> void:
	print('\n=== Privacy Tests ===')

	test_privacy_manager_instantiates()
	test_register_monitor()
	test_share_monitor_opt_in()
	test_unshare_monitor_revokes_immediately()
	test_revoke_all_sharing()
	test_max_shared_monitors_limit()
	test_sharing_summary_ui_data()
	test_privacy_acknowledgment()
	test_reset_on_disconnect()
	test_no_pii_in_logs()
	test_session_id_ephemeral()

	print('\n=== Privacy Results ===')
	print('Passed: %d' % _passed)
	print('Failed: %d' % _failed)
	print('Total:  %d' % (_passed + _failed))

# ---------------------------------------------------------------------------
# Test 1: PrivacyManager instantiates
# ---------------------------------------------------------------------------

func test_privacy_manager_instantiates() -> void:
	print('\nTest: PrivacyManager instantiates')
	var pm_script := load('res://scripts/privacy_manager.gd') as Script
	_assert(pm_script != null, 'privacy_manager.gd loads as Script')

	var pm: Node = pm_script.new()
	_assert(pm != null, 'PrivacyManager instantiates')
	_assert(pm.has_signal('monitor_share_changed'), 'Has monitor_share_changed signal')
	_assert(pm.has_signal('all_sharing_revoked'), 'Has all_sharing_revoked signal')
	_assert(pm.has_method('share_monitor'), 'Has share_monitor method')
	_assert(pm.has_method('unshare_monitor'), 'Has unshare_monitor method')
	_assert(pm.has_method('revoke_all_sharing'), 'Has revoke_all_sharing method')
	_assert(pm.has_method('is_monitor_shared'), 'Has is_monitor_shared method')
	_assert(pm.has_method('get_shared_monitors'), 'Has get_shared_monitors method')
	_assert(pm.has_method('get_sharing_summary'), 'Has get_sharing_summary method')
	_assert(pm.has_method('reset'), 'Has reset method')
	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 2: Register monitor metadata
# ---------------------------------------------------------------------------

func test_register_monitor() -> void:
	print('\nTest: Register monitor metadata')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	get_root().add_child(pm)

	pm.register_monitor(1, 'Dell U2719D', 2560, 1440)
	pm.register_monitor(2, 'LG 27GN950', 3840, 2160)

	_assert_eq_str(pm.get_monitor_name(1), 'Dell U2719D', 'Monitor 1 name registered')
	_assert_eq_str(pm.get_monitor_name(2), 'LG 27GN950', 'Monitor 2 name registered')
	_assert_eq_str(pm.get_monitor_resolution(1), '2560x1440', 'Monitor 1 resolution registered')
	_assert_eq_str(pm.get_monitor_resolution(2), '3840x2160', 'Monitor 2 resolution registered')

	# Unknown monitor returns default
	_assert_eq_str(pm.get_monitor_name(99), 'Monitor 99', 'Unknown monitor gets default name')
	_assert_eq_str(pm.get_monitor_resolution(99), '?x?', 'Unknown monitor gets default resolution')

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 3: Share monitor (opt-in)
# ---------------------------------------------------------------------------

func test_share_monitor_opt_in() -> void:
	print('\nTest: Share monitor opt-in')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	get_root().add_child(pm)

	pm.register_monitor(1, 'Monitor A', 1920, 1080)
	pm.register_monitor(2, 'Monitor B', 1920, 1080)
	pm.register_monitor(3, 'Monitor C', 1920, 1080)

	# Initially nothing shared
	_assert_false(pm.is_monitor_shared(1), 'Monitor 1 not shared initially')
	_assert_false(pm.is_monitor_shared(2), 'Monitor 2 not shared initially')
	_assert_eq_int(pm.get_shared_count(), 0, 'Shared count is 0 initially')

	# Share monitor 1
	var result := pm.share_monitor(1)
	_assert_true(result, 'share_monitor(1) returns true')
	_assert_true(pm.is_monitor_shared(1), 'Monitor 1 is now shared')
	_assert_eq_int(pm.get_shared_count(), 1, 'Shared count is 1')

	# Share monitor 2
	result = pm.share_monitor(2)
	_assert_true(result, 'share_monitor(2) returns true')
	_assert_true(pm.is_monitor_shared(2), 'Monitor 2 is now shared')
	_assert_eq_int(pm.get_shared_count(), 2, 'Shared count is 2')

	# Idempotent: sharing already-shared monitor returns true
	result = pm.share_monitor(1)
	_assert_true(result, 'share_monitor(1) again returns true (idempotent)')
	_assert_eq_int(pm.get_shared_count(), 2, 'Shared count unchanged')

	# Unknown monitor fails
	result = pm.share_monitor(99)
	_assert_false(result, 'share_monitor(99) returns false for unknown monitor')

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 4: Unshare monitor (immediate revocation)
# ---------------------------------------------------------------------------

func test_unshare_monitor_revokes_immediately() -> void:
	print('\nTest: Unshare monitor revokes immediately')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	get_root().add_child(pm)

	pm.register_monitor(1, 'Monitor A', 1920, 1080)
	pm.register_monitor(2, 'Monitor B', 1920, 1080)

	pm.share_monitor(1)
	pm.share_monitor(2)
	_assert_eq_int(pm.get_shared_count(), 2, 'Two monitors shared')

	# Unshare monitor 1
	var result := pm.unshare_monitor(1)
	_assert_true(result, 'unshare_monitor(1) returns true')
	_assert_false(pm.is_monitor_shared(1), 'Monitor 1 no longer shared immediately')
	_assert_true(pm.is_monitor_shared(2), 'Monitor 2 still shared')
	_assert_eq_int(pm.get_shared_count(), 1, 'Shared count is 1')

	# Unshare monitor 2
	result = pm.unshare_monitor(2)
	_assert_true(result, 'unshare_monitor(2) returns true')
	_assert_false(pm.is_monitor_shared(2), 'Monitor 2 no longer shared immediately')
	_assert_eq_int(pm.get_shared_count(), 0, 'Shared count is 0')

	# Idempotent: unsharing already-unshared returns false
	result = pm.unshare_monitor(1)
	_assert_false(result, 'unshare_monitor(1) again returns false (idempotent)')

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 5: Revoke all sharing (emergency stop)
# ---------------------------------------------------------------------------

func test_revoke_all_sharing() -> void:
	print('\nTest: Revoke all sharing (emergency stop)')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	get_root().add_child(pm)

	pm.register_monitor(1, 'Monitor A', 1920, 1080)
	pm.register_monitor(2, 'Monitor B', 1920, 1080)
	pm.register_monitor(3, 'Monitor C', 1920, 1080)

	pm.share_monitor(1)
	pm.share_monitor(2)
	pm.share_monitor(3)
	_assert_eq_int(pm.get_shared_count(), 3, 'Three monitors shared')

	# Track signal emissions
	var signals_received: Array = []
	pm.monitor_share_changed.connect(func(mid: int, shared: bool):
		signals_received.append({'monitor_id': mid, 'shared': shared})
	)
	var all_revoked_received: bool = false
	pm.all_sharing_revoked.connect(func():
		all_revoked_received = true
	)

	# Revoke all
	pm.revoke_all_sharing()

	_assert_true(all_revoked_received, 'all_sharing_revoked signal emitted')
	_assert_eq_int(pm.get_shared_count(), 0, 'All monitors unshared')
	_assert_false(pm.is_monitor_shared(1), 'Monitor 1 unshared')
	_assert_false(pm.is_monitor_shared(2), 'Monitor 2 unshared')
	_assert_false(pm.is_monitor_shared(3), 'Monitor 3 unshared')

	# Verify signals for each monitor
	_assert_eq_int(signals_received.size(), 3, 'monitor_share_changed emitted for each monitor')
	for sig in signals_received:
		_assert_false(sig.shared, 'Signal shows shared=false for monitor %d' % sig.monitor_id)

	# Idempotent: revoke again does nothing (no signals)
	signals_received.clear()
	all_revoked_received = false
	pm.revoke_all_sharing()
	_assert_false(all_revoked_received, 'Second revoke_all_sharing does not emit all_sharing_revoked')
	_assert_eq_int(signals_received.size(), 0, 'Second revoke_all_sharing emits no monitor signals')

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 6: Max shared monitors limit
# ---------------------------------------------------------------------------

func test_max_shared_monitors_limit() -> void:
	print('\nTest: Max shared monitors limit (3)')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	get_root().add_child(pm)

	pm.register_monitor(1, 'Monitor 1', 1920, 1080)
	pm.register_monitor(2, 'Monitor 2', 1920, 1080)
	pm.register_monitor(3, 'Monitor 3', 1920, 1080)
	pm.register_monitor(4, 'Monitor 4', 1920, 1080)

	_assert_true(pm.share_monitor(1), 'Share monitor 1')
	_assert_true(pm.share_monitor(2), 'Share monitor 2')
	_assert_true(pm.share_monitor(3), 'Share monitor 3')
	_assert_eq_int(pm.get_shared_count(), 3, 'Three monitors shared')

	# Fourth should fail
	var result := pm.share_monitor(4)
	_assert_false(result, 'share_monitor(4) returns false (limit reached)')
	_assert_eq_int(pm.get_shared_count(), 3, 'Shared count still 3')

	# But unsharing one allows a new one
	pm.unshare_monitor(1)
	result = pm.share_monitor(4)
	_assert_true(result, 'share_monitor(4) works after unsharing one')
	_assert_eq_int(pm.get_shared_count(), 3, 'Shared count back to 3')

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 7: Sharing summary for UI
# ---------------------------------------------------------------------------

func test_sharing_summary_ui_data() -> void:
	print('\nTest: Sharing summary for UI')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	get_root().add_child(pm)

	pm.register_monitor(1, 'Dell U2719D', 2560, 1440)
	pm.register_monitor(2, 'LG 27GN950', 3840, 2160)
	pm.register_monitor(3, 'Samsung Odyssey', 3440, 1440)

	pm.share_monitor(1)
	pm.share_monitor(3)

	var summary := pm.get_sharing_summary()
	_assert_eq_int(summary.size(), 3, 'Summary has 3 entries')

	# Check monitor 1 (shared)
	var m1 := summary[0]
	_assert_eq_int(m1.monitor_id, 1, 'Entry 0 monitor_id=1')
	_assert_eq_str(m1.name, 'Dell U2719D', 'Entry 0 name correct')
	_assert_eq_str(m1.resolution, '2560x1440', 'Entry 0 resolution correct')
	_assert_true(m1.shared, 'Entry 0 shared=true')

	# Check monitor 2 (not shared)
	var m2 := summary[1]
	_assert_eq_int(m2.monitor_id, 2, 'Entry 1 monitor_id=2')
	_assert_false(m2.shared, 'Entry 1 shared=false')

	# Check monitor 3 (shared)
	var m3 := summary[2]
	_assert_eq_int(m3.monitor_id, 3, 'Entry 2 monitor_id=3')
	_assert_true(m3.shared, 'Entry 2 shared=true')

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 8: Privacy acknowledgment
# ---------------------------------------------------------------------------

func test_privacy_acknowledgment() -> void:
	print('\nTest: Privacy acknowledgment')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	get_root().add_child(pm)

	_assert_false(pm.is_privacy_acknowledged(), 'Not acknowledged initially')

	pm.acknowledge_privacy_notice()
	_assert_true(pm.is_privacy_acknowledged(), 'Acknowledged after call')

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 9: Reset on disconnect
# ---------------------------------------------------------------------------

func test_reset_on_disconnect() -> void:
	print('\nTest: Reset clears all state')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	get_root().add_child(pm)

	pm.register_monitor(1, 'Monitor A', 1920, 1080)
	pm.register_monitor(2, 'Monitor B', 1920, 1080)
	pm.share_monitor(1)
	pm.share_monitor(2)
	pm.acknowledge_privacy_notice()

	var session_id_before := pm.get_session_id()

	pm.reset()

	_assert_eq_int(pm.get_shared_count(), 0, 'Shared count reset to 0')
	_assert_false(pm.is_monitor_shared(1), 'Monitor 1 no longer shared')
	_assert_false(pm.is_monitor_shared(2), 'Monitor 2 no longer shared')
	_assert_false(pm.is_privacy_acknowledged(), 'Privacy acknowledgment reset')
	_assert_eq_int(pm.get_sharing_summary().size(), 0, 'Monitor registry cleared')

	# New session ID generated
	var session_id_after := pm.get_session_id()
	_assert(session_id_before != session_id_after, 'New session ID generated after reset')

	pm.queue_free()

# ---------------------------------------------------------------------------
# Test 10: No PII in logs (audit)
# ---------------------------------------------------------------------------

func test_no_pii_in_logs() -> void:
	print('\nTest: No PII in privacy_manager.gd log statements')
	# This test reads the source file and verifies no PII patterns in print/push_warning/push_error calls

	var script_path := 'res://scripts/privacy_manager.gd'
	var file := FileAccess.open(script_path, FileAccess.READ)
	_assert(file != null, 'Can open privacy_manager.gd for audit')

	var content := file.get_as_text()
	file.close()

	# Patterns that would indicate PII logging (case-insensitive check)
	var pii_patterns := [
		'ip', 'address', 'identity', 'username', 'password', 'token',
		'email', 'name', 'screen', 'content', 'pixel', 'frame',
		'credential', 'secret', 'key', 'certificate'
	]

	# Find all print/push_warning/push_error lines
	var lines := content.split('\n')
	var log_lines: Array = []
	for i in range(lines.size()):
		var line := lines[i].strip_edges()
		if line.begins_with('print(') or line.begins_with('push_warning(') or line.begins_with('push_error('):
			log_lines.append({'line_num': i + 1, 'content': line})

	# Check each log line for PII patterns
	var violations: Array = []
	for entry in log_lines:
		var lower := entry.content.to_lower()
		for pattern in pii_patterns:
			# Check if it's a false positive (allowed context)
			var allowed := false
			if pattern == 'session' and 'session_id' in lower:
				allowed = true
			elif pattern == 'monitor' and ('monitor_id' in lower or 'monitor=%d' in lower):
				allowed = true
			elif pattern == 'shared' and 'shared=' in lower:
				allowed = true
			elif pattern == 'name' and 'monitor_name' not in lower and 'display_name' not in lower:
				pass
			elif pattern == 'screen' and 'screen_share' not in lower:
				pass

			if not allowed:
				violations.append('Line %d: %s matches PII pattern %s' % [entry.line_num, entry.content, pattern])

	_assert_eq_int(violations.size(), 0, 'No PII patterns in log statements: %s' % str(violations))

	# Also verify the log format only includes session_id, monitor_id, shared state
	for entry in log_lines:
		var lower := entry.content.to_lower()
		_assert('session=' in lower or 'session_id' in lower or 'priv_' in lower,
			'Log line %d includes session context' % entry.line_num)
		_assert('monitor=' in lower or 'monitor_id' in lower,
			'Log line %d includes monitor context' % entry.line_num)

	print('  Audited %d log statements in privacy_manager.gd' % log_lines.size())

# ---------------------------------------------------------------------------
# Test 11: Session ID is ephemeral (not persisted)
# ---------------------------------------------------------------------------

func test_session_id_ephemeral() -> void:
	print('\nTest: Session ID is ephemeral')
	var pm: Node = load('res://scripts/privacy_manager.gd').new()
	get_root().add_child(pm)

	var id1 := pm.get_session_id()
	_assert(id1.begins_with('priv_'), 'Session ID format: priv_<hex>')
	_assert(id1.length() == 12, 'Session ID length 12 (priv_ + 8 hex)')

	pm.reset()
	var id2 := pm.get_session_id()
	_assert(id2.begins_with('priv_'), 'New session ID same format')
	_assert(id1 != id2, 'Session ID changes on reset')

	pm.queue_free()
