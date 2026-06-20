## Privacy Manager for Immersive-2 Multi-User Sessions.
##
## Manages screen sharing consent per monitor, tracks which monitors are shared,
## provides UI-friendly state queries, and handles immediate revocation.
##
## Privacy principles:
## - Screen sharing is opt-in per screen (no monitor shared by default)
## - Clear indicator of what each user is exposing
## - Immediate effect on revocation (stream stops within one frame)
## - No PII in logs (ephemeral IDs only, no IPs, names, or screen contents)

extends Node

class_name PrivacyManager

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted when a monitor's share state changes (monitor_id, is_shared).
signal monitor_share_changed(monitor_id: int, is_shared: bool)

## Emitted when all sharing is revoked (emergency stop).
signal all_sharing_revoked

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Maximum monitors that can be shared simultaneously (matches MAX_SCREENS).
const MAX_SHARED_MONITORS: int = 3

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

## Set of monitor IDs currently shared (opt-in, per-monitor).
var _shared_monitors: Array[int] = []

## Map of monitor_id -> human-readable name (for UI display only, not logged).
var _monitor_names: Dictionary = {}

## Map of monitor_id -> resolution string "WxH" (for UI display only).
var _monitor_resolutions: Dictionary = {}

## Whether the user has explicitly acknowledged the privacy notice.
var _privacy_acknowledged: bool = false

## Session ID for this privacy context (ephemeral, not persisted).
var _session_id: String = ""

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _init() -> void:
	_generate_session_id()

func _ready() -> void:
	print("[Privacy] session=%s initialized" % _session_id)

func _generate_session_id() -> void:
	# Ephemeral session ID — not persisted, not logged with PII.
	# Format: "priv_<random_hex_8>"
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_session_id = "priv_%08x" % [rng.randi()]

# ---------------------------------------------------------------------------
# Public API

## Register a monitor's metadata (name, resolution) for UI display.
## Called when the host sends MONITOR_LIST.
## @param monitor_id Unique monitor identifier from host
## @param name Human-readable monitor name (e.g., "Dell U2719D")
## @param width Native width in pixels
## @param height Native height in pixels
func register_monitor(monitor_id: int, name: String, width: int, height: int) -> void:
	_monitor_names[monitor_id] = name
	_monitor_resolutions[monitor_id] = "%dx%d" % [width, height]

## Opt-in to share a specific monitor.
## Immediately starts streaming that monitor to other participants.
## @param monitor_id Monitor to share (must be registered)
## @return true if sharing started, false if already shared or invalid
func share_monitor(monitor_id: int) -> bool:
	if not _monitor_names.has(monitor_id):
		push_warning("[Privacy] session=%s Cannot share unknown monitor_id=%d" % [_session_id, monitor_id])
		return false

	if _shared_monitors.has(monitor_id):
		return true  # Already shared; idempotent

	if _shared_monitors.size() >= MAX_SHARED_MONITORS:
		push_warning("[Privacy] session=%s Maximum shared monitors (%d) reached monitor_id=%d" % [_session_id, MAX_SHARED_MONITORS, monitor_id])
		return false

	_shared_monitors.append(monitor_id)
	monitor_share_changed.emit(monitor_id, true)
	_log_share_state_change(monitor_id, true)
	return true

## Revoke sharing for a specific monitor.
## Immediately stops streaming that monitor to other participants.
## @param monitor_id Monitor to stop sharing
## @return true if sharing was active and is now revoked
func unshare_monitor(monitor_id: int) -> bool:
	if not _shared_monitors.has(monitor_id):
		return false  # Wasn't shared; idempotent

	_shared_monitors.erase(monitor_id)
	monitor_share_changed.emit(monitor_id, false)
	_log_share_state_change(monitor_id, false)
	return true

## Revoke sharing for ALL monitors immediately (emergency stop).
## Emits all_sharing_revoked for UI to react.
func revoke_all_sharing() -> void:
	if _shared_monitors.is_empty():
		return

	var monitors_to_revoke := _shared_monitors.duplicate()
	_shared_monitors.clear()

	for mid in monitors_to_revoke:
		monitor_share_changed.emit(mid, false)
		_log_share_state_change(mid, false)

	all_sharing_revoked.emit()
	print("[Privacy] session=%s All sharing revoked monitor_id_count=%d" % [_session_id, monitors_to_revoke.size()])

## Check if a specific monitor is currently shared.
## @param monitor_id Monitor to check
## @return true if this monitor is being shared
func is_monitor_shared(monitor_id: int) -> bool:
	return _shared_monitors.has(monitor_id)

## Get list of currently shared monitor IDs.
## @return Array of monitor IDs (copy, safe to modify)
func get_shared_monitors() -> Array[int]:
	return _shared_monitors.duplicate()

## Get count of currently shared monitors.
## @return Number of monitors being shared
func get_shared_count() -> int:
	return _shared_monitors.size()

## Get human-readable name for a monitor (for UI).
## @param monitor_id Monitor to query
## @return Name string, or "Monitor <id>" if unknown
func get_monitor_name(monitor_id: int) -> String:
	return _monitor_names.get(monitor_id, "Monitor %d" % monitor_id)

## Get resolution string for a monitor (for UI).
## @param monitor_id Monitor to query
## @return "WxH" string, or "?x?" if unknown
func get_monitor_resolution(monitor_id: int) -> String:
	return _monitor_resolutions.get(monitor_id, "?x?")

## Get a UI-friendly summary of what is being shared.
## @return Array of {monitor_id, name, resolution, shared} dicts for all registered monitors
func get_sharing_summary() -> Array[Dictionary]:
	var summary: Array[Dictionary] = []
	for mid in _monitor_names.keys():
		summary.append({
			"monitor_id": mid,
			"name": _monitor_names[mid],
			"resolution": _monitor_resolutions.get(mid, "?x?"),
			"shared": _shared_monitors.has(mid)
		})
	return summary

## Check if any monitor is currently shared.
## @return true if at least one monitor is shared
func is_any_shared() -> bool:
	return not _shared_monitors.is_empty()

## Mark that the user has acknowledged the privacy notice.
## Required before any sharing can be enabled (enforced by UI).
func acknowledge_privacy_notice() -> void:
	_privacy_acknowledged = true

## Check if privacy notice has been acknowledged.
## @return true if user has acknowledged
func is_privacy_acknowledged() -> bool:
	return _privacy_acknowledged

## Get the ephemeral session ID (for debugging/correlation only).
## @return Session ID string
func get_session_id() -> String:
	return _session_id

## Reset all privacy state (called on disconnect/room leave).
func reset() -> void:
	if not _shared_monitors.is_empty():
		revoke_all_sharing()
	_monitor_names.clear()
	_monitor_resolutions.clear()
	_privacy_acknowledged = false
	_generate_session_id()

# ---------------------------------------------------------------------------
# Internal logging (no PII)
# ---------------------------------------------------------------------------

func _log_share_state_change(monitor_id: int, is_shared: bool) -> void:
	# Log ONLY: session ID (ephemeral), monitor ID (opaque), share state.
	# NEVER log: monitor name, resolution, IP, user identity, screen contents.
	print("[Privacy] session=%s monitor=%d shared=%s" % [_session_id, monitor_id, str(is_shared)])
