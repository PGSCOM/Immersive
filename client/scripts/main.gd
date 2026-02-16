## Main scene controller.
## Initializes XR, manages network connection, and coordinates
## screen streaming between components.

extends Node3D

## Network client for communicating with the Windows host.
var network_client: Node
## The screen panel that displays the streamed desktop.
@onready var screen_panel: MeshInstance3D = $ScreenPanel

## Host IP address (configurable in settings).
@export var host_ip: String = "192.168.1.100"
## Host TCP port.
@export var host_tcp_port: int = 19800
## Host UDP port.
@export var host_udp_port: int = 19801

## XR interface reference.
var xr_interface: XRInterface

## Connection state.
enum State { DISCONNECTED, CONNECTING, CONNECTED, STREAMING }
var current_state: State = State.DISCONNECTED

## Available monitors from the host.
var available_monitors: Array = []

func _ready() -> void:
	_init_xr()
	_init_network()
	print("[Immersive-2] VR Client started")

func _init_xr() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		print("[Immersive-2] OpenXR initialized")
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		get_viewport().use_xr = true
	else:
		print("[Immersive-2] OpenXR not available, running in desktop mode")

func _init_network() -> void:
	network_client = preload("res://scripts/network_client.gd").new()
	network_client.name = "NetworkClient"
	add_child(network_client)

	# Connect signals
	network_client.connected_to_host.connect(_on_connected)
	network_client.disconnected_from_host.connect(_on_disconnected)
	network_client.monitor_list_received.connect(_on_monitor_list)
	network_client.stream_started.connect(_on_stream_started)
	network_client.video_frame_received.connect(_on_video_frame)

func _process(_delta: float) -> void:
	pass

## Connect to the host PC.
func connect_to_host() -> void:
	if current_state != State.DISCONNECTED:
		return
	current_state = State.CONNECTING
	print("[Immersive-2] Connecting to %s:%d..." % [host_ip, host_tcp_port])
	network_client.connect_to_server(host_ip, host_tcp_port, host_udp_port)

## Select a monitor to stream.
func select_monitor(monitor_id: int) -> void:
	if current_state != State.CONNECTED:
		return
	print("[Immersive-2] Selecting monitor %d" % monitor_id)
	network_client.select_monitor(monitor_id)

## Callback: connected to host.
func _on_connected() -> void:
	current_state = State.CONNECTED
	print("[Immersive-2] Connected to host")

## Callback: disconnected from host.
func _on_disconnected() -> void:
	current_state = State.DISCONNECTED
	print("[Immersive-2] Disconnected from host")

## Callback: received monitor list from host.
func _on_monitor_list(monitors: Array) -> void:
	available_monitors = monitors
	print("[Immersive-2] Available monitors: %d" % monitors.size())
	for m in monitors:
		print("  [%d] %s (%dx%d)" % [m.id, m.name, m.width, m.height])

	# Auto-select the first monitor for MVP
	if monitors.size() > 0:
		select_monitor(monitors[0].id)

## Callback: stream started.
func _on_stream_started(monitor_id: int, width: int, height: int) -> void:
	current_state = State.STREAMING
	print("[Immersive-2] Streaming monitor %d (%dx%d)" % [monitor_id, width, height])

	# Update screen panel aspect ratio
	if screen_panel and screen_panel.has_method("set_resolution"):
		screen_panel.set_resolution(width, height)

## Callback: video frame received.
func _on_video_frame(frame_data: PackedByteArray, width: int, height: int) -> void:
	if screen_panel and screen_panel.has_method("update_texture"):
		screen_panel.update_texture(frame_data, width, height)

## Input handling - called from vr_input.gd.
func send_mouse_input(monitor_id: int, x: int, y: int, buttons: int, scroll: int) -> void:
	if current_state == State.STREAMING and network_client:
		network_client.send_mouse_input(monitor_id, x, y, buttons, scroll)

func send_keyboard_input(monitor_id: int, scancode: int, pressed: bool, modifiers: int) -> void:
	if current_state == State.STREAMING and network_client:
		network_client.send_keyboard_input(monitor_id, scancode, pressed, modifiers)

## Auto-connect on start (for development).
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_C:
			connect_to_host()
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()
