## VR UI Overlay for Immersive-2.
##
## Floating SubViewport panel that shows connection status, IP input,
## monitor selection, and display settings.
## Organised in 4 tabs (Connect / Display / Spaces / Monitors) to avoid
## vertical scrolling in VR. Smoothly follows the camera each frame when
## visible (lazy-billboard pattern used by the Godot VR editor and godot-xr-tools).

extends Node3D

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal connect_requested(ip: String, tcp_port: int, udp_port: int)
signal monitor_selected(monitor_id: int)
signal add_screen_panel(monitor_id: int, slot: int)
signal screen_curvature_changed(enabled: bool, amount: float)
signal foveation_settings_changed(enabled: bool, strength: float)
signal passthrough_toggled(enabled: bool)
signal workspace_save_requested
signal workspace_restore_requested
## codec: 0xFF auto, 0 H.264, 2 MJPEG · res_percent: 100/75/50, -1 auto · fps: 0 auto
signal stream_settings_changed(codec: int, bitrate_kbps: int, jpeg_quality: int, res_percent: int, fps: int)
signal auto_quality_requested
## Spaces & collaboration (mixed-reality + multi-user) requests.
signal environment_cycle_requested
signal environment_selected(index: int)
signal portal_add_requested(shape: int)
signal keyboard_portal_requested
signal whiteboard_toggle_requested
## public=true means the room should be visible in the public lobby listing.
signal room_join_requested(url: String, room_id: String, display_name: String, public: bool)
signal room_leave_requested
signal mic_mute_toggled
## Emitted when the user presses "Refresh" in the Public Lobby section.
signal lobby_list_requested
## Per-monitor opt-in screen sharing toggle (Monitors tab).
signal monitor_share_toggled(monitor_id: int, shared: bool)
## Emitted when the user accepts the one-time screen-sharing privacy notice.
## Carries the monitor whose share request triggered the dialog so the share
## can be retried once consent is given.
signal privacy_notice_acknowledged(monitor_id: int)
## Show / hide the in-VR QWERTY keyboard from the overlay.
signal keyboard_toggle_requested
## Whiteboard maintenance (clear all strokes / save a PNG snapshot).
signal whiteboard_clear_requested
signal whiteboard_save_requested
## Remove every passthrough portal.
signal portals_clear_requested

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

@export var panel_distance : float = 1.0   ## Metres in front of camera
@export var panel_width    : float = 0.90  ## Panel width in metres
@export var panel_height   : float = 0.86  ## Panel height in metres

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const CONFIG_PATH  := "user://immersive2_config.cfg"

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

enum ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, STREAMING }

var _state                 : ConnectionState = ConnectionState.DISCONNECTED
var _ping_ms               : float           = 0.0
var _available_monitors    : Array           = []
var _host_ip               : String          = "192.168.1.100"
var _tcp_port              : int             = 19800
var _udp_port              : int             = 19801
var _visible_overlay       : bool            = false
var _curved_enabled        : bool            = false
var _curvature_amount      : float           = 0.18
var _foveation_enabled     : bool            = false
var _foveation_strength    : float           = 0.55
var _passthrough_enabled   : bool            = false
var _passthrough_supported : bool            = true
var _last_pointer_uv       : Vector2         = Vector2(0.5, 0.5)
var _room_url              : String          = ""
var _room_name             : String          = "Guest"
var _kbd_visible           : bool            = false

# Grab-to-move state (the overlay stays static until grabbed with the grip).
var _is_dragging           : bool            = false
var _drag_controller       : Node3D          = null
var _drag_offset           : Transform3D

# Pointer reticle state (shown only while pointing at the overlay).
var _pointer_px            : Vector2         = Vector2(450, 440)
var _reticle_idle_frames   : int             = 999

# Stream quality state (mirrors main.gd; applied via the Apply button)
var _active_monitor_ids    : Array           = []
var _stream_codec          : int             = 0xFF
var _bitrate_kbps          : int             = 20000
var _jpeg_quality          : int             = 70
var _res_percent           : int             = 100
var _fps_value             : int             = 0

# Tab state
var _active_tab            : int             = 0
var _tab_containers        : Array           = []
var _tab_buttons           : Array           = []

# Environment picker state
var _env_names             : Array           = []
var _env_buttons           : Dictionary     = {}   ## index -> Button
var _selected_env_index    : int             = 0

# Room state
var _in_room               : bool = false
var _mic_muted             : bool = false
## Monitor IDs the local user is currently sharing with the room (opt-in).
var _shared_monitor_ids    : Array = []

# ---------------------------------------------------------------------------
# Internal node references (built procedurally)
# ---------------------------------------------------------------------------

var _viewport              : SubViewport
var _reticle               : Node2D           ## Pointer reticle drawn on top
var _panel_mesh            : MeshInstance3D
var _canvas                : CanvasLayer
var _lbl_status            : Label
var _lbl_ping              : Label
var _input_ip              : LineEdit
var _btn_connect           : Button
var _monitor_list          : VBoxContainer
var _lbl_title             : Label
var _chk_curved            : CheckBox
var _slider_curvature      : HSlider
var _lbl_curvature_value   : Label
var _chk_foveation         : CheckBox
var _slider_foveation      : HSlider
var _lbl_foveation_value   : Label
var _chk_passthrough       : CheckBox
var _btn_workspace_save    : Button
var _btn_workspace_restore : Button
var _kbd_container         : VBoxContainer  ## In-viewport numeric keyboard
var _env_button_container  : HBoxContainer  ## Grid of env choice buttons

# Stream quality controls
var _codec_buttons         : Dictionary = {}  ## value -> Button
var _res_buttons           : Dictionary = {}  ## value -> Button
var _fps_buttons           : Dictionary = {}  ## value -> Button
var _slider_bitrate        : HSlider
var _lbl_bitrate_value     : Label
var _slider_jpegq          : HSlider
var _lbl_jpegq_value       : Label
var _lbl_auto_info         : Label

# Spaces & collaboration controls
var _lbl_env_name          : Label
var _input_room_url        : LineEdit
var _input_room_id         : LineEdit
var _input_room_name       : LineEdit
var _btn_room_join         : Button
var _lbl_room_status       : Label
var _lbl_whiteboard_status : Label

# Public lobby controls
var _chk_public            : CheckBox
var _btn_lobby_refresh     : Button
var _lobby_list_container  : VBoxContainer
var _btn_mic               : Button

# Privacy consent modal (one-time screen-sharing notice)
var _privacy_dialog        : Control   ## Full-rect dimmer + centered notice panel
var _privacy_pending_mid   : int = -1  ## Monitor whose share triggered the notice

## Debounce timer: any quality-selector edit auto-applies a short moment later.
var _apply_debounce        : Timer
const AUTO_APPLY_DELAY      := 0.45

# Toast notification
var _toast_label           : Label
var _toast_timer           : Timer

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_load_config()
	_build_ui()
	set_process(true)
	hide()

func _process(_delta: float) -> void:
	_update_labels()
	if _is_dragging and is_instance_valid(_drag_controller):
		_follow_controller()
	_update_reticle()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Show / hide the overlay. On show: snap to camera, then stays put until dragged.
func toggle_visibility() -> void:
	_visible_overlay = not _visible_overlay
	if _visible_overlay:
		show()
		_reposition_in_front_of_camera()
	else:
		hide()

func set_state(state: ConnectionState) -> void:
	_state = state
	_update_labels()
	if not _btn_connect:
		return
	match state:
		ConnectionState.DISCONNECTED:
			_btn_connect.text     = "Connect"
			_btn_connect.disabled = false
		ConnectionState.CONNECTING:
			_btn_connect.text     = "Connecting…"
			_btn_connect.disabled = true
		ConnectionState.CONNECTED, ConnectionState.STREAMING:
			_btn_connect.text     = "Disconnect"
			_btn_connect.disabled = false

func set_monitor_list(monitors: Array) -> void:
	_available_monitors = monitors
	_rebuild_monitor_list()

## Update which monitors are currently streaming (active indicators).
func set_active_monitors(ids: Array) -> void:
	_active_monitor_ids = ids.duplicate()
	_rebuild_monitor_list()

func set_latency(ms: float) -> void:
	_ping_ms = ms

## Show a transient toast message at the bottom of the panel for `duration_s` seconds.
func show_toast(text: String, duration_s: float = 3.0) -> void:
	if not is_instance_valid(_toast_label) or not is_instance_valid(_toast_timer):
		return
	_toast_label.text    = text
	_toast_label.visible = true
	_toast_timer.start(duration_s)

func set_screen_curvature(enabled: bool, amount: float) -> void:
	_curved_enabled   = enabled
	_curvature_amount = clamp(amount, 0.0, 0.5)
	_update_curvature_ui()

func set_foveation_settings(enabled: bool, strength: float) -> void:
	_foveation_enabled  = enabled
	_foveation_strength = clamp(strength, 0.0, 1.0)
	_update_foveation_ui()

func set_passthrough_settings(enabled: bool, supported: bool = true) -> void:
	_passthrough_enabled   = enabled
	_passthrough_supported = supported
	_update_passthrough_ui()

## Populate the environment picker buttons. Called from main.gd after
## environment_manager is ready (passing get_environment_names()).
func set_environment_list(names: Array) -> void:
	_env_names = names.duplicate()
	_rebuild_env_picker()

## Highlight the environment at `index` in the picker. Called from main.gd
## after any environment change (cycle or direct selection).
func set_environment_index(index: int) -> void:
	_selected_env_index = index
	_refresh_env_picker()
	if _lbl_env_name and _env_names.size() > index:
		_lbl_env_name.text = _env_names[index]

## Legacy: just updates the name label (kept for backward compat; prefer set_environment_index).
func set_environment_name(env_name: String) -> void:
	if _lbl_env_name:
		_lbl_env_name.text = env_name

# ---------------------------------------------------------------------------
# VR pointer injection  (called by main.gd / vr_input.gd)
# ---------------------------------------------------------------------------

## Ray–plane intersection with the overlay mesh.
## Returns { valid:bool, uv:Vector2, distance:float }.
func ray_to_overlay_hit(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	if not visible or not _panel_mesh:
		return {"valid": false}
	var inv        := _panel_mesh.global_transform.affine_inverse()
	var local_o    := inv * ray_origin
	var local_d    := _panel_mesh.global_transform.basis.inverse() * ray_direction
	if abs(local_d.z) < 0.0001:
		return {"valid": false}
	var t := -local_o.z / local_d.z
	if t < 0.0:
		return {"valid": false}
	var hit := local_o + local_d * t
	var u   := (hit.x / panel_width)  + 0.5
	var v   := 0.5 - (hit.y / panel_height)
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return {"valid": false}
	_last_pointer_uv = Vector2(u, v)
	return {"valid": true, "uv": Vector2(u, v), "distance": t}

## Push a mouse-motion event into the SubViewport.
func inject_pointer_move(uv: Vector2) -> void:
	if not _viewport:
		return
	_last_pointer_uv = uv
	var px := Vector2(uv.x * _viewport.size.x, uv.y * _viewport.size.y)
	_pointer_px          = px
	_reticle_idle_frames = 0
	var ev := InputEventMouseMotion.new()
	ev.position        = px
	ev.global_position = px
	_viewport.push_input(ev)

## Push a mouse-button event into the SubViewport.
func inject_pointer_button(pressed: bool,
		button_index: int = MOUSE_BUTTON_LEFT) -> void:
	if not _viewport:
		return
	var px := _last_pointer_uv * Vector2(_viewport.size)
	var ev := InputEventMouseButton.new()
	ev.button_index    = button_index
	ev.pressed         = pressed
	ev.position        = px
	ev.global_position = px
	_viewport.push_input(ev)

## Push a scroll event into the SubViewport.
func inject_pointer_scroll(delta_y: float) -> void:
	if not _viewport:
		return
	var px := _last_pointer_uv * Vector2(_viewport.size)
	var ev := InputEventMouseButton.new()
	ev.button_index    = MOUSE_BUTTON_WHEEL_UP if delta_y > 0 else MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed         = true
	ev.factor          = absf(delta_y)
	ev.position        = px
	ev.global_position = px
	_viewport.push_input(ev)

# ---------------------------------------------------------------------------
# Grab-to-move
# ---------------------------------------------------------------------------

func start_drag(controller: Node3D) -> void:
	if not controller:
		return
	_is_dragging     = true
	_drag_controller = controller
	_drag_offset = controller.global_transform.affine_inverse() * global_transform

func stop_drag() -> void:
	_is_dragging     = false
	_drag_controller = null

func _follow_controller() -> void:
	global_transform = _drag_controller.global_transform * _drag_offset

# ---------------------------------------------------------------------------
# Pointer reticle
# ---------------------------------------------------------------------------

func _update_reticle() -> void:
	if not _reticle:
		return
	_reticle_idle_frames += 1
	var should_show := _visible_overlay and _reticle_idle_frames < 6
	if _reticle.visible != should_show:
		_reticle.visible = should_show
	if should_show:
		_reticle.queue_redraw()

func _on_reticle_draw() -> void:
	var c := _pointer_px
	var accent := Color(0.45, 0.85, 1.0, 0.95)
	_reticle.draw_arc(c, 15.0, 0.0, TAU, 48, Color(0.0, 0.0, 0.0, 0.6), 5.0, true)
	_reticle.draw_arc(c, 15.0, 0.0, TAU, 48, accent, 2.5, true)
	_reticle.draw_circle(c, 3.0, accent)

# ---------------------------------------------------------------------------
# Camera placement
# ---------------------------------------------------------------------------

func _reposition_in_front_of_camera() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var camera := vp.get_camera_3d()
	if not camera:
		return
	var fwd := -camera.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3(0.0, 0.0, -1.0)
	else:
		fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	global_transform.origin = camera.global_transform.origin \
		+ fwd * panel_distance + Vector3(0.0, -0.08, 0.0)
	global_transform.basis  = Basis(right, Vector3.UP, -fwd)

# ---------------------------------------------------------------------------
# Theme helpers
# ---------------------------------------------------------------------------

func _flat(bg: Color, border: Color,
		radius: int = 5, mg: int = 8) -> StyleBoxFlat:
	var s               := StyleBoxFlat.new()
	s.bg_color           = bg
	s.border_color       = border
	s.border_width_left  = 1
	s.border_width_right = 1
	s.border_width_top   = 1
	s.border_width_bottom = 1
	s.corner_radius_top_left     = radius
	s.corner_radius_top_right    = radius
	s.corner_radius_bottom_left  = radius
	s.corner_radius_bottom_right = radius
	s.content_margin_left  = mg
	s.content_margin_right = mg
	s.content_margin_top   = mg - 2
	s.content_margin_bottom = mg - 2
	return s

func _apply_theme(root: Control) -> void:
	var t := Theme.new()
	t.set_stylebox("panel", "PanelContainer",
		_flat(Color(0.055, 0.065, 0.115, 0.97), Color(0.20, 0.30, 0.58), 7, 12))
	t.set_stylebox("normal",   "Button", _flat(Color(0.12, 0.18, 0.36), Color(0.26, 0.38, 0.68)))
	t.set_stylebox("hover",    "Button", _flat(Color(0.20, 0.32, 0.60), Color(0.35, 0.52, 0.90)))
	t.set_stylebox("pressed",  "Button", _flat(Color(0.07, 0.11, 0.26), Color(0.18, 0.28, 0.52)))
	t.set_stylebox("disabled", "Button", _flat(Color(0.08, 0.09, 0.14), Color(0.16, 0.17, 0.24)))
	t.set_font_size("font_size", "Button", 18)
	t.set_color("font_color",          "Button", Color(0.88, 0.92, 1.00))
	t.set_color("font_disabled_color", "Button", Color(0.35, 0.38, 0.52))
	t.set_stylebox("normal", "LineEdit", _flat(Color(0.09, 0.10, 0.17), Color(0.26, 0.40, 0.70), 4, 8))
	t.set_stylebox("focus",  "LineEdit", _flat(Color(0.11, 0.13, 0.21), Color(0.40, 0.62, 1.00), 4, 8))
	t.set_font_size("font_size",              "LineEdit", 18)
	t.set_color("font_color",            "LineEdit", Color(0.90, 0.94, 1.00))
	t.set_color("font_placeholder_color","LineEdit", Color(0.40, 0.45, 0.62))
	t.set_font_size("font_size", "Label", 19)
	t.set_color("font_color",    "Label", Color(0.87, 0.91, 1.00))
	t.set_font_size("font_size",           "CheckBox", 18)
	t.set_color("font_color",              "CheckBox", Color(0.87, 0.91, 1.00))
	t.set_color("font_disabled_color",     "CheckBox", Color(0.38, 0.40, 0.55))
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.18, 0.22, 0.40)
	track.corner_radius_top_left = 3
	track.corner_radius_top_right = 3
	track.corner_radius_bottom_left = 3
	track.corner_radius_bottom_right = 3
	t.set_stylebox("slider", "HSlider", track)
	var grab := StyleBoxFlat.new()
	grab.bg_color = Color(0.30, 0.52, 0.90)
	grab.corner_radius_top_left = 3
	grab.corner_radius_top_right = 3
	grab.corner_radius_bottom_left = 3
	grab.corner_radius_bottom_right = 3
	t.set_stylebox("grabber_area", "HSlider", grab)
	root.theme = t

# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	# ── SubViewport (900 × 880) ──────────────────────────────────────────
	_viewport                          = SubViewport.new()
	_viewport.size                     = Vector2i(900, 880)
	_viewport.transparent_bg           = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	_canvas = CanvasLayer.new()
	_viewport.add_child(_canvas)

	# ── Root container with dark theme ──────────────────────────────────
	var root := PanelContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_apply_theme(root)
	_canvas.add_child(root)

	# Pointer reticle (non-interactive, draws on top of UI)
	_reticle = Node2D.new()
	_reticle.visible = false
	_reticle.draw.connect(_on_reticle_draw)
	_canvas.add_child(_reticle)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 0)
	root.add_child(vbox)

	# ── Title bar ────────────────────────────────────────────────────────
	var title_bg := StyleBoxFlat.new()
	title_bg.bg_color              = Color(0.09, 0.14, 0.30)
	title_bg.border_width_bottom   = 1
	title_bg.border_color          = Color(0.24, 0.38, 0.72)
	title_bg.content_margin_top    = 10
	title_bg.content_margin_bottom = 10
	title_bg.content_margin_left   = 14
	title_bg.content_margin_right  = 14
	var title_panel := PanelContainer.new()
	title_panel.add_theme_stylebox_override("panel", title_bg)
	vbox.add_child(title_panel)

	_lbl_title = Label.new()
	_lbl_title.text = "✦  Immersive-2"
	_lbl_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lbl_title.add_theme_font_size_override("font_size", 22)
	_lbl_title.add_theme_color_override("font_color", Color(0.72, 0.87, 1.00))
	title_panel.add_child(_lbl_title)

	# ── Status row ───────────────────────────────────────────────────────
	var info_row := HBoxContainer.new()
	info_row.add_theme_constant_override("separation", 20)
	var info_mg := StyleBoxEmpty.new()
	info_mg.content_margin_left  = 14
	info_mg.content_margin_right = 14
	info_mg.content_margin_top   = 4
	info_mg.content_margin_bottom = 4
	var info_wrap := PanelContainer.new()
	info_wrap.add_theme_stylebox_override("panel", info_mg)
	vbox.add_child(info_wrap)
	info_wrap.add_child(info_row)

	var st_box := HBoxContainer.new()
	st_box.add_theme_constant_override("separation", 6)
	info_row.add_child(st_box)
	var st_lbl := Label.new()
	st_lbl.text = "Status:"
	st_lbl.add_theme_color_override("font_color", Color(0.50, 0.56, 0.78))
	st_box.add_child(st_lbl)
	_lbl_status = Label.new()
	_lbl_status.text = "Disconnected"
	st_box.add_child(_lbl_status)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_row.add_child(spacer)

	var ping_box := HBoxContainer.new()
	ping_box.add_theme_constant_override("separation", 6)
	info_row.add_child(ping_box)
	var ping_lbl := Label.new()
	ping_lbl.text = "Ping:"
	ping_lbl.add_theme_color_override("font_color", Color(0.50, 0.56, 0.78))
	ping_box.add_child(ping_lbl)
	_lbl_ping = Label.new()
	_lbl_ping.text = "-- ms"
	ping_box.add_child(_lbl_ping)

	# ── Tab bar ──────────────────────────────────────────────────────────
	_build_tab_bar(vbox)

	# ── Tab 0: Connect ───────────────────────────────────────────────────
	var tab0 := VBoxContainer.new()
	tab0.add_theme_constant_override("separation", 6)
	tab0.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(tab0)
	_tab_containers.append(tab0)
	_build_tab_connect(tab0)

	# ── Tab 1: Display ───────────────────────────────────────────────────
	var tab1 := VBoxContainer.new()
	tab1.add_theme_constant_override("separation", 6)
	tab1.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(tab1)
	_tab_containers.append(tab1)
	_build_tab_display(tab1)

	# ── Tab 2: Spaces ────────────────────────────────────────────────────
	var tab2 := VBoxContainer.new()
	tab2.add_theme_constant_override("separation", 6)
	tab2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(tab2)
	_tab_containers.append(tab2)
	_build_spaces_section(tab2)

	# ── Tab 3: Monitors ──────────────────────────────────────────────────
	var tab3 := VBoxContainer.new()
	tab3.add_theme_constant_override("separation", 6)
	tab3.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(tab3)
	_tab_containers.append(tab3)
	_build_tab_monitors(tab3)

	# Non-visual timer (shared across tabs)
	_apply_debounce = Timer.new()
	_apply_debounce.one_shot = true
	_apply_debounce.timeout.connect(_on_apply_quality_pressed)
	add_child(_apply_debounce)

	_switch_tab(0)

	# ── One-time privacy consent modal (hidden until a share is requested) ─
	_build_privacy_dialog()
	# Keep the pointer reticle drawn on top of everything, including the modal.
	if is_instance_valid(_reticle):
		_canvas.move_child(_reticle, _canvas.get_child_count() - 1)

	# ── Toast label (fades after a short duration) ────────────────────────
	_toast_label = Label.new()
	_toast_label.visible = false
	_toast_label.add_theme_font_size_override("font_size", 17)
	_toast_label.add_theme_color_override("font_color", Color(0.95, 0.88, 0.40))
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_toast_label.offset_top = -56
	_canvas.add_child(_toast_label)

	_toast_timer = Timer.new()
	_toast_timer.one_shot = true
	_toast_timer.timeout.connect(func(): _toast_label.visible = false)
	add_child(_toast_timer)

	# ── 3D mesh that renders the SubViewport in world space ───────────────
	_panel_mesh = MeshInstance3D.new()
	var plane          := PlaneMesh.new()
	plane.size          = Vector2(panel_width, panel_height)
	plane.orientation   = PlaneMesh.FACE_Z
	_panel_mesh.mesh   = plane
	var mat            := StandardMaterial3D.new()
	mat.albedo_texture  = _viewport.get_texture()
	mat.flags_transparent = true
	mat.shading_mode    = BaseMaterial3D.SHADING_MODE_UNSHADED
	_panel_mesh.material_override = mat
	add_child(_panel_mesh)

# ---------------------------------------------------------------------------
# Tab bar
# ---------------------------------------------------------------------------

func _build_tab_bar(parent: VBoxContainer) -> void:
	var sep1 := HSeparator.new()
	sep1.add_theme_color_override("color", Color(0.14, 0.19, 0.38))
	parent.add_child(sep1)

	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.07, 0.10, 0.22)
	bar_bg.border_width_bottom = 1
	bar_bg.border_color = Color(0.20, 0.28, 0.55)
	bar_bg.content_margin_left   = 4
	bar_bg.content_margin_right  = 4
	bar_bg.content_margin_top    = 4
	bar_bg.content_margin_bottom = 4
	var bar_wrap := PanelContainer.new()
	bar_wrap.add_theme_stylebox_override("panel", bar_bg)
	parent.add_child(bar_wrap)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 3)
	bar_wrap.add_child(bar)

	var tab_defs := [
		["⚡ Connect",  "Connection & host IP"],
		["🖥 Display",  "Screen & stream quality"],
		["🌆 Spaces",   "Environments, portals & rooms"],
		["📺 Monitors", "Active monitor screens"],
	]
	for i in range(tab_defs.size()):
		var btn := Button.new()
		btn.text         = tab_defs[i][0]
		btn.tooltip_text = tab_defs[i][1]
		btn.toggle_mode  = true
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 17)
		var idx := i
		btn.pressed.connect(func(): _switch_tab(idx))
		bar.add_child(btn)
		_tab_buttons.append(btn)

func _switch_tab(index: int) -> void:
	_active_tab = index
	for i in range(_tab_containers.size()):
		_tab_containers[i].visible = (i == index)
	for i in range(_tab_buttons.size()):
		var btn: Button = _tab_buttons[i]
		btn.set_pressed_no_signal(i == index)
		if i == index:
			btn.add_theme_color_override("font_color", Color(0.55, 0.95, 0.65))
			btn.add_theme_stylebox_override("normal",
				_flat(Color(0.10, 0.22, 0.14), Color(0.25, 0.65, 0.40)))
		else:
			btn.remove_theme_color_override("font_color")
			btn.remove_theme_stylebox_override("normal")

# ---------------------------------------------------------------------------
# Tab 0 – Connect
# ---------------------------------------------------------------------------

func _build_tab_connect(parent: VBoxContainer) -> void:
	_add_section_separator(parent, "Connection")

	var ip_row := HBoxContainer.new()
	ip_row.add_theme_constant_override("separation", 8)
	parent.add_child(ip_row)
	var ip_title := Label.new()
	ip_title.text = "Host IP"
	ip_title.add_theme_color_override("font_color", Color(0.68, 0.74, 0.94))
	ip_title.custom_minimum_size = Vector2(68, 0)
	ip_row.add_child(ip_title)
	_input_ip = LineEdit.new()
	_input_ip.text                  = _host_ip
	_input_ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_ip.placeholder_text      = "192.168.1.100"
	ip_row.add_child(_input_ip)
	var kbd_toggle := Button.new()
	kbd_toggle.text         = "⌨"
	kbd_toggle.tooltip_text = "Show / hide IP keyboard"
	kbd_toggle.pressed.connect(_on_toggle_kbd)
	ip_row.add_child(kbd_toggle)

	_kbd_container         = _build_ip_keyboard()
	_kbd_container.visible = false
	parent.add_child(_kbd_container)

	_btn_connect = Button.new()
	_btn_connect.text = "Connect"
	_btn_connect.pressed.connect(_on_connect_pressed)
	parent.add_child(_btn_connect)

# ---------------------------------------------------------------------------
# Tab 1 – Display
# ---------------------------------------------------------------------------

func _build_tab_display(parent: VBoxContainer) -> void:
	_add_section_separator(parent, "Display")

	# Curved screen
	var curve_row := HBoxContainer.new()
	curve_row.add_theme_constant_override("separation", 8)
	parent.add_child(curve_row)
	_chk_curved = CheckBox.new()
	_chk_curved.text           = "Curved screen"
	_chk_curved.button_pressed = _curved_enabled
	_chk_curved.toggled.connect(_on_curved_toggled)
	curve_row.add_child(_chk_curved)
	var curve_sp := Control.new()
	curve_sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	curve_row.add_child(curve_sp)
	_slider_curvature = HSlider.new()
	_slider_curvature.min_value             = 0.0
	_slider_curvature.max_value             = 0.5
	_slider_curvature.step                  = 0.01
	_slider_curvature.value                 = _curvature_amount
	_slider_curvature.custom_minimum_size   = Vector2(150, 0)
	_slider_curvature.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider_curvature.value_changed.connect(_on_curvature_value_changed)
	curve_row.add_child(_slider_curvature)
	_lbl_curvature_value = Label.new()
	_lbl_curvature_value.text               = "%.2f" % _curvature_amount
	_lbl_curvature_value.custom_minimum_size = Vector2(38, 0)
	_lbl_curvature_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	curve_row.add_child(_lbl_curvature_value)
	_update_curvature_ui()

	# Foveated rendering
	var fov_row := HBoxContainer.new()
	fov_row.add_theme_constant_override("separation", 8)
	parent.add_child(fov_row)
	_chk_foveation = CheckBox.new()
	_chk_foveation.text           = "Eye-tracked foveation"
	_chk_foveation.button_pressed = _foveation_enabled
	_chk_foveation.toggled.connect(_on_foveation_toggled)
	fov_row.add_child(_chk_foveation)
	var fov_sp := Control.new()
	fov_sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fov_row.add_child(fov_sp)
	_slider_foveation = HSlider.new()
	_slider_foveation.min_value             = 0.0
	_slider_foveation.max_value             = 1.0
	_slider_foveation.step                  = 0.01
	_slider_foveation.value                 = _foveation_strength
	_slider_foveation.custom_minimum_size   = Vector2(150, 0)
	_slider_foveation.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider_foveation.value_changed.connect(_on_foveation_strength_changed)
	fov_row.add_child(_slider_foveation)
	_lbl_foveation_value = Label.new()
	_lbl_foveation_value.text               = "%.2f" % _foveation_strength
	_lbl_foveation_value.custom_minimum_size  = Vector2(38, 0)
	_lbl_foveation_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fov_row.add_child(_lbl_foveation_value)
	_update_foveation_ui()

	# Passthrough
	var pass_row := HBoxContainer.new()
	parent.add_child(pass_row)
	_chk_passthrough = CheckBox.new()
	_chk_passthrough.text           = "Passthrough  (mixed reality)"
	_chk_passthrough.button_pressed = _passthrough_enabled
	_chk_passthrough.toggled.connect(_on_passthrough_toggled)
	pass_row.add_child(_chk_passthrough)
	_update_passthrough_ui()

	# Stream quality
	_build_quality_section(parent)

# ---------------------------------------------------------------------------
# Tab 3 – Monitors
# ---------------------------------------------------------------------------

func _build_tab_monitors(parent: VBoxContainer) -> void:
	_add_section_separator(parent, "Monitors")

	var mon_hdr := HBoxContainer.new()
	mon_hdr.add_theme_constant_override("separation", 6)
	parent.add_child(mon_hdr)
	var mon_fill := Control.new()
	mon_fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mon_hdr.add_child(mon_fill)
	_btn_workspace_save = Button.new()
	_btn_workspace_save.text = "💾 Save layout"
	_btn_workspace_save.pressed.connect(_on_workspace_save_pressed)
	mon_hdr.add_child(_btn_workspace_save)
	_btn_workspace_restore = Button.new()
	_btn_workspace_restore.text = "↩ Restore"
	_btn_workspace_restore.pressed.connect(_on_workspace_restore_pressed)
	mon_hdr.add_child(_btn_workspace_restore)

	var hint := Label.new()
	hint.text = "Tap a monitor to add/remove its screen. Use 🔗 Share to show it to the room (join a room first)."
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.50, 0.58, 0.78))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical  = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size  = Vector2(0, 80)
	parent.add_child(scroll)

	_monitor_list = VBoxContainer.new()
	_monitor_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_monitor_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_monitor_list)

# ---------------------------------------------------------------------------
# Stream quality section (Tab 1 – Display)
# ---------------------------------------------------------------------------

## Row of mutually-exclusive option buttons. `options` = [[label, value], …].
## Returns a Dictionary value -> Button.
func _make_segmented_row(parent: HBoxContainer, options: Array,
		on_chosen: Callable) -> Dictionary:
	var buttons: Dictionary = {}
	for opt in options:
		var b := Button.new()
		b.text = opt[0]
		b.toggle_mode = true
		b.add_theme_font_size_override("font_size", 16)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var value = opt[1]
		b.pressed.connect(func(): on_chosen.call(value))
		parent.add_child(b)
		buttons[value] = b
	return buttons

func _refresh_segmented(buttons: Dictionary, selected_value) -> void:
	for value in buttons:
		var b: Button = buttons[value]
		b.set_pressed_no_signal(value == selected_value)
		if value == selected_value:
			b.add_theme_color_override("font_color", Color(0.55, 0.95, 0.65))
		else:
			b.remove_theme_color_override("font_color")

func _quality_label(parent: HBoxContainer, text: String, min_w: int = 92) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.68, 0.74, 0.94))
	lbl.custom_minimum_size = Vector2(min_w, 0)
	parent.add_child(lbl)

func _build_quality_section(vbox: VBoxContainer) -> void:
	_add_section_separator(vbox, "Stream quality")

	# Codec row
	var codec_row := HBoxContainer.new()
	codec_row.add_theme_constant_override("separation", 6)
	vbox.add_child(codec_row)
	_quality_label(codec_row, "Codec")
	_codec_buttons = _make_segmented_row(codec_row,
		[["Auto", 0xFF], ["H.264", 0], ["H.265", 1], ["AV1", 3], ["MJPEG", 2]],
		_on_codec_chosen)

	# Resolution row
	var res_row := HBoxContainer.new()
	res_row.add_theme_constant_override("separation", 6)
	vbox.add_child(res_row)
	_quality_label(res_row, "Resolution")
	_res_buttons = _make_segmented_row(res_row,
		[["Native", 100], ["75%", 75], ["50%", 50], ["✨ Auto", -1]],
		_on_res_chosen)

	# FPS row
	var fps_row := HBoxContainer.new()
	fps_row.add_theme_constant_override("separation", 6)
	vbox.add_child(fps_row)
	_quality_label(fps_row, "FPS")
	_fps_buttons = _make_segmented_row(fps_row,
		[["Auto", 0], ["24", 24], ["30", 30], ["45", 45], ["60", 60]],
		_on_fps_chosen)

	# Bitrate slider (H.264)
	var br_row := HBoxContainer.new()
	br_row.add_theme_constant_override("separation", 8)
	vbox.add_child(br_row)
	_quality_label(br_row, "Bitrate")
	_slider_bitrate = HSlider.new()
	_slider_bitrate.min_value = 5
	_slider_bitrate.max_value = 60
	_slider_bitrate.step = 1
	_slider_bitrate.value = _bitrate_kbps / 1000.0
	_slider_bitrate.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider_bitrate.value_changed.connect(_on_bitrate_changed)
	br_row.add_child(_slider_bitrate)
	_lbl_bitrate_value = Label.new()
	_lbl_bitrate_value.custom_minimum_size = Vector2(92, 0)
	_lbl_bitrate_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	br_row.add_child(_lbl_bitrate_value)

	# JPEG quality slider (MJPEG)
	var jq_row := HBoxContainer.new()
	jq_row.add_theme_constant_override("separation", 8)
	vbox.add_child(jq_row)
	_quality_label(jq_row, "JPEG qual.")
	_slider_jpegq = HSlider.new()
	_slider_jpegq.min_value = 10
	_slider_jpegq.max_value = 95
	_slider_jpegq.step = 5
	_slider_jpegq.value = _jpeg_quality
	_slider_jpegq.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider_jpegq.value_changed.connect(_on_jpegq_changed)
	jq_row.add_child(_slider_jpegq)
	_lbl_jpegq_value = Label.new()
	_lbl_jpegq_value.custom_minimum_size = Vector2(92, 0)
	_lbl_jpegq_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	jq_row.add_child(_lbl_jpegq_value)

	# Auto-quality info label
	_lbl_auto_info = Label.new()
	_lbl_auto_info.text = ""
	_lbl_auto_info.add_theme_font_size_override("font_size", 15)
	_lbl_auto_info.add_theme_color_override("font_color", Color(0.55, 0.80, 1.00))
	_lbl_auto_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_lbl_auto_info)

	# Apply button
	var apply_btn := Button.new()
	apply_btn.text = "✔ Apply quality settings"
	apply_btn.pressed.connect(_on_apply_quality_pressed)
	vbox.add_child(apply_btn)

	_refresh_quality_ui()

## (Re)start the auto-apply countdown.
func _schedule_auto_apply() -> void:
	if _apply_debounce:
		_apply_debounce.start(AUTO_APPLY_DELAY)

func _refresh_quality_ui() -> void:
	_refresh_segmented(_codec_buttons, _stream_codec)
	_refresh_segmented(_res_buttons, _res_percent)
	_refresh_segmented(_fps_buttons, _fps_value)
	if _slider_bitrate:
		_slider_bitrate.set_value_no_signal(_bitrate_kbps / 1000.0)
	if _lbl_bitrate_value:
		_lbl_bitrate_value.text = "%d Mbps" % int(_bitrate_kbps / 1000.0)
	if _slider_jpegq:
		_slider_jpegq.set_value_no_signal(_jpeg_quality)
	if _lbl_jpegq_value:
		_lbl_jpegq_value.text = "%d" % _jpeg_quality
	if _slider_bitrate:
		_slider_bitrate.editable = _stream_codec in [0, 1, 3]
	if _slider_jpegq:
		_slider_jpegq.editable = _stream_codec == 2 or _stream_codec == 0xFF

func _on_codec_chosen(value: int) -> void:
	_stream_codec = value
	_refresh_quality_ui()
	_schedule_auto_apply()

func _on_res_chosen(value: int) -> void:
	_res_percent = value
	_refresh_quality_ui()
	if value == -1:
		auto_quality_requested.emit()
	else:
		_schedule_auto_apply()

func _on_fps_chosen(value: int) -> void:
	_fps_value = value
	_refresh_quality_ui()
	_schedule_auto_apply()

func _on_bitrate_changed(value: float) -> void:
	_bitrate_kbps = int(value) * 1000
	if _lbl_bitrate_value:
		_lbl_bitrate_value.text = "%d Mbps" % int(value)
	_schedule_auto_apply()

func _on_jpegq_changed(value: float) -> void:
	_jpeg_quality = int(value)
	if _lbl_jpegq_value:
		_lbl_jpegq_value.text = "%d" % int(value)
	_schedule_auto_apply()

func _on_apply_quality_pressed() -> void:
	stream_settings_changed.emit(_stream_codec, _bitrate_kbps, _jpeg_quality,
		_res_percent, _fps_value)

## Sync controls from main.gd (initial load and after auto-compute).
func set_stream_settings(codec: int, bitrate_kbps: int, jpeg_quality: int,
		res_percent: int, fps: int) -> void:
	_stream_codec = codec
	_bitrate_kbps = bitrate_kbps
	_jpeg_quality = jpeg_quality
	_res_percent = res_percent
	_fps_value = fps
	_refresh_quality_ui()

## Show the result of the perceptual auto-quality computation.
func set_auto_quality_result(width: int, height: int, fps: int,
		ppd: float, angle_deg: float, distance: float) -> void:
	if _lbl_auto_info:
		_lbl_auto_info.text = "Auto: %dx%d @ %d fps — panel covers %.0f° at %.1f m (headset ≈ %.0f px/°)" % [
			width, height, fps, angle_deg, distance, ppd]

# ---------------------------------------------------------------------------
# Tab 2 – Spaces & collaboration (environments, portals, whiteboard, rooms)
# ---------------------------------------------------------------------------

func _build_spaces_section(parent: VBoxContainer) -> void:
	# ── Environment picker ────────────────────────────────────────────────
	_add_section_separator(parent, "Environment")

	# Current env name label
	_lbl_env_name = Label.new()
	_lbl_env_name.text = ""
	_lbl_env_name.add_theme_font_size_override("font_size", 15)
	_lbl_env_name.add_theme_color_override("font_color", Color(0.55, 0.80, 1.00))
	_lbl_env_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(_lbl_env_name)

	# Env picker button row (populated lazily via set_environment_list)
	_env_button_container = HBoxContainer.new()
	_env_button_container.add_theme_constant_override("separation", 4)
	parent.add_child(_env_button_container)

	# Placeholder label shown until set_environment_list() is called
	var env_placeholder := Label.new()
	env_placeholder.name = "EnvPlaceholder"
	env_placeholder.text = "Loading environments…"
	env_placeholder.add_theme_font_size_override("font_size", 15)
	env_placeholder.add_theme_color_override("font_color", Color(0.45, 0.50, 0.65))
	_env_button_container.add_child(env_placeholder)

	# ── Mixed-reality portals + whiteboard ────────────────────────────────
	_add_section_separator(parent, "Spaces & Collaboration")

	# Portals row: add a shape, the keyboard passthrough portal, or clear them all.
	var mr_row := HBoxContainer.new()
	mr_row.add_theme_constant_override("separation", 6)
	parent.add_child(mr_row)
	_quality_label(mr_row, "Portal", 56)
	_portal_button(mr_row, "▭", "Add a rectangular passthrough portal", 0)
	_portal_button(mr_row, "■", "Add a square passthrough portal", 1)
	_portal_button(mr_row, "●", "Add a circular passthrough portal", 2)
	var kbp_btn := Button.new()
	kbp_btn.text = "⌨"
	kbp_btn.tooltip_text = "Keyboard passthrough portal (see your real keyboard)"
	kbp_btn.pressed.connect(func(): keyboard_portal_requested.emit())
	mr_row.add_child(kbp_btn)
	var clrp_btn := Button.new()
	clrp_btn.text = "🗑"
	clrp_btn.tooltip_text = "Remove all passthrough portals"
	clrp_btn.pressed.connect(func(): portals_clear_requested.emit())
	mr_row.add_child(clrp_btn)

	# Tools row: in-VR keyboard, whiteboard toggle, and whiteboard maintenance.
	var tools_row := HBoxContainer.new()
	tools_row.add_theme_constant_override("separation", 6)
	parent.add_child(tools_row)
	_quality_label(tools_row, "Tools", 56)
	var kbd_btn := Button.new()
	kbd_btn.text = "⌨ Keyboard"
	kbd_btn.tooltip_text = "Show / hide the in-VR QWERTY keyboard (also A/X on the controller)"
	kbd_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kbd_btn.pressed.connect(func(): keyboard_toggle_requested.emit())
	tools_row.add_child(kbd_btn)
	var wb_btn := Button.new()
	wb_btn.text = "📝 Whiteboard"
	wb_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wb_btn.pressed.connect(func(): whiteboard_toggle_requested.emit())
	tools_row.add_child(wb_btn)
	var wb_clear := Button.new()
	wb_clear.text = "🧹"
	wb_clear.tooltip_text = "Clear the whiteboard for everyone in the room"
	wb_clear.pressed.connect(func(): whiteboard_clear_requested.emit())
	tools_row.add_child(wb_clear)
	var wb_save := Button.new()
	wb_save.text = "💾"
	wb_save.tooltip_text = "Save a high-resolution PNG snapshot of the whiteboard"
	wb_save.pressed.connect(func(): whiteboard_save_requested.emit())
	tools_row.add_child(wb_save)

	_lbl_whiteboard_status = Label.new()
	_lbl_whiteboard_status.text = ""
	_lbl_whiteboard_status.add_theme_font_size_override("font_size", 14)
	_lbl_whiteboard_status.add_theme_color_override("font_color", Color(0.55, 0.80, 1.00))
	_lbl_whiteboard_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(_lbl_whiteboard_status)

	# ── Multi-user room ───────────────────────────────────────────────────
	var url_row := HBoxContainer.new()
	url_row.add_theme_constant_override("separation", 8)
	parent.add_child(url_row)
	_quality_label(url_row, "Server", 56)
	_input_room_url = LineEdit.new()
	_input_room_url.placeholder_text      = "ws://192.168.1.100:19810"
	_input_room_url.text                  = _room_url
	_input_room_url.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	url_row.add_child(_input_room_url)

	var room_row := HBoxContainer.new()
	room_row.add_theme_constant_override("separation", 8)
	parent.add_child(room_row)
	_quality_label(room_row, "Room", 56)
	_input_room_id = LineEdit.new()
	_input_room_id.placeholder_text      = "lobby"
	_input_room_id.text                  = "lobby"
	_input_room_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_row.add_child(_input_room_id)
	_input_room_name = LineEdit.new()
	_input_room_name.placeholder_text  = "Name"
	_input_room_name.text              = _room_name if not _room_name.is_empty() else "Guest"
	_input_room_name.custom_minimum_size = Vector2(120, 0)
	room_row.add_child(_input_room_name)

	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	parent.add_child(join_row)
	_btn_room_join = Button.new()
	_btn_room_join.text                  = "🤝 Join room"
	_btn_room_join.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_room_join.pressed.connect(_on_room_join_pressed)
	join_row.add_child(_btn_room_join)
	_lbl_room_status = Label.new()
	_lbl_room_status.text = "Not in a room"
	_lbl_room_status.add_theme_color_override("font_color", Color(0.50, 0.56, 0.78))
	join_row.add_child(_lbl_room_status)

	# Voice chat mute
	var voice_row := HBoxContainer.new()
	voice_row.add_theme_constant_override("separation", 8)
	parent.add_child(voice_row)
	_quality_label(voice_row, "Voice", 56)
	_btn_mic = Button.new()
	_btn_mic.text         = "🎤 Mic on"
	_btn_mic.tooltip_text = "Mute / unmute your microphone for the room (M)"
	_btn_mic.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_mic.pressed.connect(func(): mic_mute_toggled.emit())
	voice_row.add_child(_btn_mic)

	# ── Public Lobby ──────────────────────────────────────────────────────
	_add_section_separator(parent, "Public Lobby")

	var lobby_ctrl_row := HBoxContainer.new()
	lobby_ctrl_row.add_theme_constant_override("separation", 8)
	parent.add_child(lobby_ctrl_row)
	_chk_public = CheckBox.new()
	_chk_public.text         = "Make public"
	_chk_public.tooltip_text = "List this room in the public lobby so others can discover and join it"
	lobby_ctrl_row.add_child(_chk_public)
	_btn_lobby_refresh = Button.new()
	_btn_lobby_refresh.text                  = "⟳ Refresh"
	_btn_lobby_refresh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_lobby_refresh.pressed.connect(func(): lobby_list_requested.emit())
	lobby_ctrl_row.add_child(_btn_lobby_refresh)

	var lobby_scroll := ScrollContainer.new()
	lobby_scroll.custom_minimum_size    = Vector2(0, 80)
	lobby_scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	lobby_scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	parent.add_child(lobby_scroll)
	_lobby_list_container = VBoxContainer.new()
	_lobby_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lobby_scroll.add_child(_lobby_list_container)
	var lbl_empty := Label.new()
	lbl_empty.text = "Press ⟳ Refresh to browse public rooms"
	lbl_empty.add_theme_color_override("font_color", Color(0.45, 0.50, 0.65))
	lbl_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_list_container.add_child(lbl_empty)

func _portal_button(parent: HBoxContainer, label: String, tip: String, shape: int) -> void:
	var b := Button.new()
	b.text         = label
	b.tooltip_text = tip
	b.pressed.connect(func(): portal_add_requested.emit(shape))
	parent.add_child(b)

# ---------------------------------------------------------------------------
# Environment picker – rebuilt when set_environment_list() is called
# ---------------------------------------------------------------------------

func _rebuild_env_picker() -> void:
	if not is_instance_valid(_env_button_container):
		return
	# Remove all children (placeholder label + old buttons)
	for child in _env_button_container.get_children():
		_env_button_container.remove_child(child)
		child.queue_free()
	_env_buttons.clear()

	for i in range(_env_names.size()):
		var b := Button.new()
		b.text          = _env_names[i]
		b.toggle_mode   = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 16)
		var idx := i
		b.pressed.connect(func(): _on_env_chosen(idx))
		_env_button_container.add_child(b)
		_env_buttons[i] = b

	_refresh_env_picker()

func _refresh_env_picker() -> void:
	for i in _env_buttons:
		var b: Button = _env_buttons[i]
		b.set_pressed_no_signal(i == _selected_env_index)
		if i == _selected_env_index:
			b.add_theme_color_override("font_color", Color(0.55, 0.95, 0.65))
			b.add_theme_stylebox_override("normal",
				_flat(Color(0.08, 0.22, 0.14), Color(0.25, 0.65, 0.40)))
		else:
			b.remove_theme_color_override("font_color")
			b.remove_theme_stylebox_override("normal")

func _on_env_chosen(index: int) -> void:
	_selected_env_index = index
	_refresh_env_picker()
	if _lbl_env_name and _env_names.size() > index:
		_lbl_env_name.text = _env_names[index]
	environment_selected.emit(index)

func _on_room_join_pressed() -> void:
	if _in_room:
		room_leave_requested.emit()
		return
	var url := _input_room_url.text.strip_edges()
	if url.is_empty():
		url = "ws://127.0.0.1:19810"
	var is_public: bool = is_instance_valid(_chk_public) and _chk_public.button_pressed
	room_join_requested.emit(url, _input_room_id.text.strip_edges(), _input_room_name.text.strip_edges(), is_public)

## Reflect room membership from main.gd.
func set_room_state(in_room: bool, info: String = "") -> void:
	_in_room = in_room
	if _btn_room_join:
		_btn_room_join.text = "🚪 Leave room" if in_room else "🤝 Join room"
	if _lbl_room_status:
		_lbl_room_status.text = info if not info.is_empty() else ("In room" if in_room else "Not in a room")
	# Share toggles are only enabled inside a room — refresh their state.
	_rebuild_monitor_list()

## Show a short status line under the whiteboard tools (e.g. after a snapshot save).
func set_whiteboard_status(text: String) -> void:
	if is_instance_valid(_lbl_whiteboard_status):
		_lbl_whiteboard_status.text = text

## Populate the public lobby list.
func populate_lobby(rooms: Array) -> void:
	if not is_instance_valid(_lobby_list_container):
		_lobby_list_container = VBoxContainer.new()
	for child in _lobby_list_container.get_children():
		_lobby_list_container.remove_child(child)
		child.queue_free()
	if rooms.is_empty():
		var lbl := Label.new()
		lbl.text = "No public rooms at the moment"
		lbl.add_theme_color_override("font_color", Color(0.45, 0.50, 0.65))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_lobby_list_container.add_child(lbl)
		return
	for room_info in rooms:
		var rid: String  = str(room_info.get("room_id", ""))
		var cnt: int     = int(room_info.get("user_count", 0))
		var row          := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_lobby_list_container.add_child(row)
		var lbl := Label.new()
		lbl.text = "%s  (%d)" % [rid, cnt]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_color_override("font_color", Color(0.75, 0.82, 1.0))
		row.add_child(lbl)
		var btn := Button.new()
		btn.text = "→ Join"
		var _rid: String = rid
		btn.pressed.connect(func(): _on_lobby_join_pressed(_rid))
		row.add_child(btn)

func _on_lobby_join_pressed(room_id: String) -> void:
	if is_instance_valid(_input_room_id):
		_input_room_id.text = room_id
	_on_room_join_pressed()

## Reflect the local microphone mute state from main.gd.
func set_mic_muted(muted: bool) -> void:
	_mic_muted = muted
	if _btn_mic:
		_btn_mic.text = "🔇 Mic muted" if muted else "🎤 Mic on"
		_btn_mic.add_theme_color_override("font_color",
			Color(0.95, 0.45, 0.45) if muted else Color(0.55, 0.92, 0.6))

# ---------------------------------------------------------------------------
# Section separator helper
# ---------------------------------------------------------------------------

func _add_section_separator(parent: VBoxContainer, title: String) -> void:
	var sep := HSeparator.new()
	sep.add_theme_color_override("color", Color(0.18, 0.24, 0.44))
	parent.add_child(sep)
	var lbl := Label.new()
	lbl.text = title.to_upper()
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.42, 0.52, 0.78))
	parent.add_child(lbl)

# ---------------------------------------------------------------------------
# In-viewport IP keyboard
# ---------------------------------------------------------------------------

func _build_ip_keyboard() -> VBoxContainer:
	var wrapper := VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 3)

	var frame := PanelContainer.new()
	var frame_bg := StyleBoxFlat.new()
	frame_bg.bg_color              = Color(0.07, 0.09, 0.16)
	frame_bg.border_color          = Color(0.20, 0.30, 0.56)
	frame_bg.border_width_left     = 1
	frame_bg.border_width_right    = 1
	frame_bg.border_width_top      = 1
	frame_bg.border_width_bottom   = 1
	frame_bg.corner_radius_top_left = 4
	frame_bg.corner_radius_top_right = 4
	frame_bg.corner_radius_bottom_left = 4
	frame_bg.corner_radius_bottom_right = 4
	frame_bg.content_margin_left   = 6
	frame_bg.content_margin_right  = 6
	frame_bg.content_margin_top    = 6
	frame_bg.content_margin_bottom = 6
	frame.add_theme_stylebox_override("panel", frame_bg)
	wrapper.add_child(frame)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)
	frame.add_child(inner)

	# Row 1 — digits + dot
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 3)
	inner.add_child(row1)
	for ch in ["1","2","3","4","5","6","7","8","9","0","."]:
		var b := Button.new()
		b.text = ch
		b.add_theme_font_size_override("font_size", 18)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var _ch: String = ch
		b.pressed.connect(func(): _on_ip_kbd_key(_ch))
		row1.add_child(b)

	# Row 2 — control keys
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 3)
	inner.add_child(row2)

	var bksp := Button.new()
	bksp.text = "⌫  Back"
	bksp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bksp.pressed.connect(func(): _on_ip_kbd_key("←"))
	row2.add_child(bksp)

	var clr := Button.new()
	clr.text = "✕  Clear"
	clr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clr.pressed.connect(func(): _on_ip_kbd_key("C"))
	row2.add_child(clr)

	var done := Button.new()
	done.text = "✓  Done"
	done.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	done.pressed.connect(func(): _on_toggle_kbd())
	row2.add_child(done)

	return wrapper

func _on_toggle_kbd() -> void:
	_kbd_visible = not _kbd_visible
	if _kbd_container:
		_kbd_container.visible = _kbd_visible

func _on_ip_kbd_key(code: String) -> void:
	if not _input_ip:
		return
	match code:
		"←":
			if _input_ip.text.length() > 0:
				_input_ip.text = _input_ip.text.left(_input_ip.text.length() - 1)
		"C":
			_input_ip.text = ""
		_:
			_input_ip.text += code

# ---------------------------------------------------------------------------
# Monitor list rebuild
# ---------------------------------------------------------------------------

func _rebuild_monitor_list() -> void:
	if not _monitor_list:
		return
	for child in _monitor_list.get_children():
		child.queue_free()
	for mon in _available_monitors:
		var mid: int = mon.get("id", 0)
		var is_active: bool = _active_monitor_ids.has(mid)
		var is_shared: bool = _shared_monitor_ids.has(mid)

		# Each monitor is a row: a wide "select / deselect" button + a share toggle.
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_monitor_list.add_child(row)

		var btn := Button.new()
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var status := "●  " if is_active else "○  "
		var hint := "   (tap to remove)" if is_active else "   (tap to add)"
		btn.text = "%s[%d]  %s  —  %dx%d @ %d Hz%s" % [
			status,
			mid,
			mon.get("name", "Monitor"),
			mon.get("width", 0),
			mon.get("height", 0),
			mon.get("refresh_rate", 60),
			hint
		]
		btn.add_theme_font_size_override("font_size", 17)
		if is_active:
			btn.add_theme_color_override("font_color", Color(0.45, 0.95, 0.60))
			btn.add_theme_stylebox_override("normal",
				_flat(Color(0.08, 0.22, 0.14), Color(0.25, 0.65, 0.40)))
			btn.add_theme_stylebox_override("hover",
				_flat(Color(0.12, 0.30, 0.18), Color(0.35, 0.80, 0.50)))
		btn.pressed.connect(func(): _on_monitor_selected(mid))
		row.add_child(btn)

		# Share toggle — opt-in per monitor, only meaningful inside a room.
		var share_btn := Button.new()
		share_btn.toggle_mode = true
		share_btn.custom_minimum_size = Vector2(120, 0)
		share_btn.add_theme_font_size_override("font_size", 16)
		share_btn.text = "🟢 Sharing" if is_shared else "🔗 Share"
		share_btn.button_pressed = is_shared
		share_btn.disabled = not _in_room
		share_btn.tooltip_text = "Share this monitor with the room" if _in_room \
			else "Join a room first to share a monitor"
		if is_shared:
			share_btn.add_theme_color_override("font_color", Color(0.45, 0.95, 0.60))
		var _mid: int = mid
		share_btn.pressed.connect(func(): _on_monitor_share_pressed(_mid))
		row.add_child(share_btn)

## A monitor's share toggle was pressed — flip its shared state and notify main.gd.
func _on_monitor_share_pressed(monitor_id: int) -> void:
	var now_shared: bool = not _shared_monitor_ids.has(monitor_id)
	monitor_share_toggled.emit(monitor_id, now_shared)

## Reflect the set of locally-shared monitors from main.gd (rebuilds the toggles).
func set_shared_monitors(ids: Array) -> void:
	_shared_monitor_ids = ids.duplicate()
	_rebuild_monitor_list()

# ---------------------------------------------------------------------------
# Privacy consent modal (one-time screen-sharing notice)
# ---------------------------------------------------------------------------

## Build the hidden full-rect consent modal: a click-blocking dimmer plus a
## centered panel with the privacy notice and accept / dismiss buttons.
func _build_privacy_dialog() -> void:
	_privacy_dialog = Control.new()
	_privacy_dialog.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_privacy_dialog.visible = false
	_canvas.add_child(_privacy_dialog)

	# Dimmer — STOP filter swallows pointer input so the UI beneath is inert.
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.66)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_privacy_dialog.add_child(dim)

	# Centered notice card.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_privacy_dialog.add_child(center)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel",
		_flat(Color(0.07, 0.09, 0.17, 0.99), Color(0.30, 0.46, 0.82), 8, 18))
	card.custom_minimum_size = Vector2(640, 0)
	center.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	card.add_child(vb)

	var title := Label.new()
	title.text = "🔒  Screen sharing"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.72, 0.87, 1.00))
	vb.add_child(title)

	var body := Label.new()
	body.text = "You are about to share a monitor with everyone in this room. " \
		+ "They will see its live contents until you stop sharing.\n\n" \
		+ "Sharing is opt-in per monitor and you can revoke it at any time. " \
		+ "Only what you explicitly share is sent — nothing is shared by default."
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 17)
	body.add_theme_color_override("font_color", Color(0.82, 0.87, 0.98))
	vb.add_child(body)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	vb.add_child(btn_row)

	var cancel := Button.new()
	cancel.text = "Not now"
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(_on_privacy_dialog_cancel)
	btn_row.add_child(cancel)

	var accept := Button.new()
	accept.text = "I understand — share"
	accept.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	accept.add_theme_color_override("font_color", Color(0.55, 0.95, 0.65))
	accept.pressed.connect(_on_privacy_dialog_confirm)
	btn_row.add_child(accept)

## Show the one-time consent modal for the monitor that triggered a share.
## Called by main.gd in response to PrivacyManager.privacy_notice_required.
func show_privacy_notice(monitor_id: int) -> void:
	_privacy_pending_mid = monitor_id
	if is_instance_valid(_privacy_dialog):
		_privacy_dialog.visible = true

## Whether the consent modal is currently shown (test/observability helper).
func is_privacy_notice_visible() -> bool:
	return is_instance_valid(_privacy_dialog) and _privacy_dialog.visible

func _on_privacy_dialog_confirm() -> void:
	if is_instance_valid(_privacy_dialog):
		_privacy_dialog.visible = false
	privacy_notice_acknowledged.emit(_privacy_pending_mid)
	_privacy_pending_mid = -1

func _on_privacy_dialog_cancel() -> void:
	if is_instance_valid(_privacy_dialog):
		_privacy_dialog.visible = false
	_privacy_pending_mid = -1

# ---------------------------------------------------------------------------
# Label update  (called every frame)
# ---------------------------------------------------------------------------

func _update_labels() -> void:
	if not _lbl_status:
		return
	var txt: String
	var col: Color
	match _state:
		ConnectionState.DISCONNECTED:
			txt = "Disconnected";  col = Color(0.88, 0.30, 0.30)
		ConnectionState.CONNECTING:
			txt = "Connecting…";   col = Color(0.95, 0.78, 0.22)
		ConnectionState.CONNECTED:
			txt = "Connected";     col = Color(0.28, 0.85, 0.48)
		ConnectionState.STREAMING:
			txt = "● Streaming";   col = Color(0.28, 0.70, 1.00)
		_:
			txt = "Unknown";       col = Color.WHITE
	_lbl_status.text = txt
	_lbl_status.modulate = col

	if _lbl_ping:
		if _ping_ms > 0.0:
			var c := Color(0.28, 0.85, 0.48)
			if _ping_ms > 30.0: c = Color(0.95, 0.78, 0.22)
			if _ping_ms > 60.0: c = Color(0.90, 0.30, 0.30)
			_lbl_ping.text    = "%.1f ms" % _ping_ms
			_lbl_ping.modulate = c
		else:
			_lbl_ping.text    = "-- ms"
			_lbl_ping.modulate = Color(0.50, 0.56, 0.78)

# ---------------------------------------------------------------------------
# Slider / checkbox UI sync
# ---------------------------------------------------------------------------

func _update_curvature_ui() -> void:
	if _chk_curved:
		_chk_curved.button_pressed = _curved_enabled
	if _slider_curvature:
		_slider_curvature.value    = _curvature_amount
		_slider_curvature.editable = _curved_enabled
	if _lbl_curvature_value:
		_lbl_curvature_value.text  = "%.2f" % _curvature_amount

func _update_foveation_ui() -> void:
	if _chk_foveation:
		_chk_foveation.button_pressed = _foveation_enabled
	if _slider_foveation:
		_slider_foveation.value    = _foveation_strength
		_slider_foveation.editable = _foveation_enabled
	if _lbl_foveation_value:
		_lbl_foveation_value.text  = "%.2f" % _foveation_strength

func _update_passthrough_ui() -> void:
	if _chk_passthrough:
		_chk_passthrough.button_pressed = _passthrough_enabled
		_chk_passthrough.disabled       = not _passthrough_supported

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
		connect_requested.emit("", 0, 0)

func _on_monitor_selected(monitor_id: int) -> void:
	monitor_selected.emit(monitor_id)

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

func _on_workspace_save_pressed() -> void:
	workspace_save_requested.emit()

func _on_workspace_restore_pressed() -> void:
	workspace_restore_requested.emit()

# ---------------------------------------------------------------------------
# Config persistence
# ---------------------------------------------------------------------------

func _save_config() -> void:
	var cfg := ConfigFile.new()
	# Load existing data first so sections owned by main.gd ([stream], [test],
	# display/environment_index) survive an overlay save.  Missing file is fine
	# — load() returns ERR_FILE_NOT_FOUND and the object stays empty.
	cfg.load(CONFIG_PATH)
	cfg.set_value("network", "host_ip",           _host_ip)
	cfg.set_value("network", "tcp_port",           _tcp_port)
	cfg.set_value("network", "udp_port",           _udp_port)
	cfg.set_value("network", "room_url",
		_input_room_url.text.strip_edges() if is_instance_valid(_input_room_url) else _room_url)
	cfg.set_value("network", "room_name",
		_input_room_name.text.strip_edges() if is_instance_valid(_input_room_name) else _room_name)
	cfg.set_value("display", "curved_enabled",     _curved_enabled)
	cfg.set_value("display", "curved_amount",      _curvature_amount)
	cfg.set_value("display", "foveation_enabled",  _foveation_enabled)
	cfg.set_value("display", "foveation_strength", _foveation_strength)
	cfg.set_value("display", "passthrough_enabled",_passthrough_enabled)
	cfg.save(CONFIG_PATH)

func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	_host_ip             = cfg.get_value("network", "host_ip",           "192.168.1.100")
	_tcp_port            = cfg.get_value("network", "tcp_port",           19800)
	_udp_port            = cfg.get_value("network", "udp_port",           19801)
	_room_url            = cfg.get_value("network", "room_url",           "")
	_room_name           = cfg.get_value("network", "room_name",          "Guest")
	_curved_enabled      = cfg.get_value("display", "curved_enabled",     false)
	_curvature_amount    = cfg.get_value("display", "curved_amount",      0.18)
	_foveation_enabled   = cfg.get_value("display", "foveation_enabled",  false)
	_foveation_strength  = cfg.get_value("display", "foveation_strength", 0.55)
	_passthrough_enabled = cfg.get_value("display", "passthrough_enabled",false)
