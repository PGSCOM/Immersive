## UI overlay tests for Immersive-2.
## Run headlessly via the project test runner:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
##
## Covers the privacy-consent modal wiring on ui_overlay.gd:
##   - The overlay exposes the consent signal/methods main.gd connects to.
##   - show_privacy_notice() raises the modal; accepting emits
##     privacy_notice_acknowledged with the pending monitor; dismissing does not.

extends RefCounted

var _tree: SceneTree = null

# ---------------------------------------------------------------------------
# Entry point — called by run_tests.gd
# ---------------------------------------------------------------------------

func run_all(results: Dictionary, tree: SceneTree) -> void:
	_tree = tree
	var passed: Array = []
	var failed: Array = []

	print('\n=== UI Overlay Tests ===')

	_test_overlay_instantiates(passed, failed)
	_test_privacy_notice_shows_dialog(passed, failed)
	_test_privacy_notice_confirm_emits(passed, failed)
	_test_privacy_notice_cancel_no_emit(passed, failed)

	print('\n  --> UI Overlay: Passed: %d / Failed: %d' % [passed.size(), failed.size()])
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

func _new_overlay() -> Node:
	var overlay: Node = load('res://scripts/ui_overlay.gd').new()
	_tree.root.add_child(overlay)
	return overlay

# ---------------------------------------------------------------------------
# Test: overlay instantiates with the consent API main.gd relies on
# ---------------------------------------------------------------------------

func _test_overlay_instantiates(passed: Array, failed: Array) -> void:
	print('\nTest: UIOverlay instantiates with consent API')
	var overlay := _new_overlay()
	_assert(overlay != null, 'ui_overlay.gd instantiates', passed, failed)
	_assert(overlay.has_signal('monitor_share_toggled'), 'Has monitor_share_toggled signal', passed, failed)
	_assert(overlay.has_signal('privacy_notice_acknowledged'), 'Has privacy_notice_acknowledged signal', passed, failed)
	_assert(overlay.has_method('show_privacy_notice'), 'Has show_privacy_notice method', passed, failed)
	_assert(overlay.has_method('is_privacy_notice_visible'), 'Has is_privacy_notice_visible method', passed, failed)
	_assert(not overlay.is_privacy_notice_visible(), 'Consent modal hidden initially', passed, failed)
	overlay.queue_free()

# ---------------------------------------------------------------------------
# Test: show_privacy_notice raises the modal
# ---------------------------------------------------------------------------

func _test_privacy_notice_shows_dialog(passed: Array, failed: Array) -> void:
	print('\nTest: show_privacy_notice raises the modal')
	var overlay := _new_overlay()
	overlay.show_privacy_notice(7)
	_assert(overlay.is_privacy_notice_visible(), 'Consent modal visible after show_privacy_notice', passed, failed)
	overlay.queue_free()

# ---------------------------------------------------------------------------
# Test: accepting emits privacy_notice_acknowledged with the pending monitor
# ---------------------------------------------------------------------------

func _test_privacy_notice_confirm_emits(passed: Array, failed: Array) -> void:
	print('\nTest: accepting the modal emits acknowledgement')
	var overlay := _new_overlay()
	# Array wrapper so the lambda can report back to the test.
	var got: Array = [-99]
	overlay.privacy_notice_acknowledged.connect(func(mid: int):
		got[0] = mid
	)
	overlay.show_privacy_notice(3)
	overlay._on_privacy_dialog_confirm()
	_assert(got[0] == 3, 'privacy_notice_acknowledged emitted with pending monitor id', passed, failed)
	_assert(not overlay.is_privacy_notice_visible(), 'Modal hidden after accept', passed, failed)
	overlay.queue_free()

# ---------------------------------------------------------------------------
# Test: dismissing the modal does not acknowledge
# ---------------------------------------------------------------------------

func _test_privacy_notice_cancel_no_emit(passed: Array, failed: Array) -> void:
	print('\nTest: dismissing the modal does not acknowledge')
	var overlay := _new_overlay()
	var emitted: Array = [false]
	overlay.privacy_notice_acknowledged.connect(func(_mid: int):
		emitted[0] = true
	)
	overlay.show_privacy_notice(5)
	overlay._on_privacy_dialog_cancel()
	_assert(not emitted[0], 'No acknowledgement emitted on dismiss', passed, failed)
	_assert(not overlay.is_privacy_notice_visible(), 'Modal hidden after dismiss', passed, failed)
	overlay.queue_free()
