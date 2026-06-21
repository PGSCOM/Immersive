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
@onready var virtual_keyboard: VirtualKeyboard = get_node_or_null("VirtualKeyboard") as VirtualKeyboard

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

## Persisted environment index (loaded from config, applied after env_manager init).
var _saved_environment_index: int = 0

# Stream quality settings (sent to the host via STREAM_CONFIG).
## Protocol codec value: 0 = H.264, 1 = HEVC, 2 = MJPEG, 3 = AV1.
## Resolved from the device's decode capability in _load_config(); see
## _default_codec_for_device(). We never send 0xFF ("let the host decide")
## from a headset — the host would pick software MJPEG, which a mobile CPU
## cannot sustain at desktop resolution.
var stream_codec: int = 0
var stream_bitrate_kbps: int = 8000
var stream_jpeg_quality: int = 70
var stream_res_percent: int = 100   ## 100/75/50, -1 = auto (ideal)
var stream_max_width: int = 0       ## computed target width; 0 = native
var stream_fps: int = 0             ## 0 = auto

var available_monitors: Array = []

## Monitors currently selected for streaming (up to MAX_SCREENS).
var active_monitor_ids: Array = []

## Active screen panels (up to MAX_SCREENS).
var screen_panels: Array = []

## Network client (lazy-created).
var network_client: Node = null

## Audio receiver (created when the host announces audio).
var audio_receiver: Node = null

## Hardware video decoders per monitor (H.264/HEVC/AV1 via MediaCodec).
var _decoders: Dictionary = {}

## Software (CPU) MJPEG decoders per monitor, used on platforms with no hardware
## MediaCodec plugin: PC (Windows/Linux/macOS), iOS and web. Threaded JPEG decode.
var _sw_decoders: Dictionary = {}

## Last keyframe-request time per monitor (ms), to throttle loss recovery.
var _last_keyframe_req_ms: Dictionary = {}

## Decoders awaiting their first decoded frame -> open time (ms). Used to keep
## asking the host for a keyframe until the freshly-opened decoder catches a
## clean intra (cold-start recovery for inter-frame codecs).
var _decoder_pending_first: Dictionary = {}

## Whether we already auto-fell back to MJPEG this session (avoids loops).
var _codec_fallback_sent: bool = false

## Monitors awaiting an IDR keyframe after a frame gap (Fase 3 recovery).
var _awaiting_idr: Dictionary = {}

# ---------------------------------------------------------------------------
# Test/debug harness — driven from immersive2_config.cfg [test] section or
# --im2-host=/--im2-port=/--im2-capture command-line args (adb am ... --esa
# command_line). Lets the client be launched + connected + visually verified
# from adb without a headset on the user. Inert in normal use.
# ---------------------------------------------------------------------------
var _autoconnect_on_start: bool = false
var _debug_capture: bool = false
var _debug_capture_accum: float = 0.0
var _debug_capture_count: int = 0

## UI overlay (lazy-created).
var ui_overlay: Node = null

## XR interface (managed by XRStarter).
var xr_interface: XRInterface = null
var eye_gaze_controller: XRController3D = null
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

## Guard so _ready() runs its one-time setup exactly once even if invoked manually
## (e.g. headless tests force it because the engine defers _ready in that harness).
var _ready_done: bool = false

func _ready() -> void:
	if _ready_done:
		return
	_ready_done = true
	_load_config()
	_load_workspace_layout()
	_init_eye_gaze_controller()
	_init_hand_input()
	_init_network()
	_init_ui_overlay()
	_init_world_features()
	_init_multiuser()
	if _autoconnect_on_start:
		print("[Immersive-2][TEST] Autoconnect enabled -> %s:%d (capture=%s)" %
			[host_ip, host_tcp_port, str(_debug_capture)])
		connect_to_host()
	elif current_state == State.DISCONNECTED and ui_overlay and ui_overlay.has_method("toggle_visibility"):
		ui_overlay.toggle_visibility()
	print("[Immersive-2] VR Client started — press B/Y to open overlay")

func _process(delta: float) -> void:
	_handle_reconnect(delta)
	_handle_latency_probe(delta)
	_update_foveation_focus()
	_handle_keyframe_retries()
	_handle_debug_capture(delta)
	_update_decoders()
	_pump_multiuser()
	_broadcast_local_pose(delta)
	_broadcast_screen_layout(delta)
	_handle_locomotion()

# ---------------------------------------------------------------------------
# XR helpers
# ---------------------------------------------------------------------------

func _init_eye_gaze_controller() -> void:
	if not xr_origin:
		return

	eye_gaze_controller = XRController3D.new()
	eye_gaze_controller.name = "EyeGazeController"
	eye_gaze_controller.tracker = &"/user/eyes_ext"
	eye_gaze_controller.pose = &"eye_pose"
	eye_gaze_controller.visible = false
	xr_origin.add_child(eye_gaze_controller)

## Bare-hand (controller-free) pointer + pinch input. Inert until the OpenXR
## runtime reports optical hand tracking, so it's harmless on controller setups.
## See scripts/hand_input.gd for the gesture mapping (Pico 4 / Quest / SteamVR).
func _init_hand_input() -> void:
	var hand_input := preload("res://scripts/hand_input.gd").new()
	hand_input.name = "HandInput"
	add_child(hand_input)

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
	network_client.stream_stopped.connect(_on_stream_stopped)
	network_client.video_frame_received.connect(_on_video_frame)
	network_client.latency_response_received.connect(_on_latency_response)
	network_client.audio_stream_started.connect(_on_audio_stream_started)
	network_client.audio_stream_stopped.connect(_on_audio_stream_stopped)
	network_client.frame_gap_detected.connect(_on_frame_gap)

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
	if audio_receiver:
		audio_receiver.stop()
	current_state = State.DISCONNECTED
	active_monitor_ids.clear()
	_update_overlay_state()
	_update_overlay_monitors()
	_clear_all_screens()

## Toggle a monitor: selecting a new one adds a screen (up to MAX_SCREENS),
## selecting an active one removes its screen. The full selection is sent to
## the host, which reconciles its per-monitor streams.
func select_monitor(monitor_id: int, _slot: int = 0) -> void:
	if current_state != State.CONNECTED and current_state != State.STREAMING:
		return

	if active_monitor_ids.has(monitor_id):
		if active_monitor_ids.size() <= 1:
			return  # keep at least one active stream
		active_monitor_ids.erase(monitor_id)
	else:
		if active_monitor_ids.size() >= MAX_SCREENS:
			active_monitor_ids.pop_front()  # replace the oldest selection
		active_monitor_ids.append(monitor_id)

	_send_monitor_selection()
	_update_overlay_monitors()

func _send_monitor_selection() -> void:
	if not network_client or active_monitor_ids.is_empty():
		return
	print("[Immersive-2] Requesting monitors: %s" % [active_monitor_ids])
	if active_monitor_ids.size() == 1:
		network_client.select_monitor(active_monitor_ids[0])
	else:
		network_client.select_monitors(active_monitor_ids)

# ---------------------------------------------------------------------------
# Screen panels
# ---------------------------------------------------------------------------

func _create_screen_panel(slot: int) -> MeshInstance3D:
	if slot >= MAX_SCREENS:
		return null

	var panel_script = preload("res://scripts/screen_panel.gd")
	var panel := MeshInstance3D.new()
	panel.script = panel_script

	# Spread panels horizontally: center, left, right.
	# Placed at a real-monitor-like distance (~1.1 m) and eye height (1.6 m).
	var x_offsets := [0.0, -1.25, 1.25]
	var position := Vector3(x_offsets[slot], 1.6, -1.1)
	panel.transform.origin = position

	var plane := PlaneMesh.new()
	plane.size = Vector2(1.6, 0.9)
	plane.orientation = PlaneMesh.FACE_Z
	panel.mesh = plane

	add_child(panel)
	return panel

func _clear_all_screens() -> void:
	_close_all_decoders()
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

## Grab/release the overlay so it can be repositioned with the grip.
func start_ui_drag(controller: Node3D) -> void:
	if ui_overlay and ui_overlay.has_method("start_drag"):
		ui_overlay.start_drag(controller)

func stop_ui_drag() -> void:
	if ui_overlay and ui_overlay.has_method("stop_drag"):
		ui_overlay.stop_drag()

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
	if ui_overlay.has_signal("stream_settings_changed"):
		ui_overlay.stream_settings_changed.connect(_on_overlay_stream_settings_changed)
	if ui_overlay.has_signal("auto_quality_requested"):
		ui_overlay.auto_quality_requested.connect(_on_overlay_auto_quality_requested)
	if ui_overlay.has_signal("environment_cycle_requested"):
		ui_overlay.environment_cycle_requested.connect(_on_overlay_environment_cycle)
	if ui_overlay.has_signal("environment_selected"):
		ui_overlay.environment_selected.connect(_on_overlay_environment_selected)
	if ui_overlay.has_signal("portal_add_requested"):
		ui_overlay.portal_add_requested.connect(_on_overlay_portal_add)
	if ui_overlay.has_signal("keyboard_portal_requested"):
		ui_overlay.keyboard_portal_requested.connect(_on_overlay_keyboard_portal)
	if ui_overlay.has_signal("whiteboard_toggle_requested"):
		ui_overlay.whiteboard_toggle_requested.connect(_on_overlay_whiteboard_toggle)
	if ui_overlay.has_signal("room_join_requested"):
		ui_overlay.room_join_requested.connect(_on_overlay_room_join)
	if ui_overlay.has_signal("room_leave_requested"):
		ui_overlay.room_leave_requested.connect(_on_overlay_room_leave)
	if ui_overlay.has_signal("mic_mute_toggled"):
		ui_overlay.mic_mute_toggled.connect(toggle_mic_mute)
	if ui_overlay.has_signal("lobby_list_requested"):
		ui_overlay.lobby_list_requested.connect(_on_overlay_lobby_list_requested)
	if ui_overlay.has_signal("monitor_share_toggled"):
		ui_overlay.monitor_share_toggled.connect(_on_overlay_monitor_share_toggled)
	if ui_overlay.has_signal("keyboard_toggle_requested"):
		ui_overlay.keyboard_toggle_requested.connect(toggle_virtual_keyboard)
	if ui_overlay.has_signal("whiteboard_clear_requested"):
		ui_overlay.whiteboard_clear_requested.connect(clear_whiteboard)
	if ui_overlay.has_signal("whiteboard_save_requested"):
		ui_overlay.whiteboard_save_requested.connect(save_whiteboard_snapshot)
	if ui_overlay.has_signal("portals_clear_requested"):
		ui_overlay.portals_clear_requested.connect(clear_portals)

	if ui_overlay.has_method("set_screen_curvature"):
		ui_overlay.set_screen_curvature(curved_screen_enabled, curved_screen_amount)
	if ui_overlay.has_method("set_foveation_settings"):
		ui_overlay.set_foveation_settings(foveation_enabled, foveation_strength)
	if ui_overlay.has_method("set_passthrough_settings"):
		ui_overlay.set_passthrough_settings(passthrough_enabled, _is_passthrough_supported())
	if ui_overlay.has_method("set_stream_settings"):
		ui_overlay.set_stream_settings(stream_codec, stream_bitrate_kbps,
			stream_jpeg_quality, stream_res_percent, stream_fps)

func _update_overlay_state() -> void:
	if ui_overlay and ui_overlay.has_method("set_state"):
		ui_overlay.set_state(current_state as int)

# ---------------------------------------------------------------------------
# Stream quality
# ---------------------------------------------------------------------------

func _send_stream_config() -> void:
	if network_client and network_client.has_method("send_stream_config"):
		network_client.send_stream_config(stream_codec, stream_bitrate_kbps,
			stream_jpeg_quality, stream_max_width, stream_fps)

## Native width of the monitor shown on the first active panel (or first
## available monitor) — reference for percentage-based downscaling.
func _reference_monitor() -> Dictionary:
	var mon_id := -1
	for panel in screen_panels:
		if is_instance_valid(panel):
			mon_id = int(panel.get_meta("monitor_id", -1))
			break
	if mon_id < 0 and not active_monitor_ids.is_empty():
		mon_id = active_monitor_ids[0]
	for m in available_monitors:
		if m.id == mon_id:
			return m
	if not available_monitors.is_empty():
		return available_monitors[0]
	return {"id": -1, "width": 1920, "height": 1080, "refresh_rate": 60}

func _recompute_stream_max_width() -> void:
	if stream_res_percent == 100:
		stream_max_width = 0
	elif stream_res_percent > 0:
		var native_w: int = _reference_monitor().get("width", 1920)
		stream_max_width = int(native_w * stream_res_percent / 100.0)
	elif stream_res_percent == -1:
		var ideal := compute_ideal_stream_settings()
		stream_max_width = ideal["width"]
		if stream_fps == 0:
			stream_fps = ideal["fps"]

## Perceptual "ideal" stream settings: matches the stream's pixel density to
## what the headset can actually resolve for the panel at its current size
## and distance, and the FPS to what headset+monitor can display.
##
##   PPD (pixels/degree) = eye render target width / horizontal FOV
##   panel angular size  = 2*atan(panel_width / (2*distance))
##   ideal width (px)    = PPD * panel angle, capped to the native width
func compute_ideal_stream_settings() -> Dictionary:
	var panel_w_m := 1.6
	var distance := 2.0
	var ref_panel: MeshInstance3D = null
	for p in screen_panels:
		if is_instance_valid(p):
			ref_panel = p
			break
	if ref_panel:
		panel_w_m = ref_panel.panel_width
		if xr_camera:
			distance = (ref_panel.global_transform.origin
				- xr_camera.global_transform.origin).length()

	var mon := _reference_monitor()
	var native_w: int = mon.get("width", 1920)
	var native_h: int = mon.get("height", 1080)
	var native_hz: int = mon.get("refresh_rate", 60)

	# Headset pixels-per-degree from the XR eye buffer (approx. 95° hFOV)
	var vp_w := float(get_viewport().size.x)
	var hmd_fov_deg := 95.0
	var ppd: float = max(8.0, vp_w / hmd_fov_deg)

	var panel_angle_deg := rad_to_deg(2.0 * atan(panel_w_m / (2.0 * max(0.3, distance))))
	var ideal_w := int(clamp(ppd * panel_angle_deg, 480.0, float(native_w)))
	ideal_w = int(round(ideal_w / 16.0)) * 16
	var ideal_h := int(round(float(native_h) * float(ideal_w) / float(native_w)))

	# FPS: limited by both the headset and the monitor; MJPEG capped at 30
	var hmd_hz := 72.0
	var xr := XRServer.get_primary_interface()
	if xr and xr.has_method("get_display_refresh_rate"):
		var r: float = xr.get_display_refresh_rate()
		if r > 0.0:
			hmd_hz = r
	var ideal_fps: int = int(min(float(native_hz), hmd_hz))
	if stream_codec == 2:  # only software MJPEG needs the WiFi-friendly FPS cap
		ideal_fps = min(ideal_fps, 30)

	return {
		"width": ideal_w,
		"height": ideal_h,
		"fps": ideal_fps,
		"ppd": ppd,
		"angle_deg": panel_angle_deg,
		"distance": distance,
	}

func _on_overlay_stream_settings_changed(codec: int, bitrate_kbps: int,
		jpeg_quality: int, res_percent: int, fps: int) -> void:
	stream_codec = _resolve_codec(codec)
	stream_bitrate_kbps = clamp(bitrate_kbps, 1000, 100000)
	stream_jpeg_quality = clamp(jpeg_quality, 10, 95)
	stream_res_percent = res_percent
	stream_fps = clamp(fps, 0, 120)
	_recompute_stream_max_width()
	_save_config()
	_send_stream_config()
	# Reflect the resolved codec back to the UI (e.g. "Auto" → "H.264") so the
	# highlighted button matches what is actually being streamed.
	if stream_codec != codec and ui_overlay and ui_overlay.has_method("set_stream_settings"):
		ui_overlay.set_stream_settings(stream_codec, stream_bitrate_kbps,
			stream_jpeg_quality, stream_res_percent, stream_fps)

func _on_overlay_auto_quality_requested() -> void:
	var ideal := compute_ideal_stream_settings()
	stream_res_percent = -1
	stream_max_width = ideal["width"]
	stream_fps = ideal["fps"]
	_save_config()
	_send_stream_config()
	if ui_overlay and ui_overlay.has_method("set_auto_quality_result"):
		ui_overlay.set_auto_quality_result(
			ideal["width"], ideal["height"], ideal["fps"],
			ideal["ppd"], ideal["angle_deg"], ideal["distance"])
	if ui_overlay and ui_overlay.has_method("set_stream_settings"):
		ui_overlay.set_stream_settings(stream_codec, stream_bitrate_kbps,
			stream_jpeg_quality, stream_res_percent, stream_fps)

func _update_overlay_monitors() -> void:
	if ui_overlay and ui_overlay.has_method("set_active_monitors"):
		ui_overlay.set_active_monitors(active_monitor_ids)

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
	_codec_fallback_sent = false
	_update_overlay_state()
	# Send quality settings before any stream starts (TCP preserves order)
	_recompute_stream_max_width()
	_send_stream_config()
	if _workspace_panel_layouts.size() > 0:
		_pending_workspace_restore = true
	print("[Immersive-2] Connected to host")

func _on_disconnected() -> void:
	current_state = State.DISCONNECTED
	_update_overlay_state()
	if audio_receiver:
		audio_receiver.stop()
	print("[Immersive-2] Disconnected from host")

func _on_monitor_list(monitors: Array) -> void:
	available_monitors = monitors
	print("[Immersive-2] Available monitors: %d" % monitors.size())
	for m in monitors:
		print("  [%d] %s (%dx%d)" % [m.id, m.name, m.width, m.height])

	# Register each monitor with the privacy manager so it can be shared by name.
	if privacy_manager:
		for m in monitors:
			privacy_manager.register_monitor(m.id, m.get("name", "Monitor"), m.width, m.height)

	if ui_overlay and ui_overlay.has_method("set_monitor_list"):
		ui_overlay.set_monitor_list(monitors)
	_sync_share_ui()

	if _pending_workspace_restore and _workspace_monitor_ids.size() > 0:
		if _request_workspace_monitors():
			return

	# After a reconnect, re-request the monitors that were active before
	if not active_monitor_ids.is_empty():
		var still_available: Array = []
		for mon_id in active_monitor_ids:
			for m in monitors:
				if m.id == mon_id:
					still_available.append(mon_id)
					break
		active_monitor_ids = still_available
		if not active_monitor_ids.is_empty():
			_send_monitor_selection()
			return

	# Default monitor selection
	if monitors.size() > 0:
		select_monitor(monitors[0].id, 0)

func _on_stream_started(monitor_id: int, width: int, height: int, codec: int = 2) -> void:
	current_state = State.STREAMING
	_update_overlay_state()
	print("[Immersive-2] Streaming monitor %d (%dx%d) codec=%d" % [monitor_id, width, height, codec])

	# Keep the local selection in sync (covers workspace-restore startups)
	if not active_monitor_ids.has(monitor_id):
		if active_monitor_ids.size() >= MAX_SCREENS:
			active_monitor_ids.pop_front()
		active_monitor_ids.append(monitor_id)
	_update_overlay_monitors()

	# Set up (or tear down) the decoder for this monitor's codec.
	_close_decoder(monitor_id)
	if codec in [0, 1, 3]:  # H.264 / HEVC / AV1 — hardware (MediaCodec)
		var dec := VideoDecoder.new()
		if dec.open(codec, width, height):
			_decoders[monitor_id] = dec
			# Drop every frame until the first IDR: a fresh decoder cannot
			# reference a P-frame with no prior I-frame context.
			_awaiting_idr[monitor_id] = true
			# Track that we're waiting for the first IDR. We do NOT send
			# REQUEST_KEYFRAME: the host encoder always starts a stream with
			# an IDR (force_keyframe_ = true on init), so the auto-GOP IDR
			# will arrive within the first frame. Repeated requests trigger
			# oversized forced IDRs that congest WiFi.
			_decoder_pending_first[monitor_id] = Time.get_ticks_msec()
		else:
			_request_codec_fallback(codec)
	elif codec == 2 and SoftwareVideoDecoder.is_codec_supported(codec):
		# MJPEG — software (CPU) decode for PC / iOS / web (no MediaCodec plugin).
		var sw := SoftwareVideoDecoder.new()
		if sw.open(codec, width, height):
			_sw_decoders[monitor_id] = sw

	# Reuse the panel already showing this monitor; otherwise take the first
	# free slot (or the last slot if everything is occupied).
	var slot := -1
	for i in range(screen_panels.size()):
		if is_instance_valid(screen_panels[i]) and \
				int(screen_panels[i].get_meta("monitor_id", -1)) == monitor_id:
			slot = i
			break
	if slot < 0:
		for i in range(MAX_SCREENS):
			if i >= screen_panels.size() or not is_instance_valid(screen_panels[i]):
				slot = i
				break
	if slot < 0:
		slot = MAX_SCREENS - 1

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

func _on_stream_stopped(monitor_id: int) -> void:
	if monitor_id < 0:
		return  # unknown monitor; nothing to remove

	_close_decoder(monitor_id)
	active_monitor_ids.erase(monitor_id)

	# Remove the panel showing this monitor
	for i in range(screen_panels.size()):
		var panel = screen_panels[i]
		if is_instance_valid(panel) and int(panel.get_meta("monitor_id", -1)) == monitor_id:
			panel.queue_free()
			screen_panels[i] = null

	# If nothing is streaming anymore, fall back to CONNECTED state
	var any_active := false
	for panel in screen_panels:
		if is_instance_valid(panel):
			any_active = true
			break
	if not any_active and current_state == State.STREAMING:
		current_state = State.CONNECTED
		_update_overlay_state()
	_update_overlay_monitors()

func _on_video_frame(monitor_id: int, frame_data: PackedByteArray, width: int, height: int) -> void:
	if _decoders.has(monitor_id):
		var dec: VideoDecoder = _decoders[monitor_id]
		# Fase 3: after a frame gap, skip non-IDR frames until clean intra arrives
		if _awaiting_idr.get(monitor_id, false):
			var is_kf := _is_keyframe(frame_data, dec._codec)
			# Always log the result when awaiting an IDR (sparse, not every P-frame)
			if is_kf or frame_data.size() > 50000:
				print("[Main] awaiting_idr mon=%d size=%d is_kf=%s codec=%d" % [
						monitor_id, frame_data.size(), str(is_kf), dec._codec])
			if not is_kf:
				return
			print("[Main] IDR accepted, submitting to decoder")
			_awaiting_idr.erase(monitor_id)
		dec.submit(frame_data)
		return

	# Software MJPEG path (PC / iOS / web): hand the JPEG to the threaded decoder;
	# the decoded image is polled and uploaded each frame in _update_decoders().
	if _sw_decoders.has(monitor_id):
		_sw_decoders[monitor_id].submit(frame_data)
		return

	# Last-resort synchronous path (frame arrived before a decoder was ready, or
	# a raw RGBA/NV12 frame): decode straight on the panel.
	var fallback: MeshInstance3D = null
	for panel in screen_panels:
		if not is_instance_valid(panel) or not panel.has_method("update_texture"):
			continue
		if int(panel.get_meta("monitor_id", -1)) == monitor_id:
			panel.update_texture(frame_data, width, height)
			return
		if fallback == null:
			fallback = panel
	if fallback:
		fallback.update_texture(frame_data, width, height)

## A frame was lost or dropped. For inter-frame codecs (H.264/HEVC/AV1) a missing
## P-frame corrupts the decode chain — typically as artefacts that linger until a
## clean intra arrives (e.g. a "ghost" cursor where the delta that erased the old
## position never arrived). We recover by asking the host for a fresh IDR.
func _on_frame_gap(monitor_id: int) -> void:
	if not _decoders.has(monitor_id):
		return
	# Cold start: still waiting for the first IDR. Flush stale decoder buffers so
	# they don't delay the clean intra we're about to accept; the host's periodic
	# IDR (~1 s) supplies one without us flooding REQUEST_KEYFRAME.
	if _awaiting_idr.get(monitor_id, false):
		_decoders[monitor_id].flush()
		return
	# Steady state: request an IDR, throttled so a burst of losses can't trigger
	# an IDR storm that congests Wi-Fi. We do NOT set _awaiting_idr (which would
	# drop every P-frame until the IDR lands and cause a visible freeze): the
	# decoder keeps showing concealed frames, then snaps to a clean picture when
	# the requested IDR — or the host's periodic one — arrives.
	_request_keyframe(monitor_id)

## Ask the host for a fresh keyframe (intra), throttled per monitor. Used to
## recover the inter-frame decode chain after packet loss without waiting for the
## host's periodic IDR (~1 s). The throttle bounds the extra IDR traffic so a
## burst of losses can't congest Wi-Fi. Returns true if a request was sent.
func _request_keyframe(monitor_id: int, min_interval_ms: int = 250) -> bool:
	if not _decoders.has(monitor_id):
		return false
	var now := Time.get_ticks_msec()
	var last: int = _last_keyframe_req_ms.get(monitor_id, -10000)
	if now - last < min_interval_ms:
		return false
	_last_keyframe_req_ms[monitor_id] = now
	if network_client and network_client.has_method("send_request_keyframe"):
		network_client.send_request_keyframe(monitor_id)
		return true
	return false

## On cold-start, track freshly-opened decoders so we know an IDR is needed.
## We send NO request on open; the host forces an IDR on the first frame of every
## stream and emits a periodic one (~1 s), so a fresh decoder gets its intra
## without us flooding REQUEST_KEYFRAME (which would trigger oversized forced IDRs
## that congest WiFi). Clear the pending flag once the IDR has been seen (or after
## a generous timeout).
func _handle_keyframe_retries() -> void:
	if _decoder_pending_first.is_empty():
		return
	var now := Time.get_ticks_msec()
	for mid in _decoder_pending_first.keys():
		# The decoder received its first IDR once _awaiting_idr is cleared.
		if not _awaiting_idr.has(mid):
			_decoder_pending_first.erase(mid)
			continue
		# Give up waiting after 10 s; the host's auto-GOP will supply an IDR.
		if now - int(_decoder_pending_first[mid]) > 10000:
			_decoder_pending_first.erase(mid)

## Test-harness frame capture: every 2 s, dump the latest decoded panel image
## (so a screenshot can be pulled over adb `run-as` and inspected without a
## headset). Saves to user:// = /data/data/<pkg>/files/. No-op unless enabled.
func _handle_debug_capture(delta: float) -> void:
	if not _debug_capture:
		return
	_debug_capture_accum += delta
	if _debug_capture_accum < 2.0:
		return
	_debug_capture_accum = 0.0
	_debug_capture_count += 1
	var saved := false
	for panel in screen_panels:
		if is_instance_valid(panel) and panel.has_method("save_debug_png"):
			if panel.save_debug_png("user://im2_panel_%d.png" % _debug_capture_count):
				saved = true
				break
	# Also try the full rendered viewport (colour, end-to-end). May be blank in
	# XR where rendering goes to the compositor; the panel image above is the
	# reliable decode check.
	# Viewport texture is not CPU-readable in XR/compositor mode; skip silently.
	if not xr_interface or not xr_interface.is_initialized():
		var vp := get_viewport()
		if vp:
			var tex := vp.get_texture()
			if tex:
				var img := tex.get_image()
				if img:
					img.save_png("user://im2_view_%d.png" % _debug_capture_count)
	print("[Immersive-2][TEST] debug capture #%d (panel=%s) state=%d decoders=%d" %
		[_debug_capture_count, str(saved), current_state, _decoders.size()])

func _close_decoder(monitor_id: int) -> void:
	if _decoders.has(monitor_id):
		_decoders[monitor_id].close()
		_decoders.erase(monitor_id)
	if _sw_decoders.has(monitor_id):
		_sw_decoders[monitor_id].close()
		_sw_decoders.erase(monitor_id)
	_awaiting_idr.erase(monitor_id)

func _close_all_decoders() -> void:
	for monitor_id in _decoders.keys():
		_decoders[monitor_id].close()
	_decoders.clear()
	for monitor_id in _sw_decoders.keys():
		_sw_decoders[monitor_id].close()
	_sw_decoders.clear()
	_awaiting_idr.clear()

## Each frame: drive both decoder kinds onto their panels.
##   - Hardware (ExternalTexture): wire the OES texture to the panel once, then
##     schedule the render-thread updateTexImage.
##   - Software (MJPEG): poll the threaded decoder for a freshly decoded image and
##     upload it to the panel.
func _update_decoders() -> void:
	for monitor_id in _decoders:
		var dec: VideoDecoder = _decoders[monitor_id]
		if not dec.is_open():
			continue
		if not dec.has_external_texture():
			continue
		var panel := _find_panel_for_monitor(monitor_id)
		if panel == null:
			continue
		if panel.has_method("is_using_external_texture") and not panel.is_using_external_texture():
			panel.set_external_texture(dec.get_external_texture(), dec.get_width(), dec.get_height())
		var mat := panel.material_override
		if mat is ShaderMaterial:
			dec.schedule_update(mat as ShaderMaterial)

	for monitor_id in _sw_decoders:
		var sw: SoftwareVideoDecoder = _sw_decoders[monitor_id]
		if not sw.is_open():
			continue
		var img := sw.get_decoded_image()
		if img == null:
			continue
		var panel := _find_panel_for_monitor(monitor_id)
		if panel and panel.has_method("update_decoded_image"):
			panel.update_decoded_image(img)

## Return the screen panel currently assigned to monitor_id, or null.
func _find_panel_for_monitor(monitor_id: int) -> MeshInstance3D:
	for panel in screen_panels:
		if is_instance_valid(panel) and int(panel.get_meta("monitor_id", -1)) == monitor_id:
			return panel
	return null

## Detect whether data begins with an IDR / intra NAL unit (Annex-B).
## Used for Fase 3 gap recovery to skip inter frames until a clean intra arrives.
func _is_keyframe(data: PackedByteArray, codec: int) -> bool:
	var size := data.size()
	if size < 5:
		return false
	var i := 0
	while i < size - 3:
		if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
			var nal_byte := data[i + 3]
			if codec == 0:  # H.264: NAL type 5 = IDR
				if (nal_byte & 0x1f) == 5:
					return true
			elif codec == 1:  # HEVC: NAL types 16-23 = IDR/BLA/CRA
				var nal_type := (nal_byte >> 1) & 0x3f
				if nal_type >= 16 and nal_type <= 23:
					return true
			i += 3
		else:
			i += 1
	return codec == 3  # AV1: assume keyframe (OBU detection complex)

## The host streams a codec we cannot decode here. Ask for the best codec we
## CAN decode: H.264 if the MediaCodec plugin is present (e.g. AV1 stream on
## a Pico 4 / Quest 2), MJPEG otherwise. Runtime only; the user's saved codec
## preference is not overwritten.
func _request_codec_fallback(codec: int) -> void:
	if _codec_fallback_sent:
		return
	_codec_fallback_sent = true
	var names := {0: "H.264", 1: "HEVC", 3: "AV1"}
	var fallback := 2  # MJPEG
	if codec != 0 and VideoDecoder.is_codec_supported(0):
		fallback = 0  # H.264
	push_warning("[Immersive-2] No decoder for %s on this device — requesting %s" %
		[names.get(codec, str(codec)), names.get(fallback, "MJPEG")])
	stream_codec = fallback
	_save_config()
	if network_client and network_client.has_method("send_stream_config"):
		network_client.send_stream_config(fallback, stream_bitrate_kbps,
			stream_jpeg_quality, stream_max_width, stream_fps)

func _on_audio_stream_started(_sample_rate: int, _channels: int, audio_port: int) -> void:
	if audio_receiver == null:
		audio_receiver = preload("res://scripts/audio_receiver.gd").new()
		audio_receiver.name = "AudioReceiver"
		add_child(audio_receiver)
	audio_receiver.start(host_ip, audio_port)

func _on_audio_stream_stopped() -> void:
	if audio_receiver:
		audio_receiver.stop()

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

func _on_overlay_environment_cycle() -> void:
	cycle_environment()
	_sync_environment_to_overlay()

func _on_overlay_environment_selected(index: int) -> void:
	if environment_manager:
		environment_manager.set_environment(index)
		_save_config()
		_sync_environment_to_overlay()

func _sync_environment_to_overlay() -> void:
	if not environment_manager or not ui_overlay:
		return
	if ui_overlay.has_method("set_environment_index"):
		ui_overlay.set_environment_index(environment_manager.get_current_index())
	if ui_overlay.has_method("set_environment_name"):
		ui_overlay.set_environment_name(environment_manager.get_current_name())

func _on_overlay_portal_add(shape: int) -> void:
	add_passthrough_portal(shape)

func _on_overlay_keyboard_portal() -> void:
	create_keyboard_portal()

func _on_overlay_whiteboard_toggle() -> void:
	toggle_whiteboard()

func _on_overlay_monitor_share_toggled(monitor_id: int, shared: bool) -> void:
	set_monitor_shared(monitor_id, shared)

func _on_overlay_room_join(url: String, room_id: String, display_name: String, public: bool = false) -> void:
	join_room(url, room_id, display_name, public)

func _on_overlay_lobby_list_requested() -> void:
	if multiuser:
		multiuser.request_lobby()

func _on_lobby_rooms_received(rooms: Array) -> void:
	if ui_overlay and ui_overlay.has_method("populate_lobby"):
		ui_overlay.populate_lobby(rooms)

func _on_overlay_room_leave() -> void:
	leave_room()
	if ui_overlay and ui_overlay.has_method("set_room_state"):
		ui_overlay.set_room_state(false)

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

## Called from vr_input.gd.
func send_mouse_input(monitor_id: int, x: int, y: int, buttons: int, scroll: int, scroll_h: int = 0) -> void:
	if current_state == State.STREAMING and network_client:
		network_client.send_mouse_input(monitor_id, x, y, buttons, scroll, scroll_h)

func send_keyboard_input(monitor_id: int, scancode: int, pressed: bool, modifiers: int) -> void:
	if current_state == State.STREAMING and network_client:
		network_client.send_keyboard_input(monitor_id, scancode, pressed, modifiers)

## Toggle overlay via controller button (called from vr_input.gd).
func toggle_ui_overlay() -> void:
	if ui_overlay and ui_overlay.has_method("toggle_visibility"):
		ui_overlay.toggle_visibility()

## Show/hide the in-VR QWERTY keyboard (called from vr_input.gd, A/X button).
func toggle_virtual_keyboard() -> void:
	if not is_instance_valid(virtual_keyboard) or not virtual_keyboard.has_method("toggle_visibility"):
		return
	virtual_keyboard.toggle_visibility()
	if virtual_keyboard.visible:
		virtual_keyboard.active_monitor_id = _keyboard_target_monitor()

func is_virtual_keyboard_visible() -> bool:
	return is_instance_valid(virtual_keyboard) and virtual_keyboard.visible

## Drive the in-VR keyboard with a world-space ray (controller or hand pointer).
## Returns { valid, distance }; valid=true means the ray is over a key, so the
## caller should not also act on a panel/overlay behind the keyboard.
func keyboard_ray_update(ray_origin: Vector3, ray_direction: Vector3, is_pressing: bool) -> Dictionary:
	if not is_virtual_keyboard_visible() or not virtual_keyboard.has_method("ray_update"):
		return {"valid": false}
	virtual_keyboard.active_monitor_id = _keyboard_target_monitor()
	return virtual_keyboard.ray_update(ray_origin, ray_direction, is_pressing)

## Monitor the keyboard types into: the first active stream, or 0 if none.
func _keyboard_target_monitor() -> int:
	if not active_monitor_ids.is_empty():
		return int(active_monitor_ids[0])
	return 0

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
			KEY_M:
				toggle_mic_mute()
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

	active_monitor_ids = selected_ids.duplicate()
	_send_monitor_selection()

	print("[Immersive-2] Restoring workspace monitors: %s" % [selected_ids])
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
	var interface := XRServer.get_primary_interface()
	if not interface or not interface.is_initialized():
		return false
	var supported_modes: Array = interface.get_supported_environment_blend_modes()
	return XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in supported_modes

func _apply_passthrough_settings() -> void:
	var viewport := get_viewport()
	var interface := XRServer.get_primary_interface()
	if not interface or not interface.is_initialized():
		viewport.transparent_bg = false
		return

	var passthrough_supported := _is_passthrough_supported()
	if passthrough_enabled and not passthrough_supported:
		passthrough_enabled = false
		print("[Immersive-2] Passthrough is not supported by this OpenXR runtime")

	var target_mode := XRInterface.XR_ENV_BLEND_MODE_OPAQUE
	if passthrough_enabled:
		target_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND

	if not interface.set_environment_blend_mode(target_mode):
		if passthrough_enabled:
			passthrough_enabled = false
			interface.set_environment_blend_mode(XRInterface.XR_ENV_BLEND_MODE_OPAQUE)
			print("[Immersive-2] Failed to enable passthrough, falling back to opaque mode")

	viewport.transparent_bg = passthrough_enabled

	# Swap the themed sky for a transparent background so the real world shows
	# through the portals / full passthrough (otherwise the sky occludes it).
	if environment_manager:
		environment_manager.set_passthrough(passthrough_enabled)

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
	cfg.set_value("stream", "codec", stream_codec)
	cfg.set_value("stream", "bitrate_kbps", stream_bitrate_kbps)
	cfg.set_value("stream", "jpeg_quality", stream_jpeg_quality)
	cfg.set_value("stream", "res_percent", stream_res_percent)
	cfg.set_value("stream", "fps", stream_fps)
	if environment_manager:
		cfg.set_value("display", "environment_index", environment_manager.get_current_index())
	cfg.save(CONFIG_PATH)

## Best codec this device can actually decode, preferring hardware.
## Like every production VR desktop streamer (Virtual Desktop, Steam Link,
## Moonlight), we use a hardware-decoded codec when one is available; software
## MJPEG is only a fallback for desktop/clients without the MediaCodec plugin,
## where a single CPU thread cannot keep up at full desktop resolution.
func _default_codec_for_device() -> int:
	if VideoDecoder.is_codec_supported(0):  # H.264: most robust, lowest setup latency
		return 0
	return 2  # MJPEG software fallback (no MediaCodec plugin)

## Resolve a requested codec to one this device can actually use: 0xFF ("auto")
## becomes the device's best codec (never "let the host decide", which falls
## back to slow software MJPEG), and a hardware codec without a decoder here
## degrades to software MJPEG.
func _resolve_codec(codec: int) -> int:
	if codec == 0xFF:
		return _default_codec_for_device()
	if codec in [0, 1, 3] and not VideoDecoder.is_codec_supported(codec):
		return 2
	return codec

func _load_config() -> void:
	# Capability-based default first; a saved config value overrides it below.
	stream_codec = _default_codec_for_device()

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
		stream_codec = _resolve_codec(cfg.get_value("stream", "codec", stream_codec))
		stream_bitrate_kbps = cfg.get_value("stream", "bitrate_kbps", 8000)
		stream_jpeg_quality = cfg.get_value("stream", "jpeg_quality", 70)
		stream_res_percent = cfg.get_value("stream", "res_percent", 100)
		stream_fps = cfg.get_value("stream", "fps", 0)
		_saved_environment_index = cfg.get_value("display", "environment_index", 0)
		# Test harness (see _autoconnect_on_start docs). Writable over adb run-as.
		_autoconnect_on_start = cfg.get_value("test", "autoconnect", false)
		_debug_capture = cfg.get_value("test", "debug_capture", false)

	_apply_cmdline_overrides()

## Allow driving the client from adb without a headset:
##   am start -n com.immersive2.vrclient/com.godot.game.GodotApp \
##       --esa command_line "--im2-host=192.168.1.34,--im2-capture"
## Recognised: --im2-host=IP, --im2-port=N, --im2-codec=N, --im2-capture.
func _apply_cmdline_overrides() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for arg in args:
		if arg.begins_with("--im2-host="):
			host_ip = arg.get_slice("=", 1)
			_autoconnect_on_start = true
		elif arg.begins_with("--im2-port="):
			host_tcp_port = int(arg.get_slice("=", 1))
		elif arg.begins_with("--im2-codec="):
			stream_codec = _resolve_codec(int(arg.get_slice("=", 1)))
		elif arg == "--im2-capture":
			_debug_capture = true

# ---------------------------------------------------------------------------
# Multi-user remote users
# ---------------------------------------------------------------------------

## Dictionary of remote users: user_id -> RemoteUser node
var remote_users: Dictionary = {}

## Local user ID from the signaling server
var _local_user_id: int = -1

# ---------------------------------------------------------------------------
# World features (mixed-reality portals, themed environments, locomotion,
# whiteboard) and multi-user session. All created null-safe so main.gd still
# instantiates headlessly (the test harness builds it without the full scene).
# ---------------------------------------------------------------------------

var portal_manager: PortalManager = null
var environment_manager: EnvironmentManager = null
var locomotion: Locomotion = null
var whiteboard: Whiteboard = null

var signaling_client: Node = null
var webrtc_manager: WebRTCManager = null
var multiuser: MultiuserManager = null
var voice_chat: VoiceChat = null
## Per-monitor opt-in screen sharing consent (nothing shared by default).
var privacy_manager: PrivacyManager = null

const POSE_BROADCAST_INTERVAL := 0.05  ## 20 Hz pose updates to the room
var _pose_broadcast_accum: float = 0.0
## Shared-screen layout refresh so remote panels follow the local panels as they
## are dragged/scaled. Slower than pose — the layout only changes when panels move.
const SCREEN_LAYOUT_INTERVAL := 0.5
var _screen_layout_accum: float = 0.0

func _init_world_features() -> void:
	portal_manager = PortalManager.new()
	portal_manager.name = "PortalManager"
	add_child(portal_manager)

	environment_manager = EnvironmentManager.new()
	environment_manager.name = "EnvironmentManager"
	add_child(environment_manager)
	var world_env := get_node_or_null("Environment") as WorldEnvironment
	if world_env:
		environment_manager.set_world_environment(world_env)

	locomotion = Locomotion.new()
	locomotion.name = "Locomotion"
	add_child(locomotion)
	if is_instance_valid(xr_origin) and is_instance_valid(xr_camera):
		locomotion.configure(xr_origin, xr_camera)

	# Apply saved environment index (loaded from config before _init_world_features runs).
	environment_manager.set_environment(_saved_environment_index)

	if ui_overlay:
		if ui_overlay.has_method("set_environment_list"):
			ui_overlay.set_environment_list(environment_manager.get_environment_names())
		if ui_overlay.has_method("set_environment_index"):
			ui_overlay.set_environment_index(environment_manager.get_current_index())
		elif ui_overlay.has_method("set_environment_name"):
			ui_overlay.set_environment_name(environment_manager.get_current_name())

func _init_multiuser() -> void:
	signaling_client = preload("res://scripts/signaling_client.gd").new()
	signaling_client.name = "SignalingClient"
	add_child(signaling_client)

	webrtc_manager = WebRTCManager.new()
	webrtc_manager.name = "WebRTCManager"
	add_child(webrtc_manager)

	multiuser = MultiuserManager.new()
	multiuser.name = "MultiuserManager"
	add_child(multiuser)
	multiuser.setup(signaling_client, webrtc_manager)
	multiuser.remote_pose.connect(apply_user_pose)
	multiuser.remote_presence.connect(on_user_presence)
	multiuser.user_left.connect(on_room_left)
	multiuser.room_state.connect(_on_room_state)
	multiuser.remote_whiteboard_stroke.connect(_on_remote_whiteboard_stroke)
	multiuser.remote_whiteboard_clear.connect(_on_remote_whiteboard_clear)
	multiuser.lobby_rooms_received.connect(_on_lobby_rooms_received)
	multiuser.remote_voice.connect(_on_remote_voice)
	multiuser.remote_screen_share.connect(_on_remote_screen_share)
	multiuser.remote_screen_layout.connect(_on_remote_screen_layout)

	# Voice chat: capture the headset mic and play remote users back spatially.
	voice_chat = VoiceChat.new()
	voice_chat.name = "VoiceChat"
	add_child(voice_chat)
	voice_chat.voice_frame_ready.connect(_on_local_voice_frame)
	voice_chat.mute_changed.connect(_on_voice_mute_changed)

	# Screen-share consent (opt-in per monitor, nothing shared by default).
	privacy_manager = PrivacyManager.new()
	privacy_manager.name = "PrivacyManager"
	add_child(privacy_manager)
	privacy_manager.monitor_share_changed.connect(_on_monitor_share_changed)
	privacy_manager.all_sharing_revoked.connect(_on_all_sharing_revoked)

## Join a shared VR room via the signaling server (called from the overlay).
## Pass public=true to make the room visible in the public lobby listing.
func join_room(url: String, room_id: String, display_name: String, public: bool = false) -> void:
	if multiuser:
		multiuser.join(url, room_id, display_name, public)
	# Start recording the mic so the room can hear us (mute toggle still applies).
	if voice_chat:
		voice_chat.start_capture()

## Leave the room and drop every remote avatar.
func leave_room() -> void:
	# Stop exposing any monitor before we tear down the room connection.
	if privacy_manager:
		privacy_manager.revoke_all_sharing()
	if multiuser:
		multiuser.leave()
	if voice_chat:
		voice_chat.stop_capture()
		voice_chat.clear_playbacks()
	for uid in remote_users.keys():
		if is_instance_valid(remote_users[uid]):
			remote_users[uid].queue_free()
	remote_users.clear()
	_local_user_id = -1
	_sync_share_ui()

func _on_room_state(room_id: String, user_id: int, mode: String) -> void:
	_local_user_id = user_id
	print("[Immersive-2] Joined room '%s' as user %d (%s mode)" % [room_id, user_id, mode])
	if ui_overlay and ui_overlay.has_method("set_room_state"):
		ui_overlay.set_room_state(true, "In '%s' · %s" % [room_id, mode])
	# Re-announce anything already shared (and refresh the share toggles' enabled
	# state now that we're in a room).
	_push_screen_share_state()
	_push_screen_layout()
	_sync_share_ui()

## Drive the WebRTC peer/ICE state machines each frame so the P2P mesh (pose +
## voice data channels) actually progresses to OPEN. Inert until a peer exists.
func _pump_multiuser() -> void:
	if webrtc_manager and webrtc_manager.has_method("poll"):
		webrtc_manager.poll()

## Send the local head + hands pose to the room, throttled to POSE_BROADCAST_INTERVAL.
func _broadcast_local_pose(delta: float) -> void:
	if multiuser == null or multiuser.get_local_user_id() < 0:
		return
	_pose_broadcast_accum += delta
	if _pose_broadcast_accum < POSE_BROADCAST_INTERVAL:
		return
	_pose_broadcast_accum = 0.0
	if not is_instance_valid(xr_camera):
		return
	var head := _node_pose_dict(xr_camera)
	var lh := _node_pose_dict(left_controller) if is_instance_valid(left_controller) else {}
	var rh := _node_pose_dict(right_controller) if is_instance_valid(right_controller) else {}
	multiuser.broadcast_pose(head, lh, rh)

## Serialise a node's world transform to the protocol pose dict (pos + quaternion).
func _node_pose_dict(node: Node3D) -> Dictionary:
	var t := node.global_transform
	var q := t.basis.get_rotation_quaternion()
	return {
		"pos_x": t.origin.x, "pos_y": t.origin.y, "pos_z": t.origin.z,
		"rot_w": q.w, "rot_x": q.x, "rot_y": q.y, "rot_z": q.z,
	}

# ---------------------------------------------------------------------------
# Voice chat
# ---------------------------------------------------------------------------

## A locally captured voice frame — route it to the room (P2P or SFU).
func _on_local_voice_frame(frame: PackedByteArray) -> void:
	if multiuser:
		multiuser.broadcast_voice(frame)

## A voice frame from a remote user — play it back on their avatar.
func _on_remote_voice(user_id: int, frame: PackedByteArray) -> void:
	if voice_chat:
		voice_chat.on_remote_voice(user_id, frame)

## Mute / unmute the local microphone (overlay button or M key).
func toggle_mic_mute() -> void:
	if voice_chat:
		voice_chat.toggle_mute()

func is_mic_muted() -> bool:
	return voice_chat == null or voice_chat.is_muted()

func _on_voice_mute_changed(muted: bool) -> void:
	if ui_overlay and ui_overlay.has_method("set_mic_muted"):
		ui_overlay.set_mic_muted(muted)

# ---------------------------------------------------------------------------
# Screen sharing (opt-in per monitor) — exposes the local panels to the room and
# renders the panels other users share around their avatars.
# ---------------------------------------------------------------------------

## Opt in / out of sharing a monitor with the room (driven by the overlay).
## Nothing is shared by default; revocation stops the remote panel within a frame.
func set_monitor_shared(monitor_id: int, shared: bool) -> void:
	if privacy_manager == null:
		return
	if shared:
		privacy_manager.share_monitor(monitor_id)
	else:
		privacy_manager.unshare_monitor(monitor_id)

func is_monitor_shared(monitor_id: int) -> bool:
	return privacy_manager != null and privacy_manager.is_monitor_shared(monitor_id)

func get_shared_monitor_ids() -> Array:
	return privacy_manager.get_shared_monitors() if privacy_manager else []

## A monitor's share state changed: tell the room (state + layout) and refresh UI.
func _on_monitor_share_changed(_monitor_id: int, _is_shared: bool) -> void:
	_push_screen_share_state()
	_push_screen_layout()
	_sync_share_ui()

## All sharing revoked (emergency stop / room leave): tell the room and refresh UI.
func _on_all_sharing_revoked() -> void:
	_push_screen_share_state()
	_push_screen_layout()
	_sync_share_ui()

## Announce which monitors we currently expose (or that sharing is off).
func _push_screen_share_state() -> void:
	if multiuser == null or multiuser.get_local_user_id() < 0:
		return
	var ids: Array = get_shared_monitor_ids()
	multiuser.broadcast_screen_share(ids.size(), ids, not ids.is_empty())

## Send the world pose + size + resolution of each shared panel to the room.
func _push_screen_layout() -> void:
	if multiuser == null or multiuser.get_local_user_id() < 0:
		return
	multiuser.broadcast_screen_layout(_build_shared_layout())

## Build the layout entries for the currently shared monitors from their live
## panels. Coordinates are world-space (the room shares one origin), so a remote
## client places each panel exactly where the sharer positioned it.
func _build_shared_layout() -> Array:
	var entries: Array = []
	for mid in get_shared_monitor_ids():
		var panel := _find_panel_for_monitor(mid)
		if panel == null:
			continue
		var t := panel.global_transform
		var q := t.basis.get_rotation_quaternion()
		entries.append({
			"monitor_id": mid,
			"pos_x": t.origin.x, "pos_y": t.origin.y, "pos_z": t.origin.z,
			"rot_w": q.w, "rot_x": q.x, "rot_y": q.y, "rot_z": q.z,
			"width": panel.panel_width, "height": panel.panel_height,
			"resolution_w": panel.screen_width, "resolution_h": panel.screen_height,
		})
	return entries

## Periodic layout refresh so remote panels track the local panels as they move.
func _broadcast_screen_layout(delta: float) -> void:
	if privacy_manager == null or not privacy_manager.is_any_shared():
		return
	if multiuser == null or multiuser.get_local_user_id() < 0:
		return
	_screen_layout_accum += delta
	if _screen_layout_accum < SCREEN_LAYOUT_INTERVAL:
		return
	_screen_layout_accum = 0.0
	_push_screen_layout()

## Mirror the local share state into the overlay (active share toggles).
func _sync_share_ui() -> void:
	if ui_overlay and ui_overlay.has_method("set_shared_monitors"):
		ui_overlay.set_shared_monitors(get_shared_monitor_ids())

## A remote user toggled sharing: drop their panels when they stop sharing (the
## layout message that follows recreates them when they start again).
func _on_remote_screen_share(user_id: int, _count: int, _ids: Array, enabled: bool) -> void:
	if not enabled and remote_users.has(user_id):
		remote_users[user_id].apply_screen_layout([])

## A remote user's shared-screen layout arrived: place their panels on their avatar.
func _on_remote_screen_layout(user_id: int, monitors: Array) -> void:
	apply_screen_layout(user_id, monitors)

# ---------------------------------------------------------------------------
# World-feature actions (driven by the overlay / controller input)
# ---------------------------------------------------------------------------

## Cycle to the next themed environment.
func cycle_environment() -> int:
	if environment_manager:
		return environment_manager.next_environment()
	return 0

## Add a passthrough portal ~1 m in front of the user. Returns the portal or null.
func add_passthrough_portal(shape: int = Im2Portal.Shape.RECTANGLE) -> Im2Portal:
	if portal_manager == null:
		return null
	return portal_manager.add_portal(shape, Vector2.ZERO, _front_of_camera(1.0))

## Remove every passthrough portal (overlay "Clear portals").
func clear_portals() -> void:
	if portal_manager:
		portal_manager.clear_portals()

## Create the dedicated keyboard portal (anchored low, where the keyboard sits).
func create_keyboard_portal() -> Im2Portal:
	if portal_manager == null:
		return null
	return portal_manager.create_keyboard_portal(_front_of_camera(0.55, -0.45))

## Show / hide the shared whiteboard (created on first use, in front of the user).
func toggle_whiteboard() -> void:
	var was_visible := is_instance_valid(whiteboard) and whiteboard.visible
	_ensure_whiteboard()
	whiteboard.visible = not was_visible

## Create the whiteboard (hidden) on first use; returns it.
func _ensure_whiteboard() -> Whiteboard:
	if not is_instance_valid(whiteboard):
		whiteboard = Whiteboard.new()
		whiteboard.name = "Whiteboard"
		add_child(whiteboard)
		whiteboard.transform = _front_of_camera(1.6)
	return whiteboard

func is_whiteboard_active() -> bool:
	return is_instance_valid(whiteboard) and whiteboard.visible

## Clear the shared whiteboard (locally + for the room).
func clear_whiteboard() -> void:
	if is_instance_valid(whiteboard):
		whiteboard.clear_board()
	if multiuser and multiuser.get_local_user_id() >= 0:
		multiuser.broadcast_whiteboard_clear()

## Save a high-resolution PNG snapshot of the whiteboard to user://. Returns the
## saved path, or "" if there is no board to capture.
func save_whiteboard_snapshot() -> String:
	if not is_instance_valid(whiteboard):
		return ""
	var path := "user://whiteboard_%d.png" % Time.get_unix_time_from_system()
	if whiteboard.save_snapshot(path):
		print("[Immersive-2] Whiteboard snapshot saved: %s" % path)
		if ui_overlay and ui_overlay.has_method("set_whiteboard_status"):
			ui_overlay.set_whiteboard_status("Saved %s" % path.get_file())
		return path
	return ""

# Local whiteboard drawing state.
var _wb_drawing: bool = false

## Draw on the whiteboard with a world-space ray while `is_drawing` (trigger /
## pinch). Returns { valid } — valid=true means the ray is on the board (consumed,
## so the caller should not also click a panel behind it). Finished strokes are
## broadcast to the room.
func draw_on_whiteboard(ray_origin: Vector3, ray_direction: Vector3, is_drawing: bool) -> Dictionary:
	if not is_whiteboard_active():
		return {"valid": false}
	var hit: Dictionary = whiteboard.ray_to_uv(ray_origin, ray_direction)
	if not hit.get("valid", false):
		if _wb_drawing:
			_wb_finish_stroke()
		return {"valid": false}
	var uid := _wb_local_id()
	if is_drawing:
		if not _wb_drawing:
			whiteboard.begin_stroke(uid, hit["uv"])
			_wb_drawing = true
		else:
			whiteboard.append_point(uid, hit["uv"])
	elif _wb_drawing:
		_wb_finish_stroke()
	return {"valid": true, "distance": hit.get("distance", 0.0)}

func _wb_local_id() -> int:
	return _local_user_id if _local_user_id >= 0 else 0

func _wb_finish_stroke() -> void:
	if not is_instance_valid(whiteboard):
		_wb_drawing = false
		return
	whiteboard.end_stroke(_wb_local_id())
	_wb_drawing = false
	if multiuser and multiuser.get_local_user_id() >= 0:
		multiuser.broadcast_whiteboard_stroke(whiteboard.last_stroke_serialized())

func _on_remote_whiteboard_stroke(_user_id: int, stroke: Dictionary) -> void:
	_ensure_whiteboard().visible = true
	whiteboard.apply_remote_stroke(Whiteboard.stroke_from_dict(stroke))

func _on_remote_whiteboard_clear(_user_id: int) -> void:
	if is_instance_valid(whiteboard):
		whiteboard.clear_board()

## Comfortable snap-turn (called from controller input).
func snap_turn(degrees: float) -> void:
	if locomotion:
		locomotion.snap_turn(degrees)

## Teleport to a world-space floor point (called from controller input).
func teleport_to(point: Vector3) -> void:
	if locomotion:
		locomotion.teleport_to(point)

# Locomotion input state (left controller thumbstick: X = snap-turn, forward =
# aim teleport, release = go). All reads are guarded so this is inert in tests.
var _turn_latched: bool = false
var _teleport_aiming: bool = false
var _teleport_marker: MeshInstance3D = null

func _handle_locomotion() -> void:
	if locomotion == null or not is_instance_valid(left_controller):
		return
	var stick: Vector2 = left_controller.get_vector2("primary")

	# Snap-turn on a horizontal flick (latched so one flick = one turn).
	if absf(stick.x) > 0.7:
		if not _turn_latched:
			snap_turn(Locomotion.SNAP_TURN_DEGREES * signf(stick.x))
			_turn_latched = true
	elif absf(stick.x) < 0.3:
		_turn_latched = false

	# Teleport: hold the stick forward to aim, release to commit.
	if stick.y < -0.7:
		_teleport_aiming = true
		_update_teleport_marker()
	elif _teleport_aiming and stick.y > -0.3:
		_teleport_aiming = false
		_commit_teleport()

## World-space floor point the left controller is currently aiming at, or null dict.
func _teleport_aim() -> Dictionary:
	if not is_instance_valid(left_controller) or locomotion == null:
		return {"valid": false}
	var t := left_controller.global_transform
	return locomotion.aim_floor(t.origin, -t.basis.z)

func _update_teleport_marker() -> void:
	var aim := _teleport_aim()
	if not aim.get("valid", false):
		_hide_teleport_marker()
		return
	if not is_instance_valid(_teleport_marker):
		_teleport_marker = MeshInstance3D.new()
		var disc := CylinderMesh.new()
		disc.top_radius = 0.25
		disc.bottom_radius = 0.25
		disc.height = 0.02
		_teleport_marker.mesh = disc
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.3, 0.85, 1.0, 0.7)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_teleport_marker.material_override = mat
		add_child(_teleport_marker)
	_teleport_marker.visible = true
	_teleport_marker.global_position = aim["point"]

func _hide_teleport_marker() -> void:
	if is_instance_valid(_teleport_marker):
		_teleport_marker.visible = false

func _commit_teleport() -> void:
	var aim := _teleport_aim()
	if aim.get("valid", false):
		teleport_to(aim["point"])
	_hide_teleport_marker()

## A transform `dist` metres in front of the camera (facing the user), with an
## optional vertical offset. Falls back to a fixed pose when no camera (headless).
func _front_of_camera(dist: float, y_offset: float = 0.0) -> Transform3D:
	if not is_instance_valid(xr_camera):
		return Transform3D(Basis(), Vector3(0.0, 1.5 + y_offset, -dist))
	var cam := xr_camera.global_transform
	var fwd := -cam.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3(0.0, 0.0, -1.0)
	var pos := cam.origin + fwd * dist + Vector3(0.0, y_offset, 0.0)
	# Face the user: the panel's front (-Z) should point back toward the camera.
	var basis := Basis.looking_at(-fwd, Vector3.UP)
	return Transform3D(basis, pos)

## Called when we successfully join a room.
func on_room_joined(room_id: String, user_id: int, participants: Array) -> void:
	_local_user_id = user_id
	for p in participants:
		var pid: int = p.get("user_id", 0)
		if pid != _local_user_id:
			on_user_presence(pid, p.get("display_name", ""), true)

## Called when a user presence update arrives. The signaling server only relays
## presence for *other* users (it excludes the sender), so every update is remote.
func on_user_presence(user_id: int, display_name: String, is_online: bool) -> void:
	if is_online:
		if not remote_users.has(user_id):
			var user = preload("res://scripts/remote_user.gd").new()
			user.name = "RemoteUser_%d" % user_id
			user.user_id = user_id
			user.display_name = display_name
			add_child(user)
			remote_users[user_id] = user
			# Anchor this user's voice to their avatar head for spatial audio.
			if voice_chat and user.has_method("get_head_node"):
				voice_chat.attach_playback(user_id, user.get_head_node())
	else:
		if remote_users.has(user_id):
			remote_users[user_id].queue_free()
			remote_users.erase(user_id)
		if voice_chat:
			voice_chat.remove_playback(user_id)

## Called when a user leaves the room.
func on_room_left(user_id: int) -> void:
	if remote_users.has(user_id):
		remote_users[user_id].queue_free()
		remote_users.erase(user_id)
	if voice_chat:
		voice_chat.remove_playback(user_id)

## Apply pose update to a remote user.
func apply_user_pose(user_id: int, head: Dictionary, left_hand: Dictionary, right_hand: Dictionary) -> void:
	if remote_users.has(user_id):
		remote_users[user_id].update_pose(head, left_hand, right_hand)

## Apply screen layout to a remote user.
func apply_screen_layout(user_id: int, monitors: Array) -> void:
	if remote_users.has(user_id):
		remote_users[user_id].apply_screen_layout(monitors)

## Set the local user ID (for testing).
func set_local_user_id(user_id: int) -> void:
	_local_user_id = user_id
