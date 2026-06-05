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
## Emitted when foveated rendering settings change.
signal foveation_settings_changed(enabled: bool, strength: float)
## Emitted when passthrough mode is toggled.
signal passthrough_toggled(enabled: bool)
## Emitted when workspace save is requested.
signal workspace_save_requested
## Emitted when workspace restore is requested.
signal workspace_restore_requested

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

@export var panel_distance: float = 1.0    ## Meters in front of the camera
@export var panel_width: float    = 1.0    ## Panel width in meters
@export var panel_height: float   = 0.65   ## Panel height in meters
const RAY_DIRECTION_EPSILON := 0.0001
const MIN_SCROLL_DELTA := 0.1

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
var _foveation_enabled: bool = false
var _foveation_strength: float = 0.55
var _passthrough_enabled: bool = false
var _passthrough_supported: bool = true

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
var _lbl_dot: Label
var _lbl_ping: Label
var _input_ip: LineEdit
var _input_tcp: LineEdit
var _input_udp: LineEdit
var _btn_connect: Button
var _monitor_list: VBoxContainer
var _lbl_title: Label
var _chk_curved: CheckBox
var _slider_curvature: HSlider
var _lbl_curvature_value: Label
var _chk_foveation: CheckBox
var _slider_foveation: HSlider
var _lbl_foveation_value: Label
var _chk_passthrough: CheckBox
var _btn_workspace_save: Button
var _btn_workspace_restore: Button
var _ui_pointer_pos: Vector2 = Vector2.ZERO
var _ui_pointer_valid: bool = false
var _ui_button_mask: int = 0

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
		_ui_button_mask = 0
		_ui_pointer_valid = false
		_ui_pointer_pos = Vector2.ZERO
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

func set_foveation_settings(enabled: bool, strength: float) -> void:
	_foveation_enabled = enabled
	_foveation_strength = clamp(strength, 0.0, 1.0)
	_update_foveation_ui()

func set_passthrough_settings(enabled: bool, supported: bool = true) -> void:
	_passthrough_enabled = enabled
	_passthrough_supported = supported
	_update_passthrough_ui()

# ---------------------------------------------------------------------------
# Internal — UI construction
# ---------------------------------------------------------------------------

func _make_section(parent: VBoxContainer, title: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.14, 0.7)
	style.set_corner_radius_all(4)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	var header := Label.new()
	header.text = title
	header.add_theme_font_size_override("font_size", 18)
	header.add_theme_color_override("font_color", Color(0.6, 0.7, 0.9))
	vbox.add_child(header)

	return vbox

func _build_ui() -> void:
	var accent_color := Color(0.3, 0.6, 1.0)

	# --- SubViewport ---
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1000, 620)
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.gui_embed_subwindows = true
	add_child(_viewport)

	# --- Canvas inside viewport ---
	_canvas = CanvasLayer.new()
	_viewport.add_child(_canvas)

	# --- Root panel ---
	var root_panel := PanelContainer.new()
	root_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var root_bg := StyleBoxFlat.new()
	root_bg.bg_color = Color(0.03, 0.05, 0.1, 0.92)
	root_bg.set_corner_radius_all(6)
	root_bg.content_margin_left = 12
	root_bg.content_margin_right = 12
	root_bg.content_margin_top = 8
	root_bg.content_margin_bottom = 8
	root_panel.add_theme_stylebox_override("panel", root_bg)
	_canvas.add_child(root_panel)

	var outer_vbox := VBoxContainer.new()
	outer_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_panel.add_child(outer_vbox)

	# Title
	_lbl_title = Label.new()
	_lbl_title.text = "Immersive-2 VR Client"
	_lbl_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lbl_title.add_theme_font_size_override("font_size", 28)
	_lbl_title.add_theme_color_override("font_color", accent_color)
	outer_vbox.add_child(_lbl_title)

	# === CONEXIÓN Section ===
	var conn_box := _make_section(outer_vbox, "Conexión")

	var status_row := HBoxContainer.new()
	conn_box.add_child(status_row)
	_lbl_dot = Label.new()
	_lbl_dot.text = "●"
	_lbl_dot.add_theme_color_override("font_color", Color(0.8, 0.3, 0.3))
	_lbl_dot.add_theme_font_size_override("font_size", 16)
	_lbl_dot.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_row.add_child(_lbl_dot)
	var status_lbl_title := Label.new()
	status_lbl_title.text = " Status: "
	status_row.add_child(status_lbl_title)
	_lbl_status = Label.new()
	_lbl_status.text = "Disconnected"
	_lbl_status.add_theme_color_override("font_color", Color(0.8, 0.3, 0.3))
	status_row.add_child(_lbl_status)

	var ping_row := HBoxContainer.new()
	conn_box.add_child(ping_row)
	var ping_lbl_title := Label.new()
	ping_lbl_title.text = "Latency: "
	ping_row.add_child(ping_lbl_title)
	_lbl_ping = Label.new()
	_lbl_ping.text = "-- ms"
	ping_row.add_child(_lbl_ping)

	var ip_row := HBoxContainer.new()
	conn_box.add_child(ip_row)
	var ip_lbl := Label.new()
	ip_lbl.text = "Host IP: "
	ip_row.add_child(ip_lbl)
	_input_ip = LineEdit.new()
	_input_ip.text = _host_ip
	_input_ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_ip.placeholder_text = "192.168.1.100"
	ip_row.add_child(_input_ip)

	var tcp_row := HBoxContainer.new()
	conn_box.add_child(tcp_row)
	var tcp_lbl := Label.new()
	tcp_lbl.text = "TCP port: "
	tcp_row.add_child(tcp_lbl)
	_input_tcp = LineEdit.new()
	_input_tcp.text = str(_tcp_port)
	_input_tcp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_tcp.placeholder_text = "19800"
	tcp_row.add_child(_input_tcp)

	var udp_row := HBoxContainer.new()
	conn_box.add_child(udp_row)
	var udp_lbl := Label.new()
	udp_lbl.text = "UDP port: "
	udp_row.add_child(udp_lbl)
	_input_udp = LineEdit.new()
	_input_udp.text = str(_udp_port)
	_input_udp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_udp.placeholder_text = "19801"
	udp_row.add_child(_input_udp)

	_btn_connect = Button.new()
	_btn_connect.text = "Connect"
	_btn_connect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_connect.pressed.connect(_on_connect_pressed)
	var btn_green := StyleBoxFlat.new()
	btn_green.bg_color = Color(0.15, 0.5, 0.2)
	btn_green.set_corner_radius_all(4)
	btn_green.content_margin_left = 8
	btn_green.content_margin_right = 8
	btn_green.content_margin_top = 4
	btn_green.content_margin_bottom = 4
	_btn_connect.add_theme_stylebox_override("normal", btn_green)
	var btn_green_hover := StyleBoxFlat.new()
	btn_green_hover.bg_color = Color(0.2, 0.6, 0.25)
	btn_green_hover.set_corner_radius_all(4)
	btn_green_hover.content_margin_left = 8
	btn_green_hover.content_margin_right = 8
	btn_green_hover.content_margin_top = 4
	btn_green_hover.content_margin_bottom = 4
	_btn_connect.add_theme_stylebox_override("hover", btn_green_hover)
	_btn_connect.add_theme_color_override("font_color", Color(0.9, 0.95, 0.9))
	_btn_connect.add_theme_font_size_override("font_size", 20)
	conn_box.add_child(_btn_connect)

	# === DISPLAY Section ===
	var disp_box := _make_section(outer_vbox, "Display")

	var curved_row := HBoxContainer.new()
	disp_box.add_child(curved_row)
	_chk_curved = CheckBox.new()
	_chk_curved.text = "Curved screen mode"
	_chk_curved.button_pressed = _curved_enabled
	_chk_curved.toggled.connect(_on_curved_toggled)
	curved_row.add_child(_chk_curved)

	var curvature_row := HBoxContainer.new()
	disp_box.add_child(curvature_row)
	var curvature_lbl := Label.new()
	curvature_lbl.text = "Curve: "
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
	_lbl_curvature_value.add_theme_font_size_override("font_size", 16)
	curvature_row.add_child(_lbl_curvature_value)
	_update_curvature_ui()

	var foveation_row := HBoxContainer.new()
	disp_box.add_child(foveation_row)
	_chk_foveation = CheckBox.new()
	_chk_foveation.text = "Foveated rendering"
	_chk_foveation.button_pressed = _foveation_enabled
	_chk_foveation.toggled.connect(_on_foveation_toggled)
	foveation_row.add_child(_chk_foveation)

	var foveation_strength_row := HBoxContainer.new()
	disp_box.add_child(foveation_strength_row)
	var foveation_lbl := Label.new()
	foveation_lbl.text = "Strength: "
	foveation_strength_row.add_child(foveation_lbl)
	_slider_foveation = HSlider.new()
	_slider_foveation.min_value = 0.0
	_slider_foveation.max_value = 1.0
	_slider_foveation.step = 0.01
	_slider_foveation.value = _foveation_strength
	_slider_foveation.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider_foveation.value_changed.connect(_on_foveation_strength_changed)
	foveation_strength_row.add_child(_slider_foveation)
	_lbl_foveation_value = Label.new()
	_lbl_foveation_value.text = "%.2f" % _foveation_strength
	_lbl_foveation_value.add_theme_font_size_override("font_size", 16)
	foveation_strength_row.add_child(_lbl_foveation_value)
	_update_foveation_ui()

	var passthrough_row := HBoxContainer.new()
	disp_box.add_child(passthrough_row)
	_chk_passthrough = CheckBox.new()
	_chk_passthrough.text = "Passthrough (mixed reality)"
	_chk_passthrough.button_pressed = _passthrough_enabled
	_chk_passthrough.toggled.connect(_on_passthrough_toggled)
	passthrough_row.add_child(_chk_passthrough)
	_update_passthrough_ui()

	# === WORKSPACE Section ===
	var ws_box := _make_section(outer_vbox, "Workspace")

	var workspace_row := HBoxContainer.new()
	ws_box.add_child(workspace_row)
	_btn_workspace_save = Button.new()
	_btn_workspace_save.text = "Save"
	_btn_workspace_save.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_workspace_save.pressed.connect(_on_workspace_save_pressed)
	workspace_row.add_child(_btn_workspace_save)
	_btn_workspace_restore = Button.new()
	_btn_workspace_restore.text = "Restore"
	_btn_workspace_restore.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_workspace_restore.pressed.connect(_on_workspace_restore_pressed)
	workspace_row.add_child(_btn_workspace_restore)

	# === MONITORS Section ===
	var mon_box := _make_section(outer_vbox, "Monitores")

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mon_box.add_child(scroll)

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
		_lbl_status.add_theme_color_override("font_color", state_color)
	if _lbl_dot:
		_lbl_dot.add_theme_color_override("font_color", state_color)

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
	if camera == null:
		camera = get_node_or_null("/root/Main/XROrigin3D/XRCamera3D")
	if camera == null:
		return

	var forward: Vector3 = -camera.global_transform.basis.z
	global_transform.origin = camera.global_transform.origin + forward * panel_distance
	global_transform.basis = camera.global_transform.basis

func ray_to_overlay_hit(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	if not _visible_overlay or not is_instance_valid(_panel_mesh):
		return {"valid": false}

	var local_origin: Vector3 = _panel_mesh.global_transform.affine_inverse() * ray_origin
	var local_dir: Vector3 = _panel_mesh.global_transform.basis.inverse() * ray_direction
	if abs(local_dir.z) < RAY_DIRECTION_EPSILON:
		return {"valid": false}

	var t: float = -local_origin.z / local_dir.z
	if t < 0.0:
		return {"valid": false}

	var local_hit: Vector3 = local_origin + local_dir * t
	var u: float = (local_hit.x / panel_width) + 0.5
	var v: float = 0.5 - (local_hit.y / panel_height)
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return {"valid": false}

	return {
		"valid": true,
		"uv": Vector2(u, v),
		"distance": t
	}

func inject_pointer_move(uv: Vector2) -> void:
	if not is_instance_valid(_viewport):
		return
	var pos := _uv_to_viewport_pos(uv)
	var prev_pos := _ui_pointer_pos if _ui_pointer_valid else pos

	var event := InputEventMouseMotion.new()
	event.position = pos
	event.global_position = pos
	event.relative = pos - prev_pos
	event.button_mask = _ui_button_mask
	event.pressure = 1.0 if _ui_button_mask != 0 else 0.0
	_viewport.push_input(event)

	_ui_pointer_pos = pos
	_ui_pointer_valid = true

func inject_pointer_button(pressed: bool, button_index: int = MOUSE_BUTTON_LEFT) -> void:
	if not is_instance_valid(_viewport):
		return
	if not _ui_pointer_valid:
		return

	var mask := _button_index_to_mask(button_index)
	if pressed:
		_ui_button_mask |= mask
	else:
		_ui_button_mask &= ~mask

	var event := InputEventMouseButton.new()
	event.position = _ui_pointer_pos
	event.global_position = _ui_pointer_pos
	event.button_index = button_index
	event.pressed = pressed
	event.button_mask = _ui_button_mask
	_viewport.push_input(event)

func inject_pointer_scroll(delta_y: float) -> void:
	if not is_instance_valid(_viewport):
		return
	if not _ui_pointer_valid:
		return
	if abs(delta_y) < MIN_SCROLL_DELTA:
		return

	var button_index := MOUSE_BUTTON_WHEEL_DOWN if delta_y > 0.0 else MOUSE_BUTTON_WHEEL_UP
	var down := InputEventMouseButton.new()
	down.position = _ui_pointer_pos
	down.global_position = _ui_pointer_pos
	down.button_index = button_index
	down.pressed = true
	down.button_mask = _ui_button_mask
	_viewport.push_input(down)

	var up := InputEventMouseButton.new()
	up.position = _ui_pointer_pos
	up.global_position = _ui_pointer_pos
	up.button_index = button_index
	up.pressed = false
	up.button_mask = _ui_button_mask
	_viewport.push_input(up)

func _uv_to_viewport_pos(uv: Vector2) -> Vector2:
	if not is_instance_valid(_viewport):
		return Vector2.ZERO
	var size := Vector2(_viewport.size)
	return Vector2(
		clampf(uv.x, 0.0, 1.0) * max(size.x - 1.0, 0.0),
		clampf(uv.y, 0.0, 1.0) * max(size.y - 1.0, 0.0)
	)

func _button_index_to_mask(button_index: int) -> int:
	if button_index <= 0:
		return 0
	return 1 << (button_index - 1)

# ---------------------------------------------------------------------------
# Button callbacks
# ---------------------------------------------------------------------------

func _on_connect_pressed() -> void:
	if _state == ConnectionState.DISCONNECTED:
		_host_ip = _input_ip.text.strip_edges()
		if _host_ip.is_empty():
			_host_ip = "192.168.1.100"
		_tcp_port = _input_tcp.text.to_int()
		_udp_port = _input_udp.text.to_int()
		if _tcp_port <= 0:
			_tcp_port = 19800
		if _udp_port <= 0:
			_udp_port = 19801
		_save_config()
		connect_requested.emit(_host_ip, _tcp_port, _udp_port)
	else:
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

func _on_foveation_toggled(enabled: bool) -> void:
	_foveation_enabled = enabled
	_update_foveation_ui()
	_save_config()
	foveation_settings_changed.emit(_foveation_enabled, _foveation_strength)

func _on_foveation_strength_changed(value: float) -> void:
	_foveation_strength = clamp(value, 0.0, 1.0)
	_update_foveation_ui()
	_save_config()
	foveation_settings_changed.emit(_foveation_enabled, _foveation_strength)

func _on_passthrough_toggled(enabled: bool) -> void:
	_passthrough_enabled = enabled
	_update_passthrough_ui()
	_save_config()
	passthrough_toggled.emit(_passthrough_enabled)

func _update_curvature_ui() -> void:
	if _chk_curved:
		_chk_curved.button_pressed = _curved_enabled
	if _slider_curvature:
		_slider_curvature.value = _curvature_amount
		_slider_curvature.editable = _curved_enabled
	if _lbl_curvature_value:
		_lbl_curvature_value.text = "%.2f" % _curvature_amount

func _update_foveation_ui() -> void:
	if _chk_foveation:
		_chk_foveation.button_pressed = _foveation_enabled
	if _slider_foveation:
		_slider_foveation.value = _foveation_strength
		_slider_foveation.editable = _foveation_enabled
	if _lbl_foveation_value:
		_lbl_foveation_value.text = "%.2f" % _foveation_strength

func _update_passthrough_ui() -> void:
	if _chk_passthrough:
		_chk_passthrough.button_pressed = _passthrough_enabled
		_chk_passthrough.disabled = not _passthrough_supported
		if _passthrough_supported:
			_chk_passthrough.tooltip_text = ""
		else:
			_chk_passthrough.tooltip_text = "OpenXR runtime does not support passthrough"

func _on_workspace_save_pressed() -> void:
	workspace_save_requested.emit()

func _on_workspace_restore_pressed() -> void:
	workspace_restore_requested.emit()

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
	cfg.set_value("display", "foveation_enabled", _foveation_enabled)
	cfg.set_value("display", "foveation_strength", _foveation_strength)
	cfg.set_value("display", "passthrough_enabled", _passthrough_enabled)
	cfg.save(CONFIG_PATH)

func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		_host_ip = cfg.get_value("network", "host_ip", "192.168.1.100")
		_tcp_port = cfg.get_value("network", "tcp_port", 19800)
		_udp_port = cfg.get_value("network", "udp_port", 19801)
		_curved_enabled = cfg.get_value("display", "curved_enabled", false)
		_curvature_amount = cfg.get_value("display", "curved_amount", 0.18)
		_foveation_enabled = cfg.get_value("display", "foveation_enabled", false)
		_foveation_strength = cfg.get_value("display", "foveation_strength", 0.55)
		_passthrough_enabled = cfg.get_value("display", "passthrough_enabled", false)
