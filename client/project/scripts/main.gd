## Main scene controller.
## Initializes XR, manages network connection, and coordinates
## screen streaming between components.
##
## Supports up to 3 simultaneous monitor panels, UI overlay,
## auto-reconnection, and latency measurement.

extends Node3D

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const MAX_SCREENS := 3
const RECONNECT_DELAY := 5.0    ## Seconds between reconnect attempts
const LATENCY_INTERVAL := 2.0   ## Seconds between latency probes
const XR_INIT_RETRY_INTERVAL := 1.0
const XR_INIT_MAX_RETRIES := 10
const LEFT_TRACKER_PROBES := ["/user/hand/left", "/user/hand_tracker/left", "left_hand"]
const RIGHT_TRACKER_PROBES := ["/user/hand/right", "/user/hand_tracker/right", "right_hand"]
const CONFIG_PATH := "user://immersive2_config.cfg"
const WORKSPACE_PATH := "user://immersive2_workspace.json"

# ---------------------------------------------------------------------------
# Scene references
# ---------------------------------------------------------------------------

@onready var xr_origin: XROrigin3D    = $XROrigin3D
@onready var xr_camera: XRCamera3D   = $XROrigin3D/XRCamera3D
@onready var left_controller: XRController3D = $XROrigin3D/LeftController
@onready var right_controller: XRController3D = $XROrigin3D/RightController
@onready var right_aim: XRController3D = $XROrigin3D/RightAim

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

enum State { DISCONNECTED, CONNECTING, CONNECTED, STREAMING }
var current_state: State = State.DISCONNECTED

var host_ip: String    = "192.168.1.100"
var host_tcp_port: int = 19800
var host_udp_port: int = 19801
var curved_screen_enabled: bool = false
var curved_screen_amount: float = 0.18
var foveation_enabled: bool = false
var foveation_strength: float = 0.55
var passthrough_enabled: bool = false

var available_monitors: Array = []

## Active screen panels (up to MAX_SCREENS).
var screen_panels: Array = []

## Network client (lazy-created).
var network_client: Node = null

## UI overlay (lazy-created).
var ui_overlay: Node = null

## XR interface.
var xr_interface: XRInterface = null
var eye_gaze_controller: XRController3D = null
var _xr_initialized: bool = false
var _xr_init_retry_timer: float = 0.0
var _xr_init_attempts: int = 0
var _left_tracker_probe_timer: float = 0.0
var _right_tracker_probe_timer: float = 0.0
var _left_tracker_index: int = 0
var _right_tracker_index: int = 0
var _left_tracker_locked: bool = false
var _right_tracker_locked: bool = false

# Reconnect timer
var _reconnect_timer: float = 0.0
var _should_reconnect: bool = false

# Latency tracking
var _latency_timer: float = 0.0
var _probe_id: int = 0
var _probe_sent_us: int = 0
var _latency_ms: float = 0.0

# Workspace persistence
var _workspace_monitor_ids: Array = []
var _workspace_panel_layouts: Array = []
var _pending_workspace_restore: bool = false

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_load_config()
	_load_workspace_layout()
	_init_xr()
	_init_eye_gaze_controller()
	_init_network()
	_init_ui_overlay()
	if current_state == State.DISCONNECTED and ui_overlay and ui_overlay.has_method("toggle_visibility"):
		ui_overlay.toggle_visibility()
	print("[Immersive-2] VR Client started — press B/Y to open overlay")

func _process(delta: float) -> void:
	_retry_init_xr(delta)
	_update_controller_trackers(delta)
	_handle_reconnect(delta)
	_handle_latency_probe(delta)
	_update_foveation_focus()

# ---------------------------------------------------------------------------
# XR initialisation
# ---------------------------------------------------------------------------

func _init_xr() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if not xr_interface:
		print("[Immersive-2] OpenXR interface not found, running in desktop mode")
		return

	if _try_enable_xr():
		return

	print("[Immersive-2] OpenXR runtime unavailable, retrying... (check runtime/headset)")

func _try_enable_xr() -> bool:
	if not xr_interface:
		return false

	var xr_ready := xr_interface.is_initialized()
	if not xr_ready:
		xr_ready = xr_interface.initialize()

	if not xr_ready:
		return false

	if _xr_initialized:
		return true

	print("[Immersive-2] OpenXR initialized")
	XRServer.primary_interface = xr_interface
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_viewport().use_xr = true
	_xr_initialized = true
	_left_tracker_locked = false
	_right_tracker_locked = false
	_left_tracker_probe_timer = 0.0
	_right_tracker_probe_timer = 0.0
	_apply_passthrough_settings()
	return true

func _retry_init_xr(delta: float) -> void:
	if _xr_initialized:
		return
	if not xr_interface:
		return
	if _xr_init_attempts >= XR_INIT_MAX_RETRIES:
		return

	_xr_init_retry_timer += delta
	if _xr_init_retry_timer < XR_INIT_RETRY_INTERVAL:
		return

	_xr_init_retry_timer = 0.0
	_xr_init_attempts += 1

	if _try_enable_xr():
		print("[Immersive-2] OpenXR became available after %d retries" % _xr_init_attempts)
		return

	if _xr_init_attempts == XR_INIT_MAX_RETRIES:
		print("[Immersive-2] OpenXR still unavailable after retries; continuing in desktop mode")

func _tracker_has_data(tracker_name: String) -> bool:
	var xr_tracker := XRServer.get_tracker(StringName(tracker_name))
	if not xr_tracker:
		return false
	if xr_tracker.has_method("get_has_tracking_data"):
		return xr_tracker.get_has_tracking_data()
	if xr_tracker.has_method("is_active"):
		return xr_tracker.is_active()
	# Some runtimes expose a tracker object before reporting tracking-data flags.
	return true

func _tracker_exists(tracker_name: String) -> bool:
	return XRServer.get_tracker(StringName(tracker_name)) != null

func _update_controller_trackers(delta: float) -> void:
	if not _xr_initialized:
		return

	if not _left_tracker_locked:
		_left_tracker_probe_timer += delta
	if _left_tracker_probe_timer >= 1.0 and not _left_tracker_locked:
		_left_tracker_probe_timer = 0.0
		_left_tracker_locked = _update_single_controller_tracker(left_controller, LEFT_TRACKER_PROBES, "Left", true, false)

	if not _right_tracker_locked:
		_right_tracker_probe_timer += delta
	if _right_tracker_probe_timer >= 0.5 and not _right_tracker_locked:
		_right_tracker_probe_timer = 0.0
		_right_tracker_locked = _update_single_controller_tracker(right_controller, RIGHT_TRACKER_PROBES, "Right", false, true)

func _update_single_controller_tracker(controller: XRController3D, probes: Array, label: String, is_left: bool, sync_aim: bool) -> bool:
	if not is_instance_valid(controller):
		return false

	var current_tracker := String(controller.tracker)
	if _tracker_has_data(current_tracker):
		if sync_aim and is_instance_valid(right_aim):
			right_aim.tracker = controller.tracker
			right_aim.set("pose", StringName("aim_pose"))
		return true

	for candidate in probes:
		if not _tracker_has_data(candidate):
			continue
		controller.tracker = StringName(candidate)
		controller.set("pose", StringName("grip_pose"))
		if sync_aim and is_instance_valid(right_aim):
			right_aim.tracker = StringName(candidate)
			right_aim.set("pose", StringName("aim_pose"))
		print("[Immersive-2] %s controller switched tracker=%s pose=grip_pose" % [label, candidate])
		return true

	for candidate in probes:
		if not _tracker_exists(candidate):
			continue
		if String(controller.tracker) != candidate:
			controller.tracker = StringName(candidate)
			controller.set("pose", StringName("grip_pose"))
			if sync_aim and is_instance_valid(right_aim):
				right_aim.tracker = StringName(candidate)
				right_aim.set("pose", StringName("aim_pose"))
			print("[Immersive-2] %s controller fallback tracker=%s pose=grip_pose" % [label, candidate])
		return false

	return false

func _init_eye_gaze_controller() -> void:
	if not xr_origin:
		return

	eye_gaze_controller = XRController3D.new()
	eye_gaze_controller.name = "EyeGazeController"
	eye_gaze_controller.tracker = &"/user/eyes_ext"
	eye_gaze_controller.set("pose", &"eye_pose")
	eye_gaze_controller.visible = false
	xr_origin.add_child(eye_gaze_controller)

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

func _init_network() -> void:
	network_client = preload("res://scripts/network_client.gd").new()
	network_client.name = "NetworkClient"
	add_child(network_client)

	network_client.connected_to_host.connect(_on_connected)
	network_client.disconnected_from_host.connect(_on_disconnected)
	network_client.monitor_list_received.connect(_on_monitor_list)
	network_client.stream_started.connect(_on_stream_started)
	network_client.video_frame_received.connect(_on_video_frame)
	network_client.latency_response_received.connect(_on_latency_response)

func connect_to_host() -> void:
	if current_state != State.DISCONNECTED:
		return
	current_state = State.CONNECTING
	_update_overlay_state()
	print("[Immersive-2] Connecting to %s:%d..." % [host_ip, host_tcp_port])
	network_client.connect_to_server(host_ip, host_tcp_port, host_udp_port)
	_should_reconnect = true

func disconnect_from_host() -> void:
	_should_reconnect = false
	if network_client:
		network_client.disconnect_from_server()
	current_state = State.DISCONNECTED
	_update_overlay_state()
	_clear_all_screens()

func select_monitor(monitor_id: int, slot: int = 0) -> void:
	if current_state != State.CONNECTED and current_state != State.STREAMING:
		return
	print("[Immersive-2] Selecting monitor %d for slot %d" % [monitor_id, slot])
	network_client.select_monitor(monitor_id)

# ---------------------------------------------------------------------------
# Screen panels
# ---------------------------------------------------------------------------

func _create_screen_panel(slot: int) -> MeshInstance3D:
	if slot >= MAX_SCREENS:
		return null

	var panel_script = preload("res://scripts/screen_panel.gd")
	var panel := MeshInstance3D.new()
	panel.script = panel_script

	# Spread panels horizontally: center, left, right
	var x_offsets := [0.0, -1.8, 1.8]
	var position := Vector3(x_offsets[slot], 1.6, -2.0)
	panel.transform.origin = position

	var plane := PlaneMesh.new()
	plane.size = Vector2(1.6, 0.9)
	plane.orientation = PlaneMesh.FACE_Z
	panel.mesh = plane

	add_child(panel)
	return panel

func _clear_all_screens() -> void:
	for panel in screen_panels:
		if is_instance_valid(panel):
			panel.queue_free()
	screen_panels.clear()

func _ensure_panel(slot: int) -> MeshInstance3D:
	while screen_panels.size() <= slot:
		screen_panels.append(null)

	if not is_instance_valid(screen_panels[slot]):
		screen_panels[slot] = _create_screen_panel(slot)
		_apply_panel_visual_settings(screen_panels[slot])

	return screen_panels[slot]

func _apply_panel_visual_settings(panel: MeshInstance3D) -> void:
	if panel and panel.has_method("set_curvature"):
		panel.set_curvature(curved_screen_enabled, curved_screen_amount)
	if panel and panel.has_method("set_foveation"):
		panel.set_foveation(foveation_enabled, foveation_strength)

func _apply_visual_settings_to_all_panels() -> void:
	for panel in screen_panels:
		if is_instance_valid(panel):
			_apply_panel_visual_settings(panel)

## Resolve which streamed panel is hit by a world-space ray.
## Returns { valid: bool, panel: MeshInstance3D, uv: Vector2, distance: float, monitor_id: int }.
func get_panel_hit_from_ray(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	var best_panel: MeshInstance3D = null
	var best_uv := Vector2(0.5, 0.5)
	var best_distance := INF

	for panel in screen_panels:
		if not is_instance_valid(panel) or not panel.has_method("ray_to_screen_hit"):
			continue
		var hit: Dictionary = panel.ray_to_screen_hit(ray_origin, ray_direction)
		if not hit.get("valid", false):
			continue

		var dist: float = hit.get("distance", INF)
		if dist < best_distance:
			best_distance = dist
			best_panel = panel
			best_uv = hit.get("uv", Vector2(0.5, 0.5))

	if best_panel == null:
		return {"valid": false}

	return {
		"valid": true,
		"panel": best_panel,
		"uv": best_uv,
		"distance": best_distance,
		"monitor_id": int(best_panel.get_meta("monitor_id", 0))
	}

func get_ui_hit_from_ray(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	if ui_overlay and ui_overlay.has_method("ray_to_overlay_hit"):
		return ui_overlay.ray_to_overlay_hit(ray_origin, ray_direction)
	return {"valid": false}

func send_ui_pointer_move(uv: Vector2) -> void:
	if ui_overlay and ui_overlay.has_method("inject_pointer_move"):
		ui_overlay.inject_pointer_move(uv)

func send_ui_pointer_button(pressed: bool, button_index: int = MOUSE_BUTTON_LEFT) -> void:
	if ui_overlay and ui_overlay.has_method("inject_pointer_button"):
		ui_overlay.inject_pointer_button(pressed, button_index)

func send_ui_pointer_scroll(delta_y: float) -> void:
	if ui_overlay and ui_overlay.has_method("inject_pointer_scroll"):
		ui_overlay.inject_pointer_scroll(delta_y)

# ---------------------------------------------------------------------------
# UI Overlay
# ---------------------------------------------------------------------------

func _init_ui_overlay() -> void:
	ui_overlay = preload("res://scripts/ui_overlay.gd").new()
	ui_overlay.name = "UIOverlay"

	# Position overlay near origin — it repositions itself in front of camera
	add_child(ui_overlay)

	# Connect overlay signals
	if ui_overlay.has_signal("connect_requested"):
		ui_overlay.connect_requested.connect(_on_overlay_connect_requested)
	if ui_overlay.has_signal("monitor_selected"):
		ui_overlay.monitor_selected.connect(_on_overlay_monitor_selected)
	if ui_overlay.has_signal("screen_curvature_changed"):
		ui_overlay.screen_curvature_changed.connect(_on_overlay_screen_curvature_changed)
	if ui_overlay.has_signal("foveation_settings_changed"):
		ui_overlay.foveation_settings_changed.connect(_on_overlay_foveation_settings_changed)
	if ui_overlay.has_signal("passthrough_toggled"):
		ui_overlay.passthrough_toggled.connect(_on_overlay_passthrough_toggled)
	if ui_overlay.has_signal("workspace_save_requested"):
		ui_overlay.workspace_save_requested.connect(_on_overlay_workspace_save_requested)
	if ui_overlay.has_signal("workspace_restore_requested"):
		ui_overlay.workspace_restore_requested.connect(_on_overlay_workspace_restore_requested)

	if ui_overlay.has_method("set_screen_curvature"):
		ui_overlay.set_screen_curvature(curved_screen_enabled, curved_screen_amount)
	if ui_overlay.has_method("set_foveation_settings"):
		ui_overlay.set_foveation_settings(foveation_enabled, foveation_strength)
	if ui_overlay.has_method("set_passthrough_settings"):
		ui_overlay.set_passthrough_settings(passthrough_enabled, _is_passthrough_supported())

func _update_overlay_state() -> void:
	if ui_overlay and ui_overlay.has_method("set_state"):
		ui_overlay.set_state(current_state as int)

# ---------------------------------------------------------------------------
# Reconnect logic
# ---------------------------------------------------------------------------

func _handle_reconnect(delta: float) -> void:
	if _should_reconnect and current_state == State.DISCONNECTED:
		_reconnect_timer += delta
		if _reconnect_timer >= RECONNECT_DELAY:
			_reconnect_timer = 0.0
			print("[Immersive-2] Attempting auto-reconnect to %s..." % host_ip)
			connect_to_host()

# ---------------------------------------------------------------------------
# Latency probing
# ---------------------------------------------------------------------------

func _handle_latency_probe(delta: float) -> void:
	if current_state != State.STREAMING and current_state != State.CONNECTED:
		return
	_latency_timer += delta
	if _latency_timer >= LATENCY_INTERVAL:
		_latency_timer = 0.0
		_send_latency_probe()

func _send_latency_probe() -> void:
	if not network_client or not network_client.has_method("send_latency_probe"):
		return
	_probe_id += 1
	_probe_sent_us = Time.get_ticks_usec()
	network_client.send_latency_probe(_probe_id, _probe_sent_us)

# ---------------------------------------------------------------------------
# Callbacks — network events
# ---------------------------------------------------------------------------

func _on_connected() -> void:
	current_state = State.CONNECTED
	_reconnect_timer = 0.0
	_update_overlay_state()
	if _workspace_panel_layouts.size() > 0:
		_pending_workspace_restore = true
	print("[Immersive-2] Connected to host")

func _on_disconnected() -> void:
	current_state = State.DISCONNECTED
	_update_overlay_state()
	print("[Immersive-2] Disconnected from host")

func _on_monitor_list(monitors: Array) -> void:
	available_monitors = monitors
	print("[Immersive-2] Available monitors: %d" % monitors.size())
	for m in monitors:
		print("  [%d] %s (%dx%d)" % [m.id, m.name, m.width, m.height])

	if ui_overlay and ui_overlay.has_method("set_monitor_list"):
		ui_overlay.set_monitor_list(monitors)

	if _pending_workspace_restore and _workspace_monitor_ids.size() > 0:
		if _request_workspace_monitors():
			return

	# Default monitor selection
	if monitors.size() > 0:
		select_monitor(monitors[0].id, 0)

func _on_stream_started(monitor_id: int, width: int, height: int, codec: int = 2) -> void:
	current_state = State.STREAMING
	_update_overlay_state()
	print("[Immersive-2] Streaming monitor %d (%dx%d) codec=%d" % [monitor_id, width, height, codec])

	# Assign to slot 0 by default; subsequent calls go to slot 1, 2
	var slot := 0
	for i in range(screen_panels.size()):
		if not is_instance_valid(screen_panels[i]):
			slot = i
			break
		slot = i + 1

	var panel := _ensure_panel(min(slot, MAX_SCREENS - 1))
	if panel and panel.has_method("set_resolution"):
		panel.set_resolution(width, height, codec)
		_apply_panel_visual_settings(panel)
		panel.set_meta("monitor_id", monitor_id)

		var saved_layout := _find_saved_layout_for_monitor(monitor_id)
		if saved_layout.is_empty():
			saved_layout = _find_saved_layout_for_slot(slot)
		if panel.has_method("apply_layout_state") and not saved_layout.is_empty():
			panel.apply_layout_state(saved_layout)

	_mark_workspace_restored_if_complete()

func _on_video_frame(frame_data: PackedByteArray, width: int, height: int) -> void:
	# Deliver frame to the matching panel (by monitor_id stored in meta)
	# For now, deliver to the first active panel
	for panel in screen_panels:
		if is_instance_valid(panel) and panel.has_method("update_texture"):
			panel.update_texture(frame_data, width, height)
			break

func _on_latency_response(probe_id: int, _client_ts: int) -> void:
	if probe_id != _probe_id:
		return
	var now_us: int = Time.get_ticks_usec()
	_latency_ms = float(now_us - _probe_sent_us) / 1000.0

	if ui_overlay and ui_overlay.has_method("set_latency"):
		ui_overlay.set_latency(_latency_ms)

	# Also update each screen panel's latency indicator
	for panel in screen_panels:
		if is_instance_valid(panel) and panel.has_method("set_latency"):
			panel.set_latency(_latency_ms)

# ---------------------------------------------------------------------------
# Callbacks — overlay signals
# ---------------------------------------------------------------------------

func _on_overlay_connect_requested(ip: String, tcp_port: int, udp_port: int) -> void:
	if ip.is_empty():
		disconnect_from_host()
		return
	host_ip = ip
	host_tcp_port = tcp_port
	host_udp_port = udp_port
	_save_config()
	if current_state == State.DISCONNECTED:
		connect_to_host()

func _on_overlay_monitor_selected(monitor_id: int) -> void:
	select_monitor(monitor_id, 0)

func _on_overlay_screen_curvature_changed(enabled: bool, amount: float) -> void:
	curved_screen_enabled = enabled
	curved_screen_amount = clamp(amount, 0.0, 0.5)
	_apply_visual_settings_to_all_panels()
	_save_config()

func _on_overlay_foveation_settings_changed(enabled: bool, strength: float) -> void:
	foveation_enabled = enabled
	foveation_strength = clamp(strength, 0.0, 1.0)
	_apply_visual_settings_to_all_panels()
	_save_config()

func _on_overlay_passthrough_toggled(enabled: bool) -> void:
	passthrough_enabled = enabled
	_apply_passthrough_settings()
	_save_config()

func _on_overlay_workspace_save_requested() -> void:
	save_workspace_layout()

func _on_overlay_workspace_restore_requested() -> void:
	restore_workspace_layout()

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

## Called from vr_input.gd.
func send_mouse_input(monitor_id: int, x: int, y: int, buttons: int, scroll: int) -> void:
	if current_state == State.STREAMING and network_client:
		network_client.send_mouse_input(monitor_id, x, y, buttons, scroll)

func send_keyboard_input(monitor_id: int, scancode: int, pressed: bool, modifiers: int) -> void:
	if current_state == State.STREAMING and network_client:
		network_client.send_keyboard_input(monitor_id, scancode, pressed, modifiers)

## Toggle overlay via controller button (called from vr_input.gd).
func toggle_ui_overlay() -> void:
	if ui_overlay and ui_overlay.has_method("toggle_visibility"):
		ui_overlay.toggle_visibility()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_C:
				if current_state == State.DISCONNECTED:
					connect_to_host()
			KEY_D:
				disconnect_from_host()
			KEY_O:
				toggle_ui_overlay()
			KEY_ESCAPE:
				get_tree().quit()

func _update_foveation_focus() -> void:
	if not foveation_enabled:
		return

	var ray := _resolve_gaze_ray()
	var ray_origin: Vector3 = ray["origin"]
	var ray_direction: Vector3 = ray["direction"]
	var hit := get_panel_hit_from_ray(ray_origin, ray_direction)
	var best_panel: MeshInstance3D = hit.get("panel", null)
	var best_uv: Vector2 = hit.get("uv", Vector2(0.5, 0.5))

	for panel in screen_panels:
		if not is_instance_valid(panel) or not panel.has_method("set_foveation_focus_uv"):
			continue
		if panel == best_panel:
			panel.set_foveation_focus_uv(best_uv)
		else:
			panel.set_foveation_focus_uv(Vector2(0.5, 0.5))

func _resolve_gaze_ray() -> Dictionary:
	var origin := xr_camera.global_transform.origin
	var direction := (-xr_camera.global_transform.basis.z).normalized()

	if is_instance_valid(eye_gaze_controller):
		var has_tracking := false
		if eye_gaze_controller.has_method("get_has_tracking_data"):
			has_tracking = eye_gaze_controller.get_has_tracking_data()
		elif eye_gaze_controller.has_method("is_active"):
			has_tracking = eye_gaze_controller.is_active()

		if has_tracking:
			origin = eye_gaze_controller.global_transform.origin
			direction = (-eye_gaze_controller.global_transform.basis.z).normalized()

	return {
		"origin": origin,
		"direction": direction
	}

func save_workspace_layout() -> void:
	var panel_states: Array = []
	var monitor_ids: Array = []

	for i in range(screen_panels.size()):
		var panel = screen_panels[i]
		if not is_instance_valid(panel) or not panel.has_method("get_layout_state"):
			continue

		var monitor_id: int = int(panel.get_meta("monitor_id", -1))
		if monitor_id >= 0:
			monitor_ids.append(monitor_id)

		panel_states.append({
			"slot": i,
			"monitor_id": monitor_id,
			"layout": panel.get_layout_state()
		})

	if panel_states.is_empty():
		print("[Immersive-2] Workspace save skipped: no active panels")
		return

	var payload := {
		"version": 1,
		"monitor_ids": monitor_ids,
		"panels": panel_states
	}

	var file := FileAccess.open(WORKSPACE_PATH, FileAccess.WRITE)
	if not file:
		push_error("[Immersive-2] Failed to open workspace file for writing")
		return

	file.store_string(JSON.stringify(payload, "\t"))
	_workspace_monitor_ids = monitor_ids.duplicate()
	_workspace_panel_layouts = panel_states.duplicate(true)
	print("[Immersive-2] Workspace saved (%d panel(s))" % panel_states.size())

func restore_workspace_layout() -> void:
	_load_workspace_layout()
	if _workspace_panel_layouts.is_empty():
		print("[Immersive-2] Workspace restore skipped: no saved layout")
		return

	_pending_workspace_restore = true
	_clear_all_screens()

	if current_state == State.CONNECTED or current_state == State.STREAMING:
		_request_workspace_monitors()

func _load_workspace_layout() -> void:
	_workspace_monitor_ids.clear()
	_workspace_panel_layouts.clear()
	_pending_workspace_restore = false

	if not FileAccess.file_exists(WORKSPACE_PATH):
		return

	var file := FileAccess.open(WORKSPACE_PATH, FileAccess.READ)
	if not file:
		return

	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return

	_workspace_monitor_ids = parsed.get("monitor_ids", [])
	_workspace_panel_layouts = parsed.get("panels", [])
	_pending_workspace_restore = _workspace_panel_layouts.size() > 0

func _request_workspace_monitors() -> bool:
	if not network_client:
		return false

	var available_ids: Array = []
	for mon in available_monitors:
		available_ids.append(mon.id)

	var selected_ids: Array = []
	for mon_id in _workspace_monitor_ids:
		if available_ids.has(mon_id):
			selected_ids.append(mon_id)
		if selected_ids.size() >= MAX_SCREENS:
			break

	if selected_ids.is_empty():
		return false

	if network_client.has_method("select_monitors") and selected_ids.size() > 1:
		network_client.select_monitors(selected_ids)
	else:
		network_client.select_monitor(selected_ids[0])

	print("[Immersive-2] Restoring workspace monitors: %s" % selected_ids)
	return true

func _find_saved_layout_for_monitor(monitor_id: int) -> Dictionary:
	for item in _workspace_panel_layouts:
		if int(item.get("monitor_id", -1)) == monitor_id:
			return item.get("layout", {})
	return {}

func _find_saved_layout_for_slot(slot: int) -> Dictionary:
	for item in _workspace_panel_layouts:
		if int(item.get("slot", -1)) == slot:
			return item.get("layout", {})
	return {}

func _mark_workspace_restored_if_complete() -> void:
	if not _pending_workspace_restore:
		return

	var restored_count := 0
	for panel in screen_panels:
		if is_instance_valid(panel) and int(panel.get_meta("monitor_id", -1)) >= 0:
			restored_count += 1

	if restored_count >= min(_workspace_monitor_ids.size(), MAX_SCREENS):
		_pending_workspace_restore = false

func _is_passthrough_supported() -> bool:
	if not xr_interface or not xr_interface.is_initialized():
		return false
	var supported_modes: Array = xr_interface.get_supported_environment_blend_modes()
	return XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in supported_modes

func _apply_passthrough_settings() -> void:
	var viewport := get_viewport()
	if not xr_interface or not xr_interface.is_initialized():
		viewport.transparent_bg = false
		return

	var passthrough_supported := _is_passthrough_supported()
	if passthrough_enabled and not passthrough_supported:
		passthrough_enabled = false
		print("[Immersive-2] Passthrough is not supported by this OpenXR runtime")

	var target_mode := XRInterface.XR_ENV_BLEND_MODE_OPAQUE
	if passthrough_enabled:
		target_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND

	if not xr_interface.set_environment_blend_mode(target_mode):
		if passthrough_enabled:
			passthrough_enabled = false
			xr_interface.set_environment_blend_mode(XRInterface.XR_ENV_BLEND_MODE_OPAQUE)
			print("[Immersive-2] Failed to enable passthrough, falling back to opaque mode")

	viewport.transparent_bg = passthrough_enabled

	if ui_overlay and ui_overlay.has_method("set_passthrough_settings"):
		ui_overlay.set_passthrough_settings(passthrough_enabled, passthrough_supported)

# ---------------------------------------------------------------------------
# Config persistence
# ---------------------------------------------------------------------------

func _save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("network", "host_ip", host_ip)
	cfg.set_value("network", "tcp_port", host_tcp_port)
	cfg.set_value("network", "udp_port", host_udp_port)
	cfg.set_value("display", "curved_enabled", curved_screen_enabled)
	cfg.set_value("display", "curved_amount", curved_screen_amount)
	cfg.set_value("display", "foveation_enabled", foveation_enabled)
	cfg.set_value("display", "foveation_strength", foveation_strength)
	cfg.set_value("display", "passthrough_enabled", passthrough_enabled)
	cfg.save(CONFIG_PATH)

func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		host_ip       = cfg.get_value("network", "host_ip", "192.168.1.100")
		host_tcp_port = cfg.get_value("network", "tcp_port", 19800)
		host_udp_port = cfg.get_value("network", "udp_port", 19801)
		curved_screen_enabled = cfg.get_value("display", "curved_enabled", false)
		curved_screen_amount = cfg.get_value("display", "curved_amount", 0.18)
		foveation_enabled = cfg.get_value("display", "foveation_enabled", false)
		foveation_strength = cfg.get_value("display", "foveation_strength", 0.55)
		passthrough_enabled = cfg.get_value("display", "passthrough_enabled", false)
