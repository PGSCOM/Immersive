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
const CONFIG_PATH := "user://immersive2_config.cfg"

# ---------------------------------------------------------------------------
# Scene references
# ---------------------------------------------------------------------------

@onready var xr_origin: XROrigin3D    = $XROrigin3D
@onready var xr_camera: XRCamera3D   = $XROrigin3D/XRCamera3D

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

enum State { DISCONNECTED, CONNECTING, CONNECTED, STREAMING }
var current_state: State = State.DISCONNECTED

var host_ip: String    = "192.168.1.100"
var host_tcp_port: int = 19800
var host_udp_port: int = 19801

var available_monitors: Array = []

## Active screen panels (up to MAX_SCREENS).
var screen_panels: Array = []

## Network client (lazy-created).
var network_client: Node = null

## UI overlay (lazy-created).
var ui_overlay: Node = null

## XR interface.
var xr_interface: XRInterface = null

# Reconnect timer
var _reconnect_timer: float = 0.0
var _should_reconnect: bool = false

# Latency tracking
var _latency_timer: float = 0.0
var _probe_id: int = 0
var _probe_sent_us: int = 0
var _latency_ms: float = 0.0

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_load_config()
	_init_xr()
	_init_network()
	_init_ui_overlay()
	print("[Immersive-2] VR Client started — press B/Y to open overlay")

func _process(delta: float) -> void:
	_handle_reconnect(delta)
	_handle_latency_probe(delta)

# ---------------------------------------------------------------------------
# XR initialisation
# ---------------------------------------------------------------------------

func _init_xr() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		print("[Immersive-2] OpenXR initialized")
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		get_viewport().use_xr = true
	else:
		print("[Immersive-2] OpenXR not available, running in desktop mode")

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

	return screen_panels[slot]

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

	# Auto-select the first monitor for MVP
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
		panel.set_meta("monitor_id", monitor_id)

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

# ---------------------------------------------------------------------------
# Config persistence
# ---------------------------------------------------------------------------

func _save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("network", "host_ip", host_ip)
	cfg.set_value("network", "tcp_port", host_tcp_port)
	cfg.set_value("network", "udp_port", host_udp_port)
	cfg.save(CONFIG_PATH)

func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		host_ip       = cfg.get_value("network", "host_ip", "192.168.1.100")
		host_tcp_port = cfg.get_value("network", "tcp_port", 19800)
		host_udp_port = cfg.get_value("network", "udp_port", 19801)
