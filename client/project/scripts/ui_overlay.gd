## VR UI Overlay for Immersive-2.
##
## Floating SubViewport panel that shows connection status, IP input,
## monitor selection, and display settings.
## Smoothly follows the camera each frame when visible (lazy-billboard
## pattern used by the Godot VR editor and godot-xr-tools).

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

# ---------------------------------------------------------------------------
# Internal node references (built procedurally)
# ---------------------------------------------------------------------------

var _viewport              : SubViewport
var _reticle               : Node2D           ## Pointer reticle drawn on top (non-interactive)
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

# Stream quality controls
var _codec_buttons         : Dictionary = {}  ## value -> Button
var _res_buttons           : Dictionary = {}  ## value -> Button
var _fps_buttons           : Dictionary = {}  ## value -> Button
var _slider_bitrate        : HSlider
var _lbl_bitrate_value     : Label
var _slider_jpegq          : HSlider
var _lbl_jpegq_value       : Label
var _lbl_auto_info         : Label

## Debounce timer: any quality-selector edit auto-applies a short moment later,
## so settings always take effect without needing the Apply button. The delay
## coalesces rapid changes (e.g. dragging a slider) into a single stream restart.
var _apply_debounce        : Timer
const AUTO_APPLY_DELAY      := 0.45

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
	# The overlay stays where it was opened; it only moves while being grabbed.
	if _is_dragging and is_instance_valid(_drag_controller):
		_follow_controller()
	_update_reticle()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Show / hide the overlay.  On show: snap to camera, then smooth-follow
## takes over each frame.
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
	# Track the reticle so the user can clearly see where the controller points.
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
# Grab-to-move  (overlay is static; grip drags it like a screen panel)
# ---------------------------------------------------------------------------

## Begin dragging the overlay with the given controller (called from main.gd
## when the grip is pressed while the pointer hovers the overlay).
func start_drag(controller: Node3D) -> void:
	if not controller:
		return
	_is_dragging     = true
	_drag_controller = controller
	# Record the overlay pose relative to the controller at grab time.
	_drag_offset = controller.global_transform.affine_inverse() * global_transform

func stop_drag() -> void:
	_is_dragging     = false
	_drag_controller = null

func _follow_controller() -> void:
	global_transform = _drag_controller.global_transform * _drag_offset

# ---------------------------------------------------------------------------
# Pointer reticle  (clear cursor over the overlay only)
# ---------------------------------------------------------------------------

## Show the reticle only while the pointer is actively hovering the overlay
## (a few frames of grace so it doesn't flicker between input events).
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
	# Dark halo first for contrast against light/dark UI alike.
	_reticle.draw_arc(c, 15.0, 0.0, TAU, 48, Color(0.0, 0.0, 0.0, 0.6), 5.0, true)
	_reticle.draw_arc(c, 15.0, 0.0, TAU, 48, accent, 2.5, true)
	_reticle.draw_circle(c, 3.0, accent)

# ---------------------------------------------------------------------------
# Camera placement
# ---------------------------------------------------------------------------

## Instant snap used on first show.
func _reposition_in_front_of_camera() -> void:
	var camera := get_viewport().get_camera_3d()
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
# Theme helpers  (Issue #2 — dark VR-friendly design)
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
	# PanelContainer background
	t.set_stylebox("panel", "PanelContainer",
		_flat(Color(0.055, 0.065, 0.115, 0.97), Color(0.20, 0.30, 0.58), 7, 12))
	# Buttons
	t.set_stylebox("normal",   "Button", _flat(Color(0.12, 0.18, 0.36), Color(0.26, 0.38, 0.68)))
	t.set_stylebox("hover",    "Button", _flat(Color(0.20, 0.32, 0.60), Color(0.35, 0.52, 0.90)))
	t.set_stylebox("pressed",  "Button", _flat(Color(0.07, 0.11, 0.26), Color(0.18, 0.28, 0.52)))
	t.set_stylebox("disabled", "Button", _flat(Color(0.08, 0.09, 0.14), Color(0.16, 0.17, 0.24)))
	t.set_font_size("font_size", "Button", 18)
	t.set_color("font_color",          "Button", Color(0.88, 0.92, 1.00))
	t.set_color("font_disabled_color", "Button", Color(0.35, 0.38, 0.52))
	# LineEdit
	t.set_stylebox("normal", "LineEdit", _flat(Color(0.09, 0.10, 0.17), Color(0.26, 0.40, 0.70), 4, 8))
	t.set_stylebox("focus",  "LineEdit", _flat(Color(0.11, 0.13, 0.21), Color(0.40, 0.62, 1.00), 4, 8))
	t.set_font_size("font_size",              "LineEdit", 18)
	t.set_color("font_color",            "LineEdit", Color(0.90, 0.94, 1.00))
	t.set_color("font_placeholder_color","LineEdit", Color(0.40, 0.45, 0.62))
	# Labels
	t.set_font_size("font_size", "Label", 19)
	t.set_color("font_color",    "Label", Color(0.87, 0.91, 1.00))
	# CheckBox
	t.set_font_size("font_size",           "CheckBox", 18)
	t.set_color("font_color",              "CheckBox", Color(0.87, 0.91, 1.00))
	t.set_color("font_disabled_color",     "CheckBox", Color(0.38, 0.40, 0.55))
	# HSlider — make track visible
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

	# Pointer reticle — a Node2D (not a Control) so it draws on top of the UI
	# but never takes part in GUI input picking: it can't ever eat clicks.
	_reticle = Node2D.new()
	_reticle.visible = false
	_reticle.draw.connect(_on_reticle_draw)
	_canvas.add_child(_reticle)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 6)
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
	vbox.add_child(info_row)

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

	# ── Connection section ──────────────────────────────────────────────
	_add_section_separator(vbox, "Connection")

	var ip_row := HBoxContainer.new()
	ip_row.add_theme_constant_override("separation", 8)
	vbox.add_child(ip_row)
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
	kbd_toggle.text        = "⌨"
	kbd_toggle.tooltip_text = "Show / hide IP keyboard"
	kbd_toggle.pressed.connect(_on_toggle_kbd)
	ip_row.add_child(kbd_toggle)

	# In-viewport IP keyboard (Issue #4)
	_kbd_container         = _build_ip_keyboard()
	_kbd_container.visible = false
	vbox.add_child(_kbd_container)

	_btn_connect = Button.new()
	_btn_connect.text = "Connect"
	_btn_connect.pressed.connect(_on_connect_pressed)
	vbox.add_child(_btn_connect)

	# ── Display section ──────────────────────────────────────────────────
	_add_section_separator(vbox, "Display")

	# Curved screen (checkbox + slider on same row)
	var curve_row := HBoxContainer.new()
	curve_row.add_theme_constant_override("separation", 8)
	vbox.add_child(curve_row)
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
	_lbl_curvature_value.text              = "%.2f" % _curvature_amount
	_lbl_curvature_value.custom_minimum_size = Vector2(38, 0)
	_lbl_curvature_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	curve_row.add_child(_lbl_curvature_value)
	_update_curvature_ui()

	# Foveated rendering
	var fov_row := HBoxContainer.new()
	fov_row.add_theme_constant_override("separation", 8)
	vbox.add_child(fov_row)
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
	vbox.add_child(pass_row)
	_chk_passthrough = CheckBox.new()
	_chk_passthrough.text           = "Passthrough  (mixed reality)"
	_chk_passthrough.button_pressed = _passthrough_enabled
	_chk_passthrough.toggled.connect(_on_passthrough_toggled)
	pass_row.add_child(_chk_passthrough)
	_update_passthrough_ui()

	# ── Stream quality section ───────────────────────────────────────────
	_build_quality_section(vbox)

	# ── Monitors section ─────────────────────────────────────────────────
	_add_section_separator(vbox, "Monitors")

	var mon_hdr := HBoxContainer.new()
	mon_hdr.add_theme_constant_override("separation", 6)
	vbox.add_child(mon_hdr)
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

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical  = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size  = Vector2(0, 80)
	vbox.add_child(scroll)

	_monitor_list = VBoxContainer.new()
	_monitor_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_monitor_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_monitor_list)

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
# Stream quality section
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
	# Hardware-decoded codecs only — the MJPEG software path has been removed.
	_codec_buttons = _make_segmented_row(codec_row,
		[["Auto", 0xFF], ["H.264", 0], ["H.265", 1], ["AV1", 3]],
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

	# Apply button (settings also auto-apply shortly after any change)
	var apply_btn := Button.new()
	apply_btn.text = "✔ Apply quality settings"
	apply_btn.pressed.connect(_on_apply_quality_pressed)
	vbox.add_child(apply_btn)

	# Debounced auto-apply so the selectors always update without the button.
	_apply_debounce = Timer.new()
	_apply_debounce.one_shot = true
	_apply_debounce.timeout.connect(_on_apply_quality_pressed)
	add_child(_apply_debounce)

	_refresh_quality_ui()

## (Re)start the auto-apply countdown. Called after every selector edit.
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
	# Highlight the slider that matters for the chosen codec
	# (bitrate → H.264/HEVC/AV1; JPEG quality → MJPEG/Auto)
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
		# Auto resolution recomputes and applies on the spot (its own path).
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
	_fps_value = fps  # if no button matches, none is highlighted — that's fine
	_refresh_quality_ui()

## Show the result of the perceptual auto-quality computation.
func set_auto_quality_result(width: int, height: int, fps: int,
		ppd: float, angle_deg: float, distance: float) -> void:
	if _lbl_auto_info:
		_lbl_auto_info.text = "Auto: %dx%d @ %d fps — panel covers %.0f° at %.1f m (headset ≈ %.0f px/°)" % [
			width, height, fps, angle_deg, distance, ppd]

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
# In-viewport IP keyboard  (Issue #4)
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
		var btn := Button.new()

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
		_monitor_list.add_child(btn)

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
	# Keep the overlay open: selection toggles screens on/off, and the list
	# refreshes via set_active_monitors() to show the new state.
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
# Config persistence  (identical to original)
# ---------------------------------------------------------------------------

func _save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("network", "host_ip",           _host_ip)
	cfg.set_value("network", "tcp_port",           _tcp_port)
	cfg.set_value("network", "udp_port",           _udp_port)
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
	_curved_enabled      = cfg.get_value("display", "curved_enabled",     false)
	_curvature_amount    = cfg.get_value("display", "curved_amount",      0.18)
	_foveation_enabled   = cfg.get_value("display", "foveation_enabled",  false)
	_foveation_strength  = cfg.get_value("display", "foveation_strength", 0.55)
	_passthrough_enabled = cfg.get_value("display", "passthrough_enabled",false)
