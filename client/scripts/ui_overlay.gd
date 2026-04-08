## VR UI Overlay for Immersive-2.
##
## Displays connection status, host IP input, monitor selection, and latency.
## Rendered as a floating SubViewport panel in 3D space (attached to XROrigin3D).
##
## Usage:
##   - Add a Node3D child with a MeshInstance3D (PlaneMesh) + SubViewport
##   - Attach this script to the root Node3D
##   - Connect the signals from main.gd to update state

extends Node3D

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted when the user presses the Connect button.
signal connect_requested(ip: String, tcp_port: int, udp_port: int)
## Emitted when the user selects a monitor from the list.
signal monitor_selected(monitor_id: int)
## Emitted when the user requests to add a second or third screen panel.
signal add_screen_panel(monitor_id: int, slot: int)
## Emitted when curved display mode settings change.
signal screen_curvature_changed(enabled: bool, amount: float)

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

@export var panel_distance: float = 1.0    ## Meters in front of the camera
@export var panel_width: float    = 0.8    ## Panel width in meters
@export var panel_height: float   = 0.5    ## Panel height in meters

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

enum ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, STREAMING }

var _state: ConnectionState = ConnectionState.DISCONNECTED
var _ping_ms: float = 0.0
var _available_monitors: Array = []
var _host_ip: String = "192.168.1.100"
var _tcp_port: int = 19800
var _udp_port: int = 19801
var _visible_overlay: bool = false
var _curved_enabled: bool = false
var _curvature_amount: float = 0.18

# Config file path
const CONFIG_PATH := "user://immersive2_config.cfg"

# ---------------------------------------------------------------------------
# Internal node references (created dynamically)
# ---------------------------------------------------------------------------
var _viewport: SubViewport
var _panel_mesh: MeshInstance3D
var _canvas: CanvasLayer        # inside SubViewport

# UI controls (Control nodes inside the SubViewport)
var _lbl_status: Label
var _lbl_ping: Label
var _input_ip: LineEdit
var _btn_connect: Button
var _monitor_list: VBoxContainer
var _lbl_title: Label
var _chk_curved: CheckBox
var _slider_curvature: HSlider
var _lbl_curvature_value: Label

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_load_config()
	_build_ui()
	set_process(true)
	hide()   # start hidden; shown by toggle_visibility()

func _process(_delta: float) -> void:
	_update_labels()

# ---------------------------------------------------------------------------
# Public API — called from main.gd
# ---------------------------------------------------------------------------

## Show or hide the overlay panel (called when user presses B/Y button).
func toggle_visibility() -> void:
	_visible_overlay = !_visible_overlay
	if _visible_overlay:
		show()
		_reposition_in_front_of_camera()
	else:
		hide()

## Update the displayed connection state.
func set_state(state: ConnectionState) -> void:
	_state = state
	_update_labels()
	if state == ConnectionState.DISCONNECTED:
		_btn_connect.text = "Connect"
		_btn_connect.disabled = false
	elif state == ConnectionState.CONNECTING:
		_btn_connect.text = "Connecting..."
		_btn_connect.disabled = true
	elif state == ConnectionState.CONNECTED or state == ConnectionState.STREAMING:
		_btn_connect.text = "Disconnect"
		_btn_connect.disabled = false

## Update the monitor list.
func set_monitor_list(monitors: Array) -> void:
	_available_monitors = monitors
	_rebuild_monitor_list()

## Update the displayed latency value (in milliseconds).
func set_latency(ms: float) -> void:
	_ping_ms = ms

func set_screen_curvature(enabled: bool, amount: float) -> void:
	_curved_enabled = enabled
	_curvature_amount = clamp(amount, 0.0, 0.5)
	_update_curvature_ui()

# ---------------------------------------------------------------------------
# Internal — UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	# --- SubViewport ---
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(800, 500)
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	# --- Canvas inside viewport ---
	_canvas = CanvasLayer.new()
	_viewport.add_child(_canvas)

	# --- Root panel ---
	var root_panel := PanelContainer.new()
	root_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(root_panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_panel.add_child(vbox)

	# Title
	_lbl_title = Label.new()
	_lbl_title.text = "Immersive-2 VR Client"
	_lbl_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lbl_title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(_lbl_title)

	# Separator
	vbox.add_child(HSeparator.new())

	# Status row
	var status_row := HBoxContainer.new()
	vbox.add_child(status_row)
	var status_lbl_title := Label.new()
	status_lbl_title.text = "Status: "
	status_row.add_child(status_lbl_title)
	_lbl_status = Label.new()
	_lbl_status.text = "Disconnected"
	status_row.add_child(_lbl_status)

	# Ping row
	var ping_row := HBoxContainer.new()
	vbox.add_child(ping_row)
	var ping_lbl_title := Label.new()
	ping_lbl_title.text = "Latency: "
	ping_row.add_child(ping_lbl_title)
	_lbl_ping = Label.new()
	_lbl_ping.text = "-- ms"
	ping_row.add_child(_lbl_ping)

	# IP input row
	var ip_row := HBoxContainer.new()
	vbox.add_child(ip_row)
	var ip_lbl := Label.new()
	ip_lbl.text = "Host IP: "
	ip_row.add_child(ip_lbl)
	_input_ip = LineEdit.new()
	_input_ip.text = _host_ip
	_input_ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_ip.placeholder_text = "192.168.1.100"
	ip_row.add_child(_input_ip)

	# Connect button
	_btn_connect = Button.new()
	_btn_connect.text = "Connect"
	_btn_connect.pressed.connect(_on_connect_pressed)
	vbox.add_child(_btn_connect)

	# Display controls
	vbox.add_child(HSeparator.new())
	var curved_row := HBoxContainer.new()
	vbox.add_child(curved_row)
	_chk_curved = CheckBox.new()
	_chk_curved.text = "Curved screen mode"
	_chk_curved.button_pressed = _curved_enabled
	_chk_curved.toggled.connect(_on_curved_toggled)
	curved_row.add_child(_chk_curved)

	var curvature_row := HBoxContainer.new()
	vbox.add_child(curvature_row)
	var curvature_lbl := Label.new()
	curvature_lbl.text = "Curve strength"
	curvature_row.add_child(curvature_lbl)
	_slider_curvature = HSlider.new()
	_slider_curvature.min_value = 0.0
	_slider_curvature.max_value = 0.5
	_slider_curvature.step = 0.01
	_slider_curvature.value = _curvature_amount
	_slider_curvature.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider_curvature.value_changed.connect(_on_curvature_value_changed)
	curvature_row.add_child(_slider_curvature)
	_lbl_curvature_value = Label.new()
	_lbl_curvature_value.text = "%.2f" % _curvature_amount
	curvature_row.add_child(_lbl_curvature_value)
	_update_curvature_ui()

	# Separator
	vbox.add_child(HSeparator.new())

	# Monitor list label
	var mon_lbl := Label.new()
	mon_lbl.text = "Available Monitors:"
	vbox.add_child(mon_lbl)

	# Scrollable monitor list
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_monitor_list = VBoxContainer.new()
	_monitor_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_monitor_list)

	# --- 3D mesh panel to display the viewport ---
	_panel_mesh = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(panel_width, panel_height)
	plane.orientation = PlaneMesh.FACE_Z
	_panel_mesh.mesh = plane

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _viewport.get_texture()
	mat.flags_transparent = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_panel_mesh.material_override = mat
	add_child(_panel_mesh)

func _rebuild_monitor_list() -> void:
	# Clear existing buttons
	for child in _monitor_list.get_children():
		child.queue_free()

	for mon in _available_monitors:
		var btn := Button.new()
		btn.text = "[%d] %s  %dx%d @ %d Hz" % [
			mon.get("id", 0),
			mon.get("name", "Monitor"),
			mon.get("width", 0),
			mon.get("height", 0),
			mon.get("refresh_rate", 60)
		]
		var mon_id: int = mon.get("id", 0)
		btn.pressed.connect(func(): _on_monitor_selected(mon_id))
		_monitor_list.add_child(btn)

func _update_labels() -> void:
	var state_text: String
	var state_color: Color
	match _state:
		ConnectionState.DISCONNECTED:
			state_text = "Disconnected"
			state_color = Color(0.8, 0.3, 0.3)
		ConnectionState.CONNECTING:
			state_text = "Connecting..."
			state_color = Color(0.9, 0.7, 0.2)
		ConnectionState.CONNECTED:
			state_text = "Connected"
			state_color = Color(0.3, 0.8, 0.3)
		ConnectionState.STREAMING:
			state_text = "Streaming"
			state_color = Color(0.2, 0.6, 1.0)
		_:
			state_text = "Unknown"
			state_color = Color.WHITE

	if _lbl_status:
		_lbl_status.text = state_text
		_lbl_status.modulate = state_color

	if _lbl_ping:
		if _ping_ms > 0.0:
			var color := Color(0.3, 0.8, 0.3)
			if _ping_ms > 30.0:
				color = Color(0.9, 0.7, 0.2)
			if _ping_ms > 60.0:
				color = Color(0.8, 0.3, 0.3)
			_lbl_ping.text = "%.1f ms" % _ping_ms
			_lbl_ping.modulate = color
		else:
			_lbl_ping.text = "-- ms"
			_lbl_ping.modulate = Color.WHITE

func _reposition_in_front_of_camera() -> void:
	# Find the XRCamera3D to position the overlay in view
	var camera := get_viewport().get_camera_3d()
	if camera:
		var forward: Vector3 = -camera.global_transform.basis.z
		global_transform.origin = camera.global_transform.origin + forward * panel_distance
		global_transform.basis = camera.global_transform.basis

# ---------------------------------------------------------------------------
# Button callbacks
# ---------------------------------------------------------------------------

func _on_connect_pressed() -> void:
	if _state == ConnectionState.DISCONNECTED:
		_host_ip = _input_ip.text.strip_edges()
		if _host_ip.is_empty():
			_host_ip = "192.168.1.100"
		_save_config()
		connect_requested.emit(_host_ip, _tcp_port, _udp_port)
	else:
		# Disconnect
		connect_requested.emit("", 0, 0)

func _on_monitor_selected(monitor_id: int) -> void:
	monitor_selected.emit(monitor_id)
	hide()
	_visible_overlay = false

func _on_curved_toggled(enabled: bool) -> void:
	_curved_enabled = enabled
	_update_curvature_ui()
	_save_config()
	screen_curvature_changed.emit(_curved_enabled, _curvature_amount)

func _on_curvature_value_changed(value: float) -> void:
	_curvature_amount = clamp(value, 0.0, 0.5)
	_update_curvature_ui()
	_save_config()
	screen_curvature_changed.emit(_curved_enabled, _curvature_amount)

func _update_curvature_ui() -> void:
	if _chk_curved:
		_chk_curved.button_pressed = _curved_enabled
	if _slider_curvature:
		_slider_curvature.value = _curvature_amount
		_slider_curvature.editable = _curved_enabled
	if _lbl_curvature_value:
		_lbl_curvature_value.text = "%.2f" % _curvature_amount

# ---------------------------------------------------------------------------
# Config persistence
# ---------------------------------------------------------------------------

func _save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("network", "host_ip", _host_ip)
	cfg.set_value("network", "tcp_port", _tcp_port)
	cfg.set_value("network", "udp_port", _udp_port)
	cfg.set_value("display", "curved_enabled", _curved_enabled)
	cfg.set_value("display", "curved_amount", _curvature_amount)
	cfg.save(CONFIG_PATH)

func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		_host_ip = cfg.get_value("network", "host_ip", "192.168.1.100")
		_tcp_port = cfg.get_value("network", "tcp_port", 19800)
		_udp_port = cfg.get_value("network", "udp_port", 19801)
		_curved_enabled = cfg.get_value("display", "curved_enabled", false)
		_curvature_amount = cfg.get_value("display", "curved_amount", 0.18)
