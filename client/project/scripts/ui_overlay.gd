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

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

@export var panel_distance : float = 1.0   ## Metres in front of camera
@export var panel_width    : float = 0.90  ## Panel width in metres
@export var panel_height   : float = 0.62  ## Panel height in metres

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const CONFIG_PATH  := "user://immersive2_config.cfg"
## Smooth-follow speed: higher = snappier, lower = more floaty
const FOLLOW_SPEED := 2.5

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

# ---------------------------------------------------------------------------
# Internal node references (built procedurally)
# ---------------------------------------------------------------------------

var _viewport              : SubViewport
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

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_load_config()
	_build_ui()
	set_process(true)
	hide()

func _process(delta: float) -> void:
	_update_labels()
	if _visible_overlay:
		_smooth_follow_camera(delta)

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
# Camera follow  (Issue #1 fix)
# ---------------------------------------------------------------------------

## Each frame while visible: smoothly interpolate the panel transform
## towards the target position in front of the camera.
## Using Transform3D.interpolate_with() is the standard pattern in
## godot-xr-tools and the Godot VR editor PR #67736.
func _smooth_follow_camera(delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return
	var fwd := -camera.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3(0.0, 0.0, -1.0)
	else:
		fwd = fwd.normalized()
	var right         := fwd.cross(Vector3.UP).normalized()
	var target_origin := camera.global_transform.origin \
		+ fwd * panel_distance + Vector3(0.0, -0.08, 0.0)
	var target_t      := Transform3D(Basis(right, Vector3.UP, -fwd), target_origin)
	global_transform  = global_transform.interpolate_with(
		target_t, minf(delta * FOLLOW_SPEED, 1.0))

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
	# ── SubViewport (900 × 620) ──────────────────────────────────────────
	_viewport                          = SubViewport.new()
	_viewport.size                     = Vector2i(900, 620)
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
		var _ch := ch
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
	for child in _monitor_list.get_children():
		child.queue_free()
	for mon in _available_monitors:
		var btn := Button.new()
		btn.text = "[%d]  %s  —  %dx%d @ %d Hz" % [
			mon.get("id", 0),
			mon.get("name", "Monitor"),
			mon.get("width", 0),
			mon.get("height", 0),
			mon.get("refresh_rate", 60)
		]
		btn.add_theme_font_size_override("font_size", 17)
		var mid: int = mon.get("id", 0)
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
