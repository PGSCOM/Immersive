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

# Stream quality settings (sent to the host via STREAM_CONFIG).
var stream_codec: int = 0xFF        ## 0xFF = host default, 0 = H.264, 2 = MJPEG
var stream_bitrate_kbps: int = 20000
var stream_jpeg_quality: int = 35
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

## Whether we already auto-fell back to MJPEG this session (avoids loops).
var _codec_fallback_sent: bool = false

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

func _ready() -> void:
	_load_config()
	_load_workspace_layout()
	_init_eye_gaze_controller()
	_init_network()
	_init_ui_overlay()
	if current_state == State.DISCONNECTED and ui_overlay and ui_overlay.has_method("toggle_visibility"):
		ui_overlay.toggle_visibility()
	print("[Immersive-2] VR Client started — press B/Y to open overlay")

func _process(delta: float) -> void:
	_handle_reconnect(delta)
	_handle_latency_probe(delta)
	_update_foveation_focus()

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
	if stream_codec == 2 or stream_codec == 0xFF:  # MJPEG (explicit or host default)
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
	stream_codec = codec
	stream_bitrate_kbps = clamp(bitrate_kbps, 1000, 100000)
	stream_jpeg_quality = clamp(jpeg_quality, 10, 95)
	stream_res_percent = res_percent
	stream_fps = clamp(fps, 0, 120)
	_recompute_stream_max_width()
	_save_config()
	_send_stream_config()

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

	if ui_overlay and ui_overlay.has_method("set_monitor_list"):
		ui_overlay.set_monitor_list(monitors)

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

	# Set up (or tear down) the hardware decoder for this monitor's codec
	_close_decoder(monitor_id)
	if codec in [0, 1, 3]:  # H.264 / HEVC / AV1
		var dec := VideoDecoder.new()
		if dec.open(codec, width, height):
			_decoders[monitor_id] = dec
		else:
			_request_codec_fallback(codec)

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
	# H.264/HEVC/AV1: run through the hardware decoder first (output is NV12)
	if _decoders.has(monitor_id):
		var dec: VideoDecoder = _decoders[monitor_id]
		dec.submit(frame_data)
		frame_data = dec.poll_frame()
		if frame_data.is_empty():
			return  # decoder hasn't produced a frame yet
		width = dec.get_width()
		height = dec.get_height()

	# Deliver frame to the panel showing this monitor
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

func _close_decoder(monitor_id: int) -> void:
	if _decoders.has(monitor_id):
		_decoders[monitor_id].close()
		_decoders.erase(monitor_id)

func _close_all_decoders() -> void:
	for monitor_id in _decoders.keys():
		_decoders[monitor_id].close()
	_decoders.clear()

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
		stream_codec = cfg.get_value("stream", "codec", 0xFF)
		stream_bitrate_kbps = cfg.get_value("stream", "bitrate_kbps", 20000)
		stream_jpeg_quality = cfg.get_value("stream", "jpeg_quality", 35)
		stream_res_percent = cfg.get_value("stream", "res_percent", 100)
		stream_fps = cfg.get_value("stream", "fps", 0)
