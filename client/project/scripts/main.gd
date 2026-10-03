## Main scene controller.
## Initializes XR, finds and connects to the PC, and coordinates streaming
## between the network client, the decoders and the screen panels.
##
## Up to 3 monitors as curved or flat screens arranged around the user; the
## arrangement, the chosen monitors and every setting persist on their own.

extends Node3D

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const MAX_SCREENS := 3
const RECONNECT_DELAY := 5.0    ## Seconds between reconnect attempts
const LATENCY_INTERVAL := 2.0   ## Seconds between latency probes
const CONFIG_PATH := "user://immersive2_config.cfg"
const WORKSPACE_PATH := "user://immersive2_workspace.json"
## Screens sit on an arc this far from the eyes, a little below eye level.
const ARC_RADIUS := 1.25
const ARC_GAP_M := 0.06
const EYE_DROP_M := 0.08
## Snapping: a dragged screen whose centre comes within SNAP_CAPTURE_M of
## where it would sit flush beside another screen (and is turned within
## SNAP_TURN_DEG of it) shows a white frame there and lands in it on release.
const SNAP_GAP_M := 0.03        ## Space left between snapped screens
const SNAP_CAPTURE_M := 0.45
const SNAP_TURN_DEG := 60.0
const SNAP_STICKY_M := 0.08     ## The side already shown keeps this much advantage
## A restored layout further than this off the gaze is swung back in front.
const RESTORE_MAX_YAW_DEG := 60.0
const CODEC_NAMES := {0: "H.264", 1: "HEVC", 2: "MJPEG", 3: "AV1"}

# ---------------------------------------------------------------------------
# Scene references
# ---------------------------------------------------------------------------

@onready var xr_origin: XROrigin3D    = $XROrigin3D
@onready var xr_camera: XRCamera3D   = $XROrigin3D/XRCamera3D
@onready var left_controller: XRController3D = $XROrigin3D/LeftController
@onready var right_controller: XRController3D = $XROrigin3D/RightController
@onready var virtual_keyboard: Node3D = get_node_or_null("VirtualKeyboard")
var whiteboard: Whiteboard = null

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

enum State { DISCONNECTED, CONNECTING, CONNECTED, STREAMING }
var current_state: State = State.DISCONNECTED

var host_ip: String    = ""
var host_tcp_port: int = 19800
var host_udp_port: int = 19801
var curved_screen_enabled: bool = true
var curved_screen_amount: float = 0.5
var passthrough_enabled: bool = false
var look: String = "night"
## Draw the screens as OpenXR compositor layers (sharper text) when the
## runtime supports them.
var compositor_layers: bool = false
## The pointer and keyboards drive the PC. Off = look only.
var control_enabled: bool = true
## Controllers tick on clicks and grabs (read by vr_input.gd).
var haptics_enabled: bool = true
## Layout: release next to a screen to snap beside it; lock = screens cannot be moved.
var snap_enabled: bool = true
var lock_layout: bool = false
## The bare hand that points, "left" or "right" (read by hand_input.gd); the
## other one opens the menu (palm to the face, pinch).
var pointer_hand: String = "right"
## Controller ray tilt below the aim pose, degrees (read live by vr_input.gd).
var ray_angle_deg: float = 40.0
## Grabbed screens turn to face the head (LaserDrag.face_me); off = they follow
## the controller's position and rotation rigidly.
var screens_face_me: bool = false
## Pixels of the last virtual screen added or changed: the size page starts there.
var virtual_size := Vector2i(1920, 1080)

# Stream quality settings (sent to the host via STREAM_CONFIG).
## Protocol codec value: 0 = H.264, 1 = HEVC, 2 = MJPEG, 3 = AV1.
## Resolved from the device's decode capability in _load_config(); see
## _default_codec_for_device(). We never send 0xFF ("let the host decide")
## from a headset — the host would pick software MJPEG, which a mobile CPU
## cannot sustain at desktop resolution.
var stream_codec: int = 0
var stream_bitrate_kbps: int = 20000
var stream_jpeg_quality: int = 70
var stream_res_percent: int = 100   ## 100/75/50, -1 = auto (ideal)
var stream_max_width: int = 0       ## computed target width; 0 = native
var stream_fps: int = 0             ## 0 = auto

var available_monitors: Array = []

## Monitors currently selected for streaming (up to MAX_SCREENS).
var active_monitor_ids: Array = []

## Active screen panels.
var screen_panels: Array = []

## Network client, LAN discovery, audio (created on demand), world, menu.
var network_client: Node = null
var discovery: HostDiscovery = null
var audio_receiver: Node = null
var world: Node3D = null
var ui_overlay: Node = null

## Hardware video decoders per monitor (H.264/HEVC/AV1 via MediaCodec).
var _decoders: Dictionary = {}

## Software (CPU) MJPEG decoders per monitor, used on platforms with no hardware
## MediaCodec plugin: PC (Windows/Linux/macOS), iOS and web. Threaded JPEG decode.
var _sw_decoders: Dictionary = {}

## Codec and size each monitor streams at, for the connection details.
var _stream_info: Dictionary = {}

## Last keyframe-request time per monitor (ms), to throttle loss recovery.
var _last_keyframe_req_ms: Dictionary = {}

## Whether we already auto-fell back to another codec this session (avoids loops).
var _codec_fallback_sent: bool = false

## Monitors awaiting an IDR keyframe before their decoder may take frames.
var _awaiting_idr: Dictionary = {}

## Last [monitor_id, x, y, buttons] actually sent, so an unchanged pointer does
## not re-send the same event every frame. See send_mouse_input().
var _last_mouse_state: Array = []
## Monitor the pointer was last on: the keyboard types into it.
var _last_pointed_monitor: int = -1

## Force video/audio over TCP whatever the address (--im2-usb). Normally
## implied by _use_tcp_media(); this lets desktop tests exercise USB mode.
var _force_tcp_media: bool = false

## Automatic USB: whenever the PC answers through the cable (UsbProbe) the
## connection moves there, and back to Wi-Fi when the cable goes.
var _usb_probe: UsbProbe = null
## The PC's network address, to fall back to when the cable is pulled.
var _lan_ip: String = ""
## --im2-usb-port=N: the "cable" is 127.0.0.1:N (tests: a stand-in for adb
## reverse, and automatic USB on desktop). 0 = host_tcp_port.
var _usb_port: int = 0
## The user pressed Disconnect: don't jump back in over the cable.
var _usb_paused: bool = false
## Launch: hear from the cable before auto-connecting over Wi-Fi.
var _connect_after_probe: bool = false

## Pairing PINs by host ("ip:<addr>" and "name:<pc name>").
var _pins: Dictionary = {}
## Name of the PC we are talking to (from HELLO_ACK or discovery).
var _host_name: String = ""
## Reconnect to the last PC on launch (on after a successful connection,
## off after the user disconnects).
var _auto_connect: bool = false
var _last_host_name: String = ""
var _audio_on: bool = false
## HOST_FLAG_* of the connected PC (view-only, can make virtual screens).
var _host_flags: int = 0
## The PC's main screen is dark (the menu's switch). Never saved: every
## connection starts with it lit, and the host lights it again by itself when
## this stops being re-sent (_handle_latency_probe), so it is never dark
## without the headset.
var _screen_off: bool = false
## A virtual screen we asked for, to show as soon as the host lists it.
var _pending_virtual_id: int = -1
## A 1:1 resize in flight: old id, size, old layout, whether it is creating.
var _match: Dictionary = {}

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
## --im2-monitors: overrides the saved workspace's monitors.
var _cmdline_monitors: Array = []
## --im2-virtual=WxH: ask for a virtual screen of that size once connected.
var _cmdline_virtual := Vector2i.ZERO
## Driven from the command line (tests, adb): settings and layout stay as
## the user left them.
var _ephemeral: bool = false

## XR interface (managed by XRStarter).
var xr_interface: XRInterface = null
# Reconnect timer
var _reconnect_timer: float = 0.0
var _should_reconnect: bool = false

# Latency tracking
var _latency_timer: float = 0.0
var _probe_id: int = 0
var _probe_sent_us: int = 0
var _latency_ms: float = 0.0
var _stats_timer: float = 0.0

# Workspace persistence: layout per monitor id (int) -> screen_panel state.
var _layouts: Dictionary = {}
var _workspace_monitor_ids: Array = []
## Layouts loaded from disk have not been checked against the head yet.
var _layouts_from_disk: bool = false
## Monitor ids of the screens that move together (saved with the workspace).
var _linked: Dictionary = {}
## Screens dropped in the white frame beside another follow it: monitor id ->
## the monitor id it was snapped to (saved with the workspace). Pulled out and
## dropped anywhere else, a screen is free again.
var _snapped_to: Dictionary = {}
var _save_timer: Timer

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_load_config()
	_load_workspace()
	_init_world()
	_init_hand_input()
	_init_network()
	_init_ui_overlay()
	whiteboard = Whiteboard.new()
	whiteboard.name = "Whiteboard"
	add_child(whiteboard)
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.timeout.connect(save_workspace_layout)
	add_child(_save_timer)
	# XR initialises in XRStarter._ready(); defer one frame so it is up.
	_apply_passthrough_settings.call_deferred()
	_connect_xr_signals.call_deferred()

	if _autoconnect_on_start:
		print("[Immersive-2][TEST] Autoconnect enabled -> %s:%d (capture=%s)" %
			[host_ip, host_tcp_port, str(_debug_capture)])
		connect_to_host()
	elif _auto_connect and host_ip.is_valid_ip_address():
		# Straight back to the PC used last time (over the cable if one is
		# plugged in: _on_usb_checked); the menu opens only if that does not
		# work out within a few seconds.
		if _usb_auto():
			_connect_after_probe = true
		else:
			connect_to_host()
		get_tree().create_timer(6.0).timeout.connect(func():
			if current_state == State.CONNECTING or current_state == State.DISCONNECTED:
				_show_overlay())
	else:
		# Give head tracking a moment, so the menu opens where the user looks.
		get_tree().create_timer(0.5).timeout.connect(_show_overlay)
	_update_discovery()
	print("[Immersive-2] VR Client started — press B/Y to open the menu")

func _process(delta: float) -> void:
	_handle_reconnect(delta)
	_update_usb_probe()
	_handle_latency_probe(delta)
	_handle_stats(delta)
	_handle_debug_capture(delta)
	_update_decoders()
	_update_snap_preview()
	_sort_layers()

## Compositor layers ignore depth: farther screens get a lower sort_order so a
## nearer one is drawn over them where they overlap.
func _sort_layers() -> void:
	if not compositor_layers or not xr_camera:
		return
	var eye := xr_camera.global_position
	var panels := _live_panels().filter(func(p): return p.has_compositor_layer())
	panels.sort_custom(func(a, b): return eye.distance_squared_to(a.global_position) \
		< eye.distance_squared_to(b.global_position))
	for i in panels.size():
		panels[i].set_layer_order(-1 - i)

# ---------------------------------------------------------------------------
# XR helpers
# ---------------------------------------------------------------------------

func _init_world() -> void:
	world = preload("res://scripts/world.gd").new()
	world.name = "World"
	add_child(world)
	world.set_look(look)

## Bare-hand (controller-free) pointer + pinch input. Inert while a controller
## is in use (vr_input.gd) or no hand is tracked.
## See scripts/hand_input.gd for the gesture mapping (Pico 4 / Quest / SteamVR).
func _init_hand_input() -> void:
	var hand_input := preload("res://scripts/hand_input.gd").new()
	hand_input.name = "HandInput"
	add_child(hand_input)

## The system "recenter" (long press of the Meta / Pico button) moves the
## tracking origin: bring the screens back in front, like the rest of the OS.
func _connect_xr_signals() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.has_signal("pose_recentered"):
		xr_interface.pose_recentered.connect(func():
			if world:
				world.refit_floor()
			recenter_workspace())

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

func _init_network() -> void:
	network_client = preload("res://scripts/network_client.gd").new()
	network_client.name = "NetworkClient"
	add_child(network_client)

	network_client.connected_to_host.connect(_on_connected)
	network_client.disconnected_from_host.connect(_on_disconnected)
	network_client.handshake_accepted.connect(_on_handshake_accepted)
	network_client.virtual_display_result.connect(_on_virtual_display_result)
	network_client.screen_off_changed.connect(_show_screen_off)
	network_client.connection_rejected.connect(_on_connection_rejected)
	network_client.monitor_list_received.connect(_on_monitor_list)
	network_client.stream_started.connect(_on_stream_started)
	network_client.stream_stopped.connect(_on_stream_stopped)
	network_client.video_frame_received.connect(_on_video_frame)
	network_client.latency_response_received.connect(_on_latency_response)
	network_client.audio_stream_started.connect(_on_audio_stream_started)
	network_client.audio_stream_stopped.connect(_on_audio_stream_stopped)
	network_client.frame_gap_detected.connect(_on_frame_gap)
	network_client.audio_packet_received.connect(func(pkt: PackedByteArray):
		if audio_receiver:
			audio_receiver.parse_packet(pkt))

	discovery = HostDiscovery.new()
	discovery.name = "HostDiscovery"
	discovery.port = host_tcp_port
	add_child(discovery)
	discovery.hosts_changed.connect(_on_hosts_changed)

	_usb_probe = UsbProbe.new()
	_usb_probe.name = "UsbProbe"
	add_child(_usb_probe)
	_usb_probe.checked.connect(_on_usb_checked)

## Look for PCs only while not connected: it is what the menu shows then, and
## it lets a reconnect follow a PC whose address changed.
func _update_discovery() -> void:
	if not discovery:
		return
	if current_state == State.CONNECTED or current_state == State.STREAMING:
		discovery.stop()
	else:
		discovery.start()

func _on_hosts_changed(hosts: Array) -> void:
	if ui_overlay:
		ui_overlay.set_discovered_hosts(hosts)
	for h in hosts:
		if h.name == _last_host_name and not h.ip.begins_with("127."):
			_lan_ip = h.ip
	# The PC we reconnect to got a new address (DHCP): follow it.
	if _should_reconnect and not _last_host_name.is_empty() and current_state == State.DISCONNECTED:
		for h in hosts:
			if h.name == _last_host_name and h.ip != host_ip and not h.ip.begins_with("127."):
				print("[Immersive-2] %s moved to %s" % [h.name, h.ip])
				host_ip = h.ip
				host_tcp_port = h.port
				_save_config()

## USB mode: on the headset, a loopback host address can only be the PC
## reached through `adb reverse` (the host re-arms it every few seconds), and
## that tunnel carries TCP only — so ask for video/audio in-band on TCP.
## On desktop, loopback is a host on the same machine and UDP works.
func _use_tcp_media() -> bool:
	return _force_tcp_media or _on_usb()

## The headset looks for a PC on a USB cable by itself (always on Android).
func _usb_auto() -> bool:
	return OS.has_feature("android") or _usb_port > 0

## Talking to (or trying) the PC through the cable.
func _on_usb() -> bool:
	return _usb_auto() and host_ip.begins_with("127.")

func connect_to_host() -> void:
	if current_state != State.DISCONNECTED or host_ip.is_empty():
		return
	current_state = State.CONNECTING
	_usb_paused = false
	_host_name = _name_for_ip(host_ip)
	_update_overlay_state()
	var port := _usb_port if _on_usb() and _usb_port > 0 else host_tcp_port
	print("[Immersive-2] Connecting to %s:%d..." % [host_ip, port])
	network_client.connect_to_server(host_ip, port, host_udp_port, _use_tcp_media(),
		_pin_for_host())
	_should_reconnect = true

## Probe the cable unless we are on it already or the user disconnected.
func _update_usb_probe() -> void:
	if not _usb_probe:
		return
	_usb_probe.port = _usb_port if _usb_port > 0 else host_tcp_port
	_usb_probe.set_enabled(_usb_auto() and not _usb_paused
		and not (_on_usb() and current_state != State.DISCONNECTED))

func _on_usb_checked(found: bool) -> void:
	if found and not _usb_paused and not (_on_usb() and current_state != State.DISCONNECTED):
		print("[Immersive-2] USB: the PC answers through the cable, switching to it")
		if host_ip.is_valid_ip_address() and not host_ip.begins_with("127."):
			_lan_ip = host_ip
		_connect_after_probe = false
		_switch_to("127.0.0.1")
	elif _connect_after_probe:
		_connect_after_probe = false
		connect_to_host()

## Move the connection to `ip` now. Handled like a dropped connection, so
## the screens stay where they are and come back with the same monitors.
func _switch_to(ip: String) -> void:
	if current_state != State.DISCONNECTED:
		network_client.disconnect_from_server()
		_on_disconnected()
	host_ip = ip
	_reconnect_timer = 0.0
	connect_to_host()

func disconnect_from_host() -> void:
	_should_reconnect = false
	_usb_paused = true
	_auto_connect = false
	_save_config()
	if network_client:
		network_client.disconnect_from_server()
	if audio_receiver:
		audio_receiver.stop()
	_audio_on = false
	current_state = State.DISCONNECTED
	_show_screen_off(false)
	active_monitor_ids.clear()
	_update_overlay_state()
	_update_overlay_monitors()
	_clear_all_screens()
	_update_discovery()

## The name a discovered PC answers with at `ip`, if any.
func _name_for_ip(ip: String) -> String:
	if discovery:
		for h in discovery.get_hosts():
			if h.ip == ip:
				return h.name
	return _last_host_name if ip == host_ip else ""

func _pin_for_host() -> int:
	if not _host_name.is_empty() and _pins.has("name:" + _host_name):
		return int(_pins["name:" + _host_name])
	return int(_pins.get("ip:" + host_ip, 0))

## Toggle a monitor: selecting a new one adds a screen (up to MAX_SCREENS),
## selecting an active one removes its screen. The full selection is sent to
## the host, which reconciles its per-monitor streams.
func select_monitor(monitor_id: int, _slot: int = 0) -> void:
	if current_state != State.CONNECTED and current_state != State.STREAMING:
		return
	if active_monitor_ids.has(monitor_id):
		active_monitor_ids.erase(monitor_id)
	else:
		if active_monitor_ids.size() >= MAX_SCREENS:
			active_monitor_ids.pop_front()  # replace the oldest selection
		active_monitor_ids.append(monitor_id)
	_send_monitor_selection()
	_update_overlay_monitors()
	_schedule_save()

func _send_monitor_selection() -> void:
	if not network_client:
		return
	print("[Immersive-2] Requesting monitors: %s" % [active_monitor_ids])
	if active_monitor_ids.size() == 1:
		network_client.select_monitor(active_monitor_ids[0])
	else:
		network_client.select_monitors(active_monitor_ids)

# ---------------------------------------------------------------------------
# Screen panels
# ---------------------------------------------------------------------------

func _create_screen_panel() -> MeshInstance3D:
	var panel := MeshInstance3D.new()
	panel.script = preload("res://scripts/screen_panel.gd")
	add_child(panel)
	return panel

func _clear_all_screens() -> void:
	_close_all_decoders()
	for panel in screen_panels:
		if is_instance_valid(panel):
			panel.queue_free()
	screen_panels.clear()

func _apply_panel_visual_settings(panel: MeshInstance3D) -> void:
	if panel and panel.has_method("set_curvature"):
		panel.set_curvature(curved_screen_enabled, curved_screen_amount)
	if panel and panel.has_method("set_compositor_layer"):
		panel.set_compositor_layer(compositor_layers and layers_supported(), xr_origin)

## Whether the OpenXR runtime composites layers itself (Quest, Pico and
## SteamVR do); otherwise the screens stay ordinary meshes.
func layers_supported() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	if not xr or not xr.is_initialized() or not ClassDB.class_exists("OpenXRCompositionLayerQuad"):
		return false
	var probe: Object = ClassDB.instantiate("OpenXRCompositionLayerQuad")
	var ok: bool = probe.is_natively_supported()
	probe.free()
	return ok

func _apply_visual_settings_to_all_panels() -> void:
	for panel in screen_panels:
		if is_instance_valid(panel):
			_apply_panel_visual_settings(panel)

func _live_panels() -> Array:
	return screen_panels.filter(func(p): return is_instance_valid(p))

## What a pointer ray lands on: the NEAREST of the menu, the keyboard, the
## whiteboard, every screen and every grab bar (vr_input.gd and hand_input.gd
## both use it). Returns {} on a miss, else { kind: "overlay" / "keyboard" /
## "whiteboard" / "panel" / "bar",
## distance, and uv (overlay, panel), panel + monitor_id (panel), target (the
## node a bar moves: a screen, the menu, the keyboard, the whiteboard or a
## ResizeHandle) + bar
## (the GrabBar or ResizeHandle, both have mark_hovered()) }.
func pick(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	var hits: Array = []
	var ui := get_ui_hit_from_ray(ray_origin, ray_direction)
	if ui.get("valid", false):
		hits.append({"kind": "overlay", "distance": ui.distance, "uv": ui.uv})
	if is_instance_valid(virtual_keyboard) and virtual_keyboard.visible:
		var kb: Dictionary = virtual_keyboard.ray_hit(ray_origin, ray_direction)
		if not kb.is_empty():
			hits.append({"kind": "keyboard", "distance": kb.distance})
	if is_instance_valid(whiteboard) and whiteboard.visible:
		var wb := whiteboard.ray_hit(ray_origin, ray_direction)
		if not wb.is_empty():
			hits.append({"kind": "whiteboard", "distance": wb.distance})
		for handle in whiteboard.resize_handles:
			var d: float = handle.probe(ray_origin, ray_direction)
			if d >= 0.0 and wb.is_empty():
				hits.append({"kind": "bar", "distance": d, "rank": d + 0.06, "target": handle, "bar": handle})
	var owners: Array = _live_panels()
	for p in owners:
		var h: Dictionary = p.ray_to_screen_hit(ray_origin, ray_direction)
		var on_screen: bool = h.get("valid", false)
		if on_screen:
			hits.append({"kind": "panel", "distance": h.distance, "uv": h.uv, "panel": p,
				"monitor_id": int(p.get_meta("monitor_id", 0))})
		for handle in p.resize_handles:
			# Probe always (it shows the bracket), but the screen's own pixels win.
			var d: float = handle.probe(ray_origin, ray_direction)
			if d >= 0.0 and not on_screen:
				hits.append({"kind": "bar", "distance": d, "rank": d + 0.06, "target": handle, "bar": handle})
	owners.append_array([ui_overlay, virtual_keyboard, whiteboard])
	for o in owners:
		var bar: GrabBar = o.get("grab_bar") if is_instance_valid(o) else null
		var d: float = bar.hit(ray_origin, ray_direction) if bar else -1.0
		if d >= 0.0:
			# A bar loses a near tie (a screen stacked right under another).
			hits.append({"kind": "bar", "distance": d, "rank": d + 0.02, "target": o, "bar": bar})
	var best := {}
	for h in hits:
		if best.is_empty() or h.get("rank", h.distance) < best.get("rank", best.distance):
			best = h
	return best

## The pointer is not on the keyboard (any more): release its key and hover.
func leave_keyboard() -> void:
	if is_instance_valid(virtual_keyboard):
		virtual_keyboard.pointer_leave()

## The pointer is not on the whiteboard (any more): end its stroke.
func leave_whiteboard() -> void:
	if is_instance_valid(whiteboard):
		whiteboard.pointer_leave()

## Route a pointer ray at the whiteboard (trigger / pinch draws). Returns the
## hit distance, or -1 on a miss.
func send_whiteboard_pointer(ray_origin: Vector3, ray_direction: Vector3, pressing: bool) -> float:
	return whiteboard.pointer_ray(ray_origin, ray_direction, pressing) if is_instance_valid(whiteboard) else -1.0

## A fingertip of hand `who` at `tip` (world): true while it draws on (or
## hovers just in front of) the whiteboard, and the hand's ray should rest.
func whiteboard_touch(who: int, tip: Vector3) -> bool:
	return is_instance_valid(whiteboard) and whiteboard.touch(who, tip)

## Show/hide the whiteboard (the menu, or B on desktop).
func toggle_whiteboard() -> void:
	if is_instance_valid(whiteboard):
		whiteboard.toggle_visibility()

func get_ui_hit_from_ray(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	if ui_overlay and ui_overlay.has_method("ray_to_overlay_hit"):
		return ui_overlay.ray_to_overlay_hit(ray_origin, ray_direction)
	return {"valid": false}

func send_ui_pointer_move(uv: Vector2) -> void:
	if ui_overlay:
		ui_overlay.inject_pointer_move(uv)

func send_ui_pointer_button(pressed: bool, button_index: int = MOUSE_BUTTON_LEFT) -> void:
	if ui_overlay:
		ui_overlay.inject_pointer_button(pressed, button_index)

func send_ui_pointer_scroll(delta_y: float) -> void:
	if ui_overlay:
		ui_overlay.inject_pointer_scroll(delta_y)

## Grab/release the overlay so it can be repositioned with the grip.
func start_ui_drag(pointer: Node3D, distance: float = -1.0) -> void:
	if ui_overlay:
		ui_overlay.start_drag(pointer, distance)

func stop_ui_drag() -> void:
	if ui_overlay:
		ui_overlay.stop_drag()

# ---------------------------------------------------------------------------
# Arrangement
# ---------------------------------------------------------------------------

## Head position and level forward direction.
func _head() -> Array:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var pos := cam.global_position if cam else Vector3(0, 1.6, 0)
	var fwd := -cam.global_basis.z if cam else Vector3.FORWARD
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 0.0001 else Vector3.FORWARD
	return [pos, fwd]

## Place every screen, ordered by monitor id, on an arc in front of the head.
## Each one stands on its own there: none follows another any more.
func arrange_panels() -> void:
	_snapped_to.clear()
	var panels := _live_panels()
	panels.sort_custom(func(a, b): return int(a.get_meta("monitor_id", 0)) < int(b.get_meta("monitor_id", 0)))
	if panels.is_empty():
		return
	var head := _head()
	var pos: Vector3 = head[0]
	var fwd: Vector3 = head[1]
	var right := fwd.cross(Vector3.UP).normalized()
	var angles: Array = []
	var total := 0.0
	for p in panels:
		angles.append(p.panel_width / ARC_RADIUS)
		total += p.panel_width / ARC_RADIUS
	total += ARC_GAP_M / ARC_RADIUS * (panels.size() - 1)
	var a := -total / 2.0
	for i in panels.size():
		var mid: float = a + angles[i] / 2.0
		var at: Vector3 = pos + (fwd * cos(mid) + right * sin(mid)) * ARC_RADIUS
		at.y = pos.y - EYE_DROP_M
		panels[i].place_facing(at, pos)
		panels[i].set_meta("auto_placed", true)
		a += angles[i] + ARC_GAP_M / ARC_RADIUS
	_place_bars()
	_remember_layouts()
	_schedule_save()

## Swing the whole workspace (keeping its shape) back in front of the head.
func recenter_workspace() -> void:
	var panels := _live_panels()
	if panels.is_empty():
		return
	var head := _head()
	var pos: Vector3 = head[0]
	var centroid := Vector3.ZERO
	for p in panels:
		centroid += p.global_position
	centroid /= panels.size()
	var xform := _recenter_transform(pos, head[1], centroid)
	for p in panels:
		p.global_transform = xform * p.global_transform
	_remember_layouts()
	_schedule_save()

## Rotation about the head's vertical axis (plus a height shift) that moves
## `centroid` straight in front of the head, just below eye level.
func _recenter_transform(head_pos: Vector3, head_fwd: Vector3, centroid: Vector3) -> Transform3D:
	var to_c := centroid - head_pos
	to_c.y = 0.0
	if to_c.length_squared() < 0.0001:
		to_c = head_fwd
	var yaw := to_c.normalized().signed_angle_to(head_fwd, Vector3.UP)
	var pivot := Vector3(head_pos.x, 0.0, head_pos.z)
	var rot := Transform3D(Basis(Vector3.UP, yaw), Vector3.ZERO)
	var xform := Transform3D(Basis(), pivot) * rot * Transform3D(Basis(), -pivot)
	var dy := (head_pos.y - EYE_DROP_M) - centroid.y
	return Transform3D(Basis(), Vector3(0, dy, 0)) * xform

## Where a new screen goes when it has no saved spot: first one in front, the
## next ones to the right of the rightmost screen, on the same arc.
func _place_new_panel(panel: MeshInstance3D) -> void:
	var others := _live_panels().filter(func(p): return p != panel)
	if others.is_empty():
		arrange_panels()
		return
	panel.set_meta("auto_placed", true)
	var head := _head()
	var pos: Vector3 = head[0]
	var fwd: Vector3 = head[1]
	var rightmost: MeshInstance3D = null
	var best := -INF
	for p in others:
		var d: Vector3 = p.global_position - pos
		d.y = 0.0
		var ang := fwd.signed_angle_to(d.normalized(), Vector3.DOWN)  # + = to the right
		if ang > best:
			best = ang
			rightmost = p
	var dist := maxf(0.5, Vector2(rightmost.global_position.x - pos.x,
		rightmost.global_position.z - pos.z).length())
	var span: float = rightmost.panel_width / 2.0 + ARC_GAP_M + panel.panel_width / 2.0
	var mid: float = best + span / dist
	var right := fwd.cross(Vector3.UP).normalized()
	var at := pos + (fwd * cos(mid) + right * sin(mid)) * dist
	at.y = rightmost.global_position.y
	panel.place_facing(at, Vector3(pos.x, at.y + EYE_DROP_M, pos.z))

## The landing shown by the white frame (see snap_target_for()), and the frame.
var _snap_pick: Dictionary = {}
var _snap_frame: SnapFrame = null

func _is_linked(panel: Node3D) -> bool:
	return _linked.get(int(panel.get_meta("monitor_id", -1)), false)

## The OTHER screens that move rigidly with `panel` (empty: it moves alone):
## the ones snapped to it (and to those, and so on) and, for a "Move together"
## screen, the other linked ones. The screen it is snapped to stays behind.
func drag_group_for(panel: Node3D) -> Array:
	var ids := [int(panel.get_meta("monitor_id", -1))]
	if _is_linked(panel):
		ids.append_array(_linked.keys().filter(func(k): return _linked[k]))
	ids = _with_snapped(ids)
	return _live_panels().filter(func(p): return p != panel and ids.has(int(p.get_meta("monitor_id", -1))))

## `ids` plus every monitor id snapped to one of them, to those, and so on.
func _with_snapped(ids: Array) -> Array:
	var out := ids.duplicate()
	var i := 0
	while i < out.size():
		for c in _snapped_to:
			if _snapped_to[c] == out[i] and not out.has(c):
				out.append(c)
		i += 1
	return out

## Screens snapped to `panel` go back flush against it, on the side they are
## nearest (it changed size), with whatever is snapped to them.
func _reseat_snapped(panel: Node3D) -> void:
	var pid := int(panel.get_meta("monitor_id", -1))
	for c in _live_panels():
		var cid := int(c.get_meta("monitor_id", -1))
		if c == panel or _snapped_to.get(cid, -1) != pid:
			continue
		var best: Transform3D = c.global_transform
		var best_d := INF
		for side in 4:
			var x: Transform3D = panel.landing_beside(side, c.panel_width, c.panel_height, SNAP_GAP_M)
			if x.origin.distance_to(c.global_position) < best_d:
				best_d = x.origin.distance_to(c.global_position)
				best = x
		var moved: Transform3D = best * c.global_transform.affine_inverse()
		var ids := _with_snapped([cid])
		for p in _live_panels():
			if p != panel and ids.has(int(p.get_meta("monitor_id", -1))):
				p.global_transform = moved * p.global_transform

## A screen with another right under it (one snapped below, or it snapped on
## top) has its grab bar over its top edge: under it the bar would sit on the
## other screen, whose pixels win the pointer.
func _place_bars() -> void:
	var panels := _live_panels()
	for p in panels:
		var spot: Vector3 = p.to_global(p.local_point(0.5, 1.0) + Vector3(0.0, -0.06, 0.0))
		var n: Vector3 = p.global_basis.z
		p.set_bar_on_top(panels.any(func(q):
			var h: Dictionary = q.ray_to_screen_hit(spot + n * 0.3, -n) if q != p else {}
			return h.get("valid", false) and h.distance < 0.6))

## A virtual screen is gone for good (its id comes back for the next one):
## free it and whatever was snapped to it.
func _unsnap(id: int) -> void:
	_snapped_to.erase(id)
	for c in _snapped_to.keys():
		if _snapped_to[c] == id:
			_snapped_to.erase(c)

## A replaced virtual screen keeps its snaps under its new id.
func _rename_snaps(old_id: int, new_id: int) -> void:
	if old_id == new_id:
		return
	var renamed := {}
	for c in _snapped_to:
		renamed[new_id if c == old_id else c] = new_id if _snapped_to[c] == old_id else _snapped_to[c]
	_snapped_to = renamed

## False while the layout is locked (the menu and keyboard still move).
func can_move_panel(_panel: Node3D) -> bool:
	return not lock_layout or _panel.get_parent() is Whiteboard

## Where `panel` would land if released now: { panel: the neighbour, side:
## ScreenPanel.Side, xform: world transform } beside the nearest free side of
## another screen, or {} (snapping off, or nothing close). The side shown last
## frame is favoured a little so the choice does not flicker between two.
func snap_target_for(panel: Node3D) -> Dictionary:
	if not snap_enabled or not is_instance_valid(panel):
		return {}
	var group := drag_group_for(panel)
	var others := _live_panels().filter(func(p): return p != panel and not group.has(p))
	var best := {}
	var best_err := SNAP_CAPTURE_M
	for n in others:
		for side in 4:
			var x: Transform3D = n.landing_beside(side, panel.panel_width, panel.panel_height, SNAP_GAP_M)
			var err := x.origin.distance_to(panel.global_position)
			if _snap_pick.get("panel") == n and _snap_pick.get("side") == side:
				err -= SNAP_STICKY_M
			if err > best_err or x.basis.z.angle_to(panel.global_basis.z) > deg_to_rad(SNAP_TURN_DEG):
				continue
			# Somebody already sits there.
			var min_side := minf(panel.panel_width, panel.panel_height) * 0.4
			if others.any(func(q): return q != n and q.global_position.distance_to(x.origin) < min_side):
				continue
			best = {"panel": n, "side": side, "xform": x}
			best_err = err
	return best

## Every frame: the white frame follows the screen being dragged, if any.
func _update_snap_preview() -> void:
	var dragged: Node3D = null
	for p in _live_panels():
		if p.is_dragging():
			dragged = p
	_snap_pick = snap_target_for(dragged) if dragged else {}
	if _snap_pick.is_empty():
		if _snap_frame:
			_snap_frame.clear()
		return
	if not _snap_frame:
		_snap_frame = SnapFrame.new()
		add_child(_snap_frame)
	_snap_frame.show_at(_snap_pick.xform, dragged.panel_width, dragged.panel_height, dragged.get_arc())

## A screen grab ended: it lands in the frame that was showing and from now on
## follows that neighbour (moving the neighbour moves it); dropped anywhere
## else it follows nobody. What follows it moves with it. "Move together" is
## not touched. Called before on_layout_changed().
func on_panel_drag_ended(panel: Node3D) -> void:
	var target := snap_target_for(panel)
	_snap_pick = {}
	if _snap_frame:
		_snap_frame.clear()
	var mid := int(panel.get_meta("monitor_id", -1))
	if target.is_empty():
		_snapped_to.erase(mid)
		return
	var old := panel.global_transform
	panel.global_transform = target.xform
	var moved := panel.global_transform * old.affine_inverse()
	for g in drag_group_for(panel):
		g.global_transform = moved * g.global_transform
	_snapped_to[mid] = int(target.panel.get_meta("monitor_id", -1))

## Called by vr_input.gd when a grab ends: the layout is now the user's, so
## new screens no longer re-arrange the others.
func on_layout_changed() -> void:
	for p in _live_panels():
		p.set_meta("auto_placed", false)
		_reseat_snapped(p)  # a resized screen keeps what is snapped to it flush
	_place_bars()
	_remember_layouts()
	_schedule_save()

func _remember_layouts() -> void:
	for p in _live_panels():
		var mid := int(p.get_meta("monitor_id", -1))
		if mid >= 0:
			_layouts[mid] = p.get_layout_state()

# ---------------------------------------------------------------------------
# UI Overlay
# ---------------------------------------------------------------------------

func _init_ui_overlay() -> void:
	ui_overlay = preload("res://scripts/ui_overlay.gd").new()
	ui_overlay.name = "UIOverlay"
	add_child(ui_overlay)

	ui_overlay.connect_requested.connect(_on_overlay_connect_requested)
	ui_overlay.pin_entered.connect(_on_pin_entered)
	ui_overlay.pin_cancelled.connect(func(): ui_overlay.set_notice(""))
	ui_overlay.monitor_selected.connect(func(id): select_monitor(id))
	ui_overlay.arrange_requested.connect(arrange_panels)
	ui_overlay.recenter_requested.connect(recenter_workspace)
	ui_overlay.keyboard_toggle_requested.connect(toggle_virtual_keyboard)
	ui_overlay.whiteboard_toggle_requested.connect(toggle_whiteboard)
	ui_overlay.screen_curvature_changed.connect(_on_overlay_screen_curvature_changed)
	ui_overlay.look_changed.connect(_on_overlay_look_changed)
	ui_overlay.stream_settings_changed.connect(_on_overlay_stream_settings_changed)
	ui_overlay.auto_quality_requested.connect(_on_overlay_auto_quality_requested)
	ui_overlay.virtual_screen_requested.connect(request_virtual_screen)
	ui_overlay.virtual_screen_remove_requested.connect(remove_virtual_screen)
	ui_overlay.virtual_screen_match_requested.connect(match_virtual_screen)
	ui_overlay.virtual_page_requested.connect(_open_virtual_page)
	ui_overlay.screen_off_toggled.connect(func(off: bool):
		_screen_off = off
		network_client.send_screen_off(off))
	ui_overlay.control_toggled.connect(func(on: bool):
		control_enabled = on
		_last_mouse_state.clear()
		_save_config())
	ui_overlay.haptics_toggled.connect(func(on: bool):
		haptics_enabled = on
		_save_config())
	ui_overlay.screen_link_changed.connect(func(mid: int, linked: bool):
		_linked[mid] = linked
		_schedule_save())
	ui_overlay.snap_toggled.connect(func(on: bool):
		snap_enabled = on
		_save_config())
	ui_overlay.lock_toggled.connect(func(on: bool):
		lock_layout = on
		_save_config())
	ui_overlay.pointer_settings_changed.connect(func(hand: String, angle: float, face_me: bool):
		pointer_hand = hand
		ray_angle_deg = angle
		screens_face_me = face_me
		LaserDrag.face_me = face_me
		_save_config())
	ui_overlay.compositor_layers_toggled.connect(func(on: bool):
		compositor_layers = on
		_apply_visual_settings_to_all_panels()
		_save_config())

	ui_overlay.set_host_address(host_ip, host_tcp_port, host_udp_port)
	ui_overlay.set_screen_curvature(curved_screen_enabled, curved_screen_amount)
	ui_overlay.set_look("passthrough" if passthrough_enabled else look, _is_passthrough_supported())
	ui_overlay.set_stream_settings(stream_codec, stream_bitrate_kbps,
		stream_jpeg_quality, stream_res_percent, stream_fps)
	ui_overlay.set_input_settings(control_enabled, haptics_enabled)
	ui_overlay.set_layout_options(snap_enabled, lock_layout)
	ui_overlay.set_linked_monitors(_linked.keys().filter(func(k): return _linked[k]))
	ui_overlay.set_pointer_settings(pointer_hand, ray_angle_deg, screens_face_me)
	ui_overlay.set_compositor_layers(compositor_layers, true)

func _show_overlay() -> void:
	if ui_overlay and not ui_overlay.is_shown():
		ui_overlay.set_shown(true)

func _update_overlay_state() -> void:
	if ui_overlay:
		ui_overlay.set_state(current_state as int)
		ui_overlay.set_host_label(_host_name if not _host_name.is_empty() else host_ip)
		ui_overlay.set_link("USB" if _use_tcp_media() else
			("Wi-Fi" if OS.has_feature("android") else ""))

func _update_overlay_monitors() -> void:
	if ui_overlay:
		ui_overlay.set_active_monitors(active_monitor_ids)

# ---------------------------------------------------------------------------
# Stream quality
# ---------------------------------------------------------------------------

func _send_stream_config() -> void:
	if network_client:
		network_client.send_stream_config(stream_codec, stream_bitrate_kbps,
			stream_jpeg_quality, stream_max_width, stream_fps)

## The screen being worked on: the one the pointer was last on, else the first.
func _reference_panel() -> MeshInstance3D:
	var panels := _live_panels()
	var i := pick_reference(_last_pointed_monitor,
		panels.map(func(p): return int(p.get_meta("monitor_id", -1))))
	return panels[i] if i >= 0 else null

## Index into `shown_ids` of the pointed monitor, else 0; -1 when none shown.
static func pick_reference(pointed: int, shown_ids: Array) -> int:
	if shown_ids.is_empty():
		return -1
	return maxi(shown_ids.find(pointed), 0)

## What the headset resolves, pixels per degree: the eye buffer width over the
## real horizontal FOV when XR is up, else the old guess (95 degrees).
func _headset_ppd() -> float:
	var xr := XRServer.get_primary_interface()
	if xr and xr.is_initialized():
		var size: Vector2 = xr.get_render_target_size()
		if size.x > 0.0 and size.y > 0.0:
			var proj: Projection = xr.get_projection_for_view(0, size.x / size.y, 0.05, 100.0)
			if proj.x.x > 0.01:
				return maxf(8.0, size.x / rad_to_deg(2.0 * atan(1.0 / proj.x.x)))
	return maxf(8.0, float(get_viewport().size.x) / 95.0)

## Native size of the monitor shown on the pointed panel (or first available
## monitor) — reference for percentage-based downscaling.
func _reference_monitor() -> Dictionary:
	var mon_id := -1
	var ref := _reference_panel()
	if ref:
		mon_id = int(ref.get_meta("monitor_id", -1))
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
##   panel angular size  = panel width (arc) / distance, in degrees
##   ideal width (px)    = PPD * panel angle, capped to the native width
func compute_ideal_stream_settings() -> Dictionary:
	var panel_w_m := 1.6
	var distance := ARC_RADIUS
	var ref := _reference_panel()
	if ref:
		panel_w_m = ref.panel_width
		if xr_camera:
			distance = (ref.global_position - xr_camera.global_position).length()

	var mon := _reference_monitor()
	var native_w: int = mon.get("width", 1920)
	var native_h: int = mon.get("height", 1080)
	var native_hz: int = mon.get("refresh_rate", 60)

	var ppd := _headset_ppd()
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

	return {"width": ideal_w, "height": ideal_h, "fps": ideal_fps, "ppd": ppd,
		"angle_deg": panel_angle_deg, "distance": distance}

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
	# Reflect the resolved codec back (e.g. "Auto" → "H.264") so the selected
	# option matches what is actually streamed.
	if stream_codec != codec and ui_overlay:
		ui_overlay.set_stream_settings(stream_codec, stream_bitrate_kbps,
			stream_jpeg_quality, stream_res_percent, stream_fps)

func _on_overlay_auto_quality_requested() -> void:
	var ideal := compute_ideal_stream_settings()
	stream_res_percent = -1
	stream_max_width = ideal["width"]
	stream_fps = ideal["fps"]
	_save_config()
	_send_stream_config()
	if ui_overlay:
		ui_overlay.set_auto_quality_result(ideal["width"], ideal["height"], ideal["fps"],
			ideal["ppd"], ideal["angle_deg"], ideal["distance"])
		ui_overlay.set_stream_settings(stream_codec, stream_bitrate_kbps,
			stream_jpeg_quality, stream_res_percent, stream_fps)

# ---------------------------------------------------------------------------
# Reconnect, latency, stats
# ---------------------------------------------------------------------------

func _handle_reconnect(delta: float) -> void:
	if _should_reconnect and current_state == State.DISCONNECTED:
		_reconnect_timer += delta
		if _reconnect_timer >= RECONNECT_DELAY:
			_reconnect_timer = 0.0
			print("[Immersive-2] Attempting auto-reconnect to %s..." % host_ip)
			connect_to_host()

func _handle_latency_probe(delta: float) -> void:
	if current_state != State.STREAMING and current_state != State.CONNECTED:
		return
	_latency_timer += delta
	if _latency_timer >= LATENCY_INTERVAL:
		_latency_timer = 0.0
		_probe_id += 1
		_probe_sent_us = Time.get_ticks_usec()
		network_client.send_latency_probe(_probe_id, _probe_sent_us)
		if _screen_off:
			network_client.send_screen_off(true)  # renews the host's lease

## Once a second: received fps / Mbps for the status line and the details.
func _handle_stats(delta: float) -> void:
	_stats_timer += delta
	if _stats_timer < 1.0:
		return
	_stats_timer = 0.0
	if current_state != State.STREAMING or not ui_overlay:
		return
	var stats: Dictionary = network_client.take_stats()
	ui_overlay.set_stream_stats(stats.fps, stats.mbps)
	if ui_overlay.is_shown():
		ui_overlay.set_connection_details(_connection_details(stats))

func _connection_details(stats: Dictionary) -> Array:
	var rows := [["Address", "%s:%d" % [host_ip, host_tcp_port]],
		["Link", "USB cable" if _use_tcp_media() else
			("Wi-Fi" if OS.has_feature("android") else "Network") + " (video over UDP)"]]
	if _latency_ms > 0.0:
		rows.append(["Delay", "%d ms round trip" % int(round(_latency_ms))])
	var pics: Array = []
	for mid in _stream_info:
		var info: Dictionary = _stream_info[mid]
		pics.append("%s %d×%d" % [CODEC_NAMES.get(info.codec, "?"), info.w, info.h])
	if not pics.is_empty():
		rows.append(["Picture", ", ".join(pics)])
	rows.append(["Received", "%d fps · %.1f Mbps" % [int(round(stats.fps)), stats.mbps]])
	rows.append(["Control", "Off: this PC is view-only" if _host_view_only()
		else ("On" if control_enabled else "Off")])
	rows.append(["Sound", "Stereo, 48 kHz" if _audio_on else "Off"])
	return rows

# ---------------------------------------------------------------------------
# Callbacks — network events
# ---------------------------------------------------------------------------

func _on_connected() -> void:
	current_state = State.CONNECTED
	_show_screen_off(false)
	_reconnect_timer = 0.0
	_codec_fallback_sent = false
	_update_overlay_state()
	_update_discovery()
	# Send quality settings before any stream starts (TCP preserves order)
	_recompute_stream_max_width()
	_send_stream_config()
	print("[Immersive-2] Connected to host")

func _on_handshake_accepted(host_name: String, host_flags: int = 0) -> void:
	_host_flags = host_flags
	if ui_overlay:
		ui_overlay.set_host_capabilities(_host_view_only(), (host_flags & 0x02) != 0,
			(host_flags & 0x04) != 0)
	if _cmdline_virtual != Vector2i.ZERO:
		print("[Immersive-2][TEST] requesting a %dx%d virtual screen" % [_cmdline_virtual.x, _cmdline_virtual.y])
		network_client.send_virtual_display_create(_cmdline_virtual.x, _cmdline_virtual.y, 60)
		_cmdline_virtual = Vector2i.ZERO
	if not host_name.is_empty():
		_host_name = host_name
		_last_host_name = host_name
	if not host_ip.begins_with("127."):
		_lan_ip = host_ip
	var pin := int(_pins.get("pending", 0))
	_pins.erase("pending")
	if pin > 0:
		_pins["ip:" + host_ip] = pin
		if not _host_name.is_empty():
			_pins["name:" + _host_name] = pin
	_auto_connect = true
	_save_config()
	if ui_overlay:
		ui_overlay.set_notice("")
		ui_overlay.hide_pin_prompt()
	_update_overlay_state()

func _on_connection_rejected(reason: int) -> void:
	var who := _host_name if not _host_name.is_empty() else host_ip
	match reason:
		1, 2:
			# Wrong or missing PIN: ask for it instead of retrying blind.
			_should_reconnect = false
			_pins.erase("ip:" + host_ip)
			_pins.erase("name:" + _host_name)
			_save_config()
			if ui_overlay:
				ui_overlay.show_pin_prompt(2 if reason == 2 else 1, who)
		3:
			if ui_overlay:
				ui_overlay.set_notice("%s already has as many headsets as it allows. Trying again…" % who)
		4:
			_should_reconnect = false
			if ui_overlay:
				ui_overlay.set_notice("Too many wrong PINs. Wait a minute, then connect again.")
				_show_overlay()

func _on_pin_entered(pin: int) -> void:
	_pins["pending"] = pin
	_pins["ip:" + host_ip] = pin
	if ui_overlay:
		ui_overlay.set_notice("")
	connect_to_host()

## The host's word on the main screen (or a reset): the switch follows it.
func _show_screen_off(off: bool) -> void:
	_screen_off = off
	if ui_overlay:
		ui_overlay.set_screen_off(off)

## Headset taken off: light the PC's screen now rather than when the host's
## lease runs out (it would anyway, if this never gets out).
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED and _screen_off:
		network_client.send_screen_off(false)
		_show_screen_off(false)

func _on_disconnected() -> void:
	var was_streaming := current_state == State.STREAMING
	current_state = State.DISCONNECTED
	_show_screen_off(false)  # the host lights it when we leave
	_pending_virtual_id = -1
	_match.clear()
	_update_overlay_state()
	_update_discovery()
	if audio_receiver:
		audio_receiver.stop()
	_audio_on = false
	if was_streaming:
		_remember_layouts()
	print("[Immersive-2] Disconnected from host")
	# Cable pulled (or its host gone): straight back to Wi-Fi, and give the
	# cable a moment before trying it again.
	if _should_reconnect and _on_usb() and not _lan_ip.is_empty():
		print("[Immersive-2] USB link lost, back to Wi-Fi at %s" % _lan_ip)
		host_ip = _lan_ip
		_reconnect_timer = RECONNECT_DELAY
		_usb_probe.hold(3000)

func _on_monitor_list(monitors: Array) -> void:
	available_monitors = monitors
	print("[Immersive-2] Available monitors: %d" % monitors.size())
	for m in monitors:
		print("  [%d] %s (%dx%d)" % [m.id, m.name, m.width, m.height])
	if ui_overlay:
		ui_overlay.set_monitor_list(monitors)

	# What to show: the command line's choice, then what was on screen before a
	# reconnect, then the saved workspace, then the first monitor.
	var wanted: Array = []
	if not _cmdline_monitors.is_empty():
		wanted = _cmdline_monitors.duplicate()
		_cmdline_monitors.clear()
	elif not active_monitor_ids.is_empty():
		wanted = active_monitor_ids.duplicate()
	elif not _workspace_monitor_ids.is_empty():
		wanted = _workspace_monitor_ids.duplicate()
	var ids: Array = monitors.map(func(m): return int(m.id))
	wanted = wanted.filter(func(id): return ids.has(int(id))).map(func(id): return int(id))
	# (Not mid 1:1 resize: the virtual screen is about to come back.)
	if wanted.is_empty() and not ids.is_empty() and _match.is_empty():
		wanted = [ids[0]]
	active_monitor_ids = wanted.slice(0, MAX_SCREENS)

	# Screens of monitors that are not coming back would sit frozen.
	for panel in _live_panels():
		var mid := int(panel.get_meta("monitor_id", -1))
		if not active_monitor_ids.has(mid):
			_close_decoder(mid)
			screen_panels.erase(panel)
			panel.queue_free()

	_update_overlay_monitors()
	if _pending_virtual_id >= 0 and ids.has(_pending_virtual_id):
		_show_new_virtual_screen()
	elif not active_monitor_ids.is_empty():
		_send_monitor_selection()

func _on_stream_started(monitor_id: int, width: int, height: int, codec: int = 2) -> void:
	current_state = State.STREAMING
	_update_overlay_state()
	print("[Immersive-2] Streaming monitor %d (%dx%d) codec=%d" % [monitor_id, width, height, codec])
	_stream_info[monitor_id] = {"codec": codec, "w": width, "h": height}

	# A restarted stream can change the pixel scale, so the de-dup memory in
	# send_mouse_input() must not suppress the first move at the same UV.
	_last_mouse_state.clear()

	# Keep the local selection in sync (covers host-side restarts).
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
			# reference a P-frame with no prior I-frame context. The host
			# starts every stream with an IDR, so none is requested here.
			_awaiting_idr[monitor_id] = true
		else:
			_request_codec_fallback(codec)
	elif codec == 2 and SoftwareVideoDecoder.is_codec_supported(codec):
		# MJPEG — software (CPU) decode for PC / iOS / web (no MediaCodec plugin).
		var sw := SoftwareVideoDecoder.new()
		if sw.open(codec, width, height):
			_sw_decoders[monitor_id] = sw

	var panel := _find_panel_for_monitor(monitor_id)
	var is_new := panel == null
	if is_new:
		panel = _create_screen_panel()
		panel.set_meta("monitor_id", monitor_id)
		screen_panels.append(panel)
	panel.set_resolution(width, height, codec)
	_apply_panel_visual_settings(panel)
	if is_new:
		var layout := _layout_for(monitor_id)
		if layout.is_empty() and _is_virtual(monitor_id):
			panel.set_panel_width(VirtualSize.default_width_m(float(width) / height))
		if not layout.is_empty():
			panel.apply_layout_state(layout)
			# Back at another size (a replaced virtual screen): what is snapped
			# to it, and it against the one it is snapped to, stay flush.
			_reseat_snapped(panel)
			var under := _find_panel_for_monitor(_snapped_to.get(monitor_id, -1))
			if under:
				_reseat_snapped(under)
		elif _live_panels().all(func(p): return p == panel or p.get_meta("auto_placed", false)):
			# Nothing placed by hand yet (e.g. the first connection, where the
			# streams start in any order): lay them all out, in monitor order.
			arrange_panels()
		else:
			panel.set_meta("auto_placed", true)
			_place_new_panel(panel)
			_remember_layouts()
			_schedule_save()
		_place_bars()

## The remembered spot for a monitor's screen. Layouts read from disk are
## checked once against where the user now looks: a workspace saved facing
## another way (or in another tracking space) is swung round in front.
func _layout_for(monitor_id: int) -> Dictionary:
	if not _layouts.has(monitor_id):
		return {}
	if _layouts_from_disk:
		_layouts_from_disk = false
		var head := _head()
		var centroid := Vector3.ZERO
		var n := 0
		# Only the screens of the saved workspace: layouts of monitors that are
		# not shown any more must not drag the centroid around.
		for mid in _layouts:
			if not _workspace_monitor_ids.is_empty() and not _workspace_monitor_ids.has(mid):
				continue
			var p: Array = _layouts[mid].get("position", [])
			if p.size() == 3:
				centroid += Vector3(p[0], p[1], p[2])
				n += 1
		if n > 0:
			centroid /= n
			var to_c: Vector3 = centroid - head[0]
			to_c.y = 0.0
			var off := rad_to_deg(absf(head[1].signed_angle_to(to_c.normalized(), Vector3.UP)))
			if off > RESTORE_MAX_YAW_DEG or to_c.length() > 4.0 or to_c.length() < 0.3:
				var xform := _recenter_transform(head[0], head[1], centroid)
				for mid in _layouts:
					_layouts[mid] = _transformed_layout(_layouts[mid], xform)
	return _layouts[monitor_id]

func _transformed_layout(layout: Dictionary, xform: Transform3D) -> Dictionary:
	var p: Array = layout.get("position", [])
	var b: Array = layout.get("basis", [])
	if p.size() != 3 or b.size() != 9:
		return layout
	var t := xform * Transform3D(Basis(Vector3(b[0], b[1], b[2]), Vector3(b[3], b[4], b[5]),
		Vector3(b[6], b[7], b[8])), Vector3(p[0], p[1], p[2]))
	var out := layout.duplicate()
	out["position"] = [t.origin.x, t.origin.y, t.origin.z]
	out["basis"] = [t.basis.x.x, t.basis.x.y, t.basis.x.z, t.basis.y.x, t.basis.y.y,
		t.basis.y.z, t.basis.z.x, t.basis.z.y, t.basis.z.z]
	return out

func _on_stream_stopped(monitor_id: int) -> void:
	if monitor_id < 0:
		return  # unknown monitor; nothing to remove
	_close_decoder(monitor_id)
	_stream_info.erase(monitor_id)
	var panel := _find_panel_for_monitor(monitor_id)
	if panel:
		# Remember where it was: a codec or resolution change restarts every stream, and
		# the screen must come back in the same place.
		_layouts[monitor_id] = panel.get_layout_state()
		screen_panels.erase(panel)
		panel.queue_free()
	if _live_panels().is_empty() and current_state == State.STREAMING:
		current_state = State.CONNECTED
		_update_overlay_state()

func _on_video_frame(monitor_id: int, frame_data: PackedByteArray, width: int, height: int) -> void:
	if _decoders.has(monitor_id):
		var dec: VideoDecoder = _decoders[monitor_id]
		if _awaiting_idr.get(monitor_id, false):
			if not _is_keyframe(frame_data, dec._codec):
				# The stream's first IDR can reach us before its STREAM_START
				# was handled (UDP overtakes TCP) and the host sends no
				# periodic IDR any more: ask for one, or the screen stays
				# black until some rate change re-opens the encoder. A still
				# screen sends one P-frame a second, so the ask is a second
				# apart at most.
				_request_keyframe(monitor_id, 1000)
				return
			_awaiting_idr.erase(monitor_id)
		if not dec.submit(frame_data):
			_request_keyframe(monitor_id)  # the decoder dropped it
		return

	# Software MJPEG path (PC / iOS / web): hand the JPEG to the threaded decoder;
	# the decoded image is polled and uploaded each frame in _update_decoders().
	if _sw_decoders.has(monitor_id):
		_sw_decoders[monitor_id].submit(frame_data)
		return

	# Last resort (raw RGBA/NV12 frame, no decoder): decode on this monitor's
	# own panel — never on another monitor's.
	var panel := _find_panel_for_monitor(monitor_id)
	if panel:
		panel.update_texture(frame_data, width, height)

## A frame was lost or dropped. For inter-frame codecs (H.264/HEVC/AV1) a missing
## P-frame corrupts the decode chain — typically as artefacts that linger until a
## clean intra arrives (e.g. a "ghost" cursor where the delta that erased the old
## position never arrived). We recover by asking the host for a fresh IDR.
func _on_frame_gap(monitor_id: int) -> void:
	if not _decoders.has(monitor_id):
		return
	# Cold start: still waiting for the first IDR. Flush stale decoder buffers so
	# they don't delay the clean intra we're about to accept.
	if _awaiting_idr.get(monitor_id, false):
		_decoders[monitor_id].flush()
		return
	# Steady state: request an IDR, throttled so a burst of losses can't trigger
	# an IDR storm. The decoder keeps showing concealed frames until it lands.
	_request_keyframe(monitor_id)

## Ask the host for a fresh keyframe (intra), throttled per monitor.
func _request_keyframe(monitor_id: int, min_interval_ms: int = 250) -> bool:
	if not _decoders.has(monitor_id):
		return false
	var now := Time.get_ticks_msec()
	var last: int = _last_keyframe_req_ms.get(monitor_id, -10000)
	if now - last < min_interval_ms:
		return false
	_last_keyframe_req_ms[monitor_id] = now
	network_client.send_request_keyframe(monitor_id)
	return true

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
	for panel in _live_panels():
		if panel.save_debug_png("user://im2_panel_%d.png" % _debug_capture_count):
			saved = true
			break
	# The viewport texture is not CPU-readable in XR/compositor mode or headless.
	if (not xr_interface or not xr_interface.is_initialized()) \
			and DisplayServer.get_name() != "headless":
		var tex := get_viewport().get_texture()
		if tex:
			var img := tex.get_image()
			if img:
				img.save_png("user://im2_view_%d.png" % _debug_capture_count)
	var sw_stats := []
	for mid in _sw_decoders:
		var sw: SoftwareVideoDecoder = _sw_decoders[mid]
		sw_stats.append("%d:%d/%d/%d" % [mid, sw.frames_in, sw.frames_out, sw.frames_bad])
	print("[Immersive-2][TEST] debug capture #%d (panel=%s) state=%d decoders=%d mjpeg in/out/bad=%s" %
		[_debug_capture_count, str(saved), current_state, _decoders.size(), " ".join(sw_stats)])
	# One line per panel with its centre pixel, so host/tools/e2e_test.py can
	# check each monitor's decoded image landed on that monitor's panel.
	for mid in active_monitor_ids:
		var panel := _find_panel_for_monitor(mid)
		if panel and panel.screen_image and not panel.screen_image.is_empty():
			var img: Image = panel.screen_image
			print("[Immersive-2][TEST] panel mon=%d %dx%d center=%s" % [mid,
				img.get_width(), img.get_height(),
				img.get_pixel(img.get_width() / 2, img.get_height() / 2).to_html(false)])

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
	_stream_info.clear()

## Each frame: drive both decoder kinds onto their panels.
##   - Hardware (ExternalTexture): wire the OES texture to the panel once, then
##     schedule the render-thread updateTexImage.
##   - Software (MJPEG): poll the threaded decoder for a freshly decoded image and
##     upload it to the panel.
func _update_decoders() -> void:
	for monitor_id in _decoders:
		var dec: VideoDecoder = _decoders[monitor_id]
		if not dec.is_open() or not dec.has_external_texture():
			continue
		var panel := _find_panel_for_monitor(monitor_id)
		if panel == null:
			continue
		if not panel.is_using_external_texture():
			panel.set_external_texture(dec.get_external_texture(), dec.get_width(), dec.get_height())
		var mat := panel.material_override
		if mat is ShaderMaterial:
			dec.schedule_update(mat as ShaderMaterial, panel.get_layer_material())

	for monitor_id in _sw_decoders:
		var sw: SoftwareVideoDecoder = _sw_decoders[monitor_id]
		if not sw.is_open():
			continue
		var img := sw.get_decoded_image()
		if img == null:
			continue
		var panel := _find_panel_for_monitor(monitor_id)
		if panel:
			panel.update_decoded_image(img)

## Return the screen panel currently assigned to monitor_id, or null.
func _find_panel_for_monitor(monitor_id: int) -> MeshInstance3D:
	for panel in screen_panels:
		if is_instance_valid(panel) and int(panel.get_meta("monitor_id", -1)) == monitor_id:
			return panel
	return null

## Detect whether data begins with an IDR / intra NAL unit (Annex-B).
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
## a Pico 4 / Quest 2), MJPEG otherwise. Runtime only: the user's saved codec
## preference is kept.
func _request_codec_fallback(codec: int) -> void:
	if _codec_fallback_sent:
		return
	_codec_fallback_sent = true
	var fallback := 2  # MJPEG
	if codec != 0 and VideoDecoder.is_codec_supported(0):
		fallback = 0  # H.264
	push_warning("[Immersive-2] No decoder for %s on this device — requesting %s" %
		[CODEC_NAMES.get(codec, str(codec)), CODEC_NAMES.get(fallback, "MJPEG")])
	network_client.send_stream_config(fallback, stream_bitrate_kbps,
		stream_jpeg_quality, stream_max_width, stream_fps)
	if ui_overlay:
		ui_overlay.set_notice("This headset cannot decode %s; showing %s instead." %
			[CODEC_NAMES.get(codec, "that codec"), CODEC_NAMES.get(fallback, "MJPEG")])

func _on_audio_stream_started(_sample_rate: int, _channels: int, audio_port: int) -> void:
	if audio_receiver == null:
		audio_receiver = preload("res://scripts/audio_receiver.gd").new()
		audio_receiver.name = "AudioReceiver"
		add_child(audio_receiver)
	# USB mode: packets come on TCP (audio_packet_received); bind an ephemeral
	# port rather than the real one, which nothing will ever send to.
	_audio_on = audio_receiver.start(host_ip, 0 if _use_tcp_media() else audio_port)

func _on_audio_stream_stopped() -> void:
	if audio_receiver:
		audio_receiver.stop()
	_audio_on = false

func _on_latency_response(probe_id: int, _client_ts: int) -> void:
	if probe_id != _probe_id:
		return
	_latency_ms = float(Time.get_ticks_usec() - _probe_sent_us) / 1000.0
	if ui_overlay:
		ui_overlay.set_latency(_latency_ms)

# ---------------------------------------------------------------------------
# Virtual screens
# ---------------------------------------------------------------------------

## Ask the PC for an extra screen that exists only in the headset.
func request_virtual_screen(width: int, height: int) -> void:
	if current_state != State.CONNECTED and current_state != State.STREAMING:
		return
	_remember_virtual_size(width, height)
	network_client.send_virtual_display_create(width, height, 60)

func _remember_virtual_size(width: int, height: int) -> void:
	virtual_size = Vector2i(width, height)
	_save_config()

func _is_virtual(monitor_id: int) -> bool:
	return available_monitors.any(func(m): return int(m.id) == monitor_id and m.get("virtual", false))

## The menu's size page: for a new screen (-1) at the default spot, or for
## that virtual screen where it hangs now (it must be on: its spot and width
## decide the 1:1 size).
func _open_virtual_page(monitor_id: int) -> void:
	var size := virtual_size
	var width_m := 0.0
	var distance := ARC_RADIUS
	if monitor_id >= 0:
		var panel := _find_panel_for_monitor(monitor_id)
		if panel == null:
			ui_overlay.set_notice("Turn that screen on first.")
			return
		for m in available_monitors:
			if int(m.id) == monitor_id:
				size = Vector2i(m.width, m.height)
		width_m = panel.panel_width
		distance = (panel.global_position - _head()[0]).length()
	ui_overlay.open_virtual_page(monitor_id, size, width_m, distance, _headset_ppd())

func remove_virtual_screen(monitor_id: int) -> void:
	if current_state != State.CONNECTED and current_state != State.STREAMING:
		return
	network_client.send_virtual_display_remove(monitor_id)

func _on_virtual_display_result(status: int, removed: bool, monitor_id: int) -> void:
	if not _match.is_empty() and _match_step(status, monitor_id):
		return
	if status != 0:
		var why := {
			1: "This PC can't make virtual screens (it needs GNOME on Wayland, X11 or macOS).",
			2: "The PC could not add the screen; its window says why.",
			3: "That's as many virtual screens as a PC can have.",
		}
		if ui_overlay:
			ui_overlay.set_notice(why.get(status, "The virtual screen request failed."))
		return
	if ui_overlay:
		ui_overlay.set_notice("")
	if removed:
		_layouts.erase(monitor_id)  # a later screen with this id starts afresh
		_unsnap(monitor_id)
		return
	# Show it: at once if the new MONITOR_LIST is already here, else when it comes.
	_pending_virtual_id = monitor_id
	for m in available_monitors:
		if int(m.id) == monitor_id:
			_show_new_virtual_screen()
			return

## Replace a virtual screen by one of width x height pixels (0 x 0: sized
## 1:1 for where it hangs now). The new one takes the old one's place and
## width (rescaled for a new shape) when its stream starts.
func match_virtual_screen(monitor_id: int, width: int = 0, height: int = 0) -> void:
	if not _match.is_empty() or not ui_overlay:
		return
	var panel := _find_panel_for_monitor(monitor_id)
	if panel == null:
		ui_overlay.set_notice("Turn that screen on first.")
		return
	var aspect := float(panel.screen_width) / float(panel.screen_height)
	var size := Vector2i(width, height)
	var done := "Screen set to %d × %d."
	if width <= 0 or height <= 0:
		var head: Vector3 = _head()[0]
		size = VirtualSize.one_to_one(panel.panel_width, (panel.global_position - head).length(),
			aspect, _headset_ppd())
		done = "Screen set to %d × %d for this distance."
		if absf(panel.screen_width - size.x) <= 0.03 * size.x:
			ui_overlay.set_notice("Already sharp at %d × %d for this distance." % [panel.screen_width, panel.screen_height])
			return
	else:
		_remember_virtual_size(width, height)
	var layout: Dictionary = panel.get_layout_state()
	layout["panel_width"] = VirtualSize.replaced_width_m(panel.panel_width, aspect, float(size.x) / size.y)
	_match = {"old": monitor_id, "size": size, "layout": layout, "creating": false, "done": done}
	remove_virtual_screen(monitor_id)

## Next step of match_virtual_screen; true when the result was consumed.
func _match_step(status: int, monitor_id: int) -> bool:
	var size: Vector2i = _match["size"]
	if not _match["creating"]:
		if status != 0:
			_match.clear()
			ui_overlay.set_notice("The PC would not change that screen.")
			return true
		_match["creating"] = true
		_layouts.erase(_match["old"])
		network_client.send_virtual_display_create(size.x, size.y, 60)
		return true
	var layout: Dictionary = _match["layout"]
	var done: String = _match["done"]
	var old_id: int = _match["old"]
	_match.clear()
	if status != 0:
		_unsnap(old_id)
		return false  # normal error notice; the old screen is gone
	_layouts[monitor_id] = layout
	_rename_snaps(old_id, monitor_id)
	ui_overlay.set_notice(done % [size.x, size.y])
	_pending_virtual_id = monitor_id
	for m in available_monitors:
		if int(m.id) == monitor_id:
			_show_new_virtual_screen()
	return true

func _show_new_virtual_screen() -> void:
	var mid := _pending_virtual_id
	_pending_virtual_id = -1
	if active_monitor_ids.has(mid):
		return
	if active_monitor_ids.size() >= MAX_SCREENS:
		if ui_overlay:
			ui_overlay.set_notice("Screen added. Turn another one off to show it (three at a time).")
		_send_monitor_selection()
		return
	active_monitor_ids.append(mid)
	_update_overlay_monitors()
	_send_monitor_selection()
	_schedule_save()

## The PC ignores input (--view-only), or the user turned control off.
func _host_view_only() -> bool:
	return (_host_flags & 0x01) != 0

func _can_control() -> bool:
	return control_enabled and not _host_view_only()

# ---------------------------------------------------------------------------
# Callbacks — overlay signals
# ---------------------------------------------------------------------------

func _on_overlay_connect_requested(ip: String, tcp_port: int, udp_port: int) -> void:
	if ip.is_empty():
		disconnect_from_host()
		return
	if current_state != State.DISCONNECTED:
		disconnect_from_host()
	host_ip = ip
	host_tcp_port = tcp_port
	host_udp_port = udp_port
	_save_config()
	connect_to_host()

func _on_overlay_screen_curvature_changed(enabled: bool, amount: float) -> void:
	curved_screen_enabled = enabled
	curved_screen_amount = clamp(amount, 0.0, 1.0)
	_apply_visual_settings_to_all_panels()
	_save_config()

func _on_overlay_look_changed(new_look: String) -> void:
	passthrough_enabled = new_look == "passthrough"
	if not passthrough_enabled:
		look = new_look
		world.set_look(look)
	_apply_passthrough_settings()
	_save_config()

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

## Called from vr_input.gd and hand_input.gd — both of which call it once per
## rendered frame while pointing at a panel. Identical repeats are dropped here
## (one place, both callers). Button releases go out while merely CONNECTED
## too, so a button can never stay stuck down on the PC.
func send_mouse_input(monitor_id: int, x: int, y: int, buttons: int, scroll: int, scroll_h: int = 0) -> void:
	if not network_client or not _can_control():
		return
	if current_state != State.STREAMING and not (current_state == State.CONNECTED and buttons == 0):
		return
	if scroll == 0 and scroll_h == 0:
		var state := [monitor_id, x, y, buttons]
		if state == _last_mouse_state:
			return
		_last_mouse_state = state
	_last_pointed_monitor = monitor_id
	network_client.send_mouse_input(monitor_id, x, y, buttons, scroll, scroll_h)

func send_keyboard_input(monitor_id: int, scancode: int, pressed: bool, modifiers: int) -> void:
	if current_state == State.STREAMING and network_client and _can_control():
		network_client.send_keyboard_input(monitor_id, scancode, pressed, modifiers)

## Toggle overlay via controller button (called from vr_input.gd).
func toggle_ui_overlay() -> void:
	if ui_overlay:
		ui_overlay.toggle_visibility()

## Show/hide the in-VR keyboard (A/X, the menu, or K on desktop).
func toggle_virtual_keyboard() -> void:
	if not is_instance_valid(virtual_keyboard):
		return
	if not virtual_keyboard.visible and not _can_control() and current_state == State.STREAMING:
		if ui_overlay:
			ui_overlay.set_notice("Typing is off: this PC is view-only." if _host_view_only()
				else "Typing is off. Turn on \"Control this PC\" on the Connect tab.")
			_show_overlay()
		return
	virtual_keyboard.active_monitor_id = _keyboard_target()
	virtual_keyboard.toggle_visibility()

func is_virtual_keyboard_visible() -> bool:
	return is_instance_valid(virtual_keyboard) and virtual_keyboard.visible

## Monitor the keyboard types into: the one pointed at last, else the first.
func _keyboard_target() -> int:
	if active_monitor_ids.has(_last_pointed_monitor):
		return _last_pointed_monitor
	return active_monitor_ids[0] if not active_monitor_ids.is_empty() else 0

## Route a pointer ray at the VR keyboard. Returns the hit distance, or -1
## when the ray misses it (then it goes on to the screens). Shared by the
## controller (vr_input.gd) and hand-tracking (hand_input.gd) paths.
func send_keyboard_pointer(ray_origin: Vector3, ray_direction: Vector3, pressing: bool) -> float:
	if not is_instance_valid(virtual_keyboard) or not virtual_keyboard.visible:
		return -1.0
	virtual_keyboard.active_monitor_id = _keyboard_target()
	return virtual_keyboard.pointer_ray(ray_origin, ray_direction, pressing)

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	# On the headset a Bluetooth keyboard types straight into the PC. (On a PC
	# client the keyboard already belongs to a PC, and these are shortcuts.)
	# Auto-repeat (echo) goes through as more key-downs, as on Windows.
	if OS.has_feature("android"):
		var vk := KeyMap.to_vk(event.physical_keycode if event.physical_keycode else event.keycode)
		if vk > 0 and current_state == State.STREAMING:
			send_keyboard_input(_keyboard_target(), vk, event.pressed, 0)
			get_viewport().set_input_as_handled()
		return
	if not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_C:
			if current_state == State.DISCONNECTED:
				connect_to_host()
		KEY_D:
			disconnect_from_host()
		KEY_O:
			toggle_ui_overlay()
		KEY_K:
			toggle_virtual_keyboard()
		KEY_B:
			toggle_whiteboard()
		KEY_ESCAPE:
			get_tree().quit()

# ---------------------------------------------------------------------------
# Workspace persistence
# ---------------------------------------------------------------------------

func _schedule_save() -> void:
	if _save_timer and _save_timer.is_inside_tree():
		_save_timer.start(0.6)

func save_workspace_layout() -> void:
	_remember_layouts()
	if _ephemeral:
		return
	var panels := {}
	for mid in _layouts:
		panels[str(mid)] = _layouts[mid]
	var linked: Array = _linked.keys().filter(func(k): return _linked[k])
	var snapped := {}
	for c in _snapped_to:
		snapped[str(c)] = _snapped_to[c]
	var payload := {"version": 4, "monitor_ids": active_monitor_ids, "panels": panels,
		"linked": linked, "snapped": snapped}
	var file := FileAccess.open(WORKSPACE_PATH, FileAccess.WRITE)
	if not file:
		push_error("[Immersive-2] Failed to open workspace file for writing")
		return
	file.store_string(JSON.stringify(payload, "\t"))
	_workspace_monitor_ids = active_monitor_ids.duplicate()

## Kept for callers of the old API.
func restore_workspace_layout() -> void:
	recenter_workspace()

func _load_workspace() -> void:
	_layouts.clear()
	_workspace_monitor_ids.clear()
	_linked.clear()
	_snapped_to.clear()
	if not FileAccess.file_exists(WORKSPACE_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(WORKSPACE_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	# JSON numbers come back as floats: 1.0 != 1 for Array.has().
	for id in parsed.get("monitor_ids", []):
		_workspace_monitor_ids.append(int(id))
	for id in parsed.get("linked", []):  # version 3
		_linked[int(id)] = true
	var snapped = parsed.get("snapped", {})
	if typeof(snapped) == TYPE_DICTIONARY:  # version 4
		for key in snapped:
			if int(key) != int(snapped[key]):
				_snapped_to[int(key)] = int(snapped[key])
	var panels = parsed.get("panels", {})
	if typeof(panels) == TYPE_DICTIONARY:  # version 2
		for key in panels:
			_layouts[int(key)] = panels[key]
	elif typeof(panels) == TYPE_ARRAY:     # version 1: [{monitor_id, layout}]
		for item in panels:
			if typeof(item) == TYPE_DICTIONARY and int(item.get("monitor_id", -1)) >= 0:
				_layouts[int(item.monitor_id)] = item.get("layout", {})
	_layouts_from_disk = not _layouts.is_empty()

# ---------------------------------------------------------------------------
# Passthrough
# ---------------------------------------------------------------------------

func _is_passthrough_supported() -> bool:
	var interface := XRServer.get_primary_interface()
	if not interface or not interface.is_initialized():
		return false
	return XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in interface.get_supported_environment_blend_modes()

func _apply_passthrough_settings() -> void:
	var viewport := get_viewport()
	var interface := XRServer.get_primary_interface()
	var supported := _is_passthrough_supported()
	if passthrough_enabled and not supported:
		passthrough_enabled = false
		print("[Immersive-2] Passthrough is not supported by this OpenXR runtime")
	if interface and interface.is_initialized():
		var mode := XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND if passthrough_enabled \
			else XRInterface.XR_ENV_BLEND_MODE_OPAQUE
		if not interface.set_environment_blend_mode(mode) and passthrough_enabled:
			passthrough_enabled = false
			interface.set_environment_blend_mode(XRInterface.XR_ENV_BLEND_MODE_OPAQUE)
			print("[Immersive-2] Failed to enable passthrough, falling back to opaque mode")
	viewport.transparent_bg = passthrough_enabled
	if world:
		world.set_passthrough(passthrough_enabled)
	if ui_overlay:
		ui_overlay.set_look("passthrough" if passthrough_enabled else look, supported)

# ---------------------------------------------------------------------------
# Config persistence (this script is the only writer)
# ---------------------------------------------------------------------------

func _save_config() -> void:
	if _ephemeral:
		return
	# Load first: the [test] section is written externally over adb.
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	# The network address, not the cable's loopback: the next launch finds
	# the cable by itself, and needs the address when there is none.
	cfg.set_value("network", "host_ip", _lan_ip if _on_usb() and not _lan_ip.is_empty() else host_ip)
	cfg.set_value("network", "tcp_port", host_tcp_port)
	cfg.set_value("network", "udp_port", host_udp_port)
	cfg.set_value("network", "last_host_name", _last_host_name)
	cfg.set_value("network", "auto_connect", _auto_connect)
	var pins := _pins.duplicate()
	pins.erase("pending")
	cfg.set_value("pairing", "pins", pins)
	cfg.set_value("display", "curved_enabled", curved_screen_enabled)
	cfg.set_value("display", "curved_amount", curved_screen_amount)
	cfg.set_value("display", "passthrough_enabled", passthrough_enabled)
	cfg.set_value("display", "look", look)
	cfg.set_value("display", "compositor_layers", compositor_layers)
	cfg.set_value("input", "control", control_enabled)
	cfg.set_value("input", "haptics", haptics_enabled)
	cfg.set_value("layout", "snap", snap_enabled)
	cfg.set_value("layout", "lock", lock_layout)
	cfg.set_value("input", "pointer_hand", pointer_hand)
	cfg.set_value("input", "ray_angle", ray_angle_deg)
	cfg.set_value("input", "face_me_moving", screens_face_me)
	cfg.set_value("stream", "codec", stream_codec)
	cfg.set_value("stream", "bitrate_kbps", stream_bitrate_kbps)
	cfg.set_value("stream", "jpeg_quality", stream_jpeg_quality)
	cfg.set_value("stream", "res_percent", stream_res_percent)
	cfg.set_value("stream", "fps", stream_fps)
	cfg.set_value("virtual", "width", virtual_size.x)
	cfg.set_value("virtual", "height", virtual_size.y)
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
		host_ip       = cfg.get_value("network", "host_ip", "")
		if not host_ip.begins_with("127."):
			_lan_ip = host_ip
		host_tcp_port = cfg.get_value("network", "tcp_port", 19800)
		host_udp_port = cfg.get_value("network", "udp_port", 19801)
		_last_host_name = cfg.get_value("network", "last_host_name", "")
		_auto_connect = cfg.get_value("network", "auto_connect", false)
		_pins = cfg.get_value("pairing", "pins", {})
		curved_screen_enabled = cfg.get_value("display", "curved_enabled", true)
		# Curvature used to be a 0-0.5 texture warp; it is now 0-1 of a real arc.
		curved_screen_amount = clamp(float(cfg.get_value("display", "curved_amount", 0.5)), 0.0, 1.0)
		passthrough_enabled = cfg.get_value("display", "passthrough_enabled", false)
		look = cfg.get_value("display", "look", "night")
		compositor_layers = cfg.get_value("display", "compositor_layers", false)
		control_enabled = cfg.get_value("input", "control", true)
		haptics_enabled = cfg.get_value("input", "haptics", true)
		snap_enabled = cfg.get_value("layout", "snap", true)
		lock_layout = cfg.get_value("layout", "lock", false)
		pointer_hand = "left" if cfg.get_value("input", "pointer_hand", "right") == "left" else "right"
		ray_angle_deg = clampf(float(cfg.get_value("input", "ray_angle", 40.0)), 0.0, 60.0)
		screens_face_me = cfg.get_value("input", "face_me_moving", false)
		LaserDrag.face_me = screens_face_me
		stream_codec = _resolve_codec(cfg.get_value("stream", "codec", stream_codec))
		stream_bitrate_kbps = cfg.get_value("stream", "bitrate_kbps", 20000)
		stream_jpeg_quality = cfg.get_value("stream", "jpeg_quality", 70)
		stream_res_percent = cfg.get_value("stream", "res_percent", 100)
		stream_fps = cfg.get_value("stream", "fps", 0)
		virtual_size = Vector2i(cfg.get_value("virtual", "width", 1920), cfg.get_value("virtual", "height", 1080))
		# Test harness (see _autoconnect_on_start docs). Writable over adb run-as.
		_autoconnect_on_start = cfg.get_value("test", "autoconnect", false)
		_debug_capture = cfg.get_value("test", "debug_capture", false)

	_apply_cmdline_overrides()

## Test-harness arguments. On a PC pass them after `--`. On Android the
## launcher drops intent extras, so bake them into a test APK with the export
## option command_line/extra_args="--im2-host=192.168.1.34 --im2-capture"
## (and reinstall the normal APK afterwards).
## Recognised: --im2-host=IP, --im2-port=N, --im2-udp-port=N, --im2-codec=N, --im2-capture,
## --im2-usb (video/audio over TCP, as over a USB cable),
## --im2-usb-port=N (the USB tunnel is 127.0.0.1:N: automatic USB on desktop),
## --im2-monitors=0,1,2 (monitors to stream once connected),
## --im2-pin=NNNNNN (pairing PIN for that host),
## --im2-virtual=WxH (ask the host for a virtual screen once connected).
func _apply_cmdline_overrides() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	var pin := 0
	for arg in args:
		if arg.begins_with("--im2-host="):
			host_ip = arg.get_slice("=", 1)
			_lan_ip = "" if host_ip.begins_with("127.") else host_ip
			_autoconnect_on_start = true
			_ephemeral = true
		elif arg.begins_with("--im2-port="):
			host_tcp_port = int(arg.get_slice("=", 1))
		elif arg.begins_with("--im2-udp-port="):
			host_udp_port = int(arg.get_slice("=", 1))
		elif arg.begins_with("--im2-codec="):
			stream_codec = _resolve_codec(int(arg.get_slice("=", 1)))
		elif arg == "--im2-usb":
			_force_tcp_media = true
		elif arg.begins_with("--im2-usb-port="):
			_usb_port = int(arg.get_slice("=", 1))
		elif arg == "--im2-capture":
			_debug_capture = true
		elif arg.begins_with("--im2-monitors="):
			_cmdline_monitors = Array(arg.get_slice("=", 1).split_floats(",")).map(func(v): return int(v))
		elif arg.begins_with("--im2-pin="):
			pin = int(arg.get_slice("=", 1))
		elif arg.begins_with("--im2-virtual="):
			var wh := arg.get_slice("=", 1).split("x")
			if wh.size() == 2:
				_cmdline_virtual = Vector2i(int(wh[0]), int(wh[1]))
	if pin > 0:
		_pins["ip:" + host_ip] = pin
