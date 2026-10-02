## The in-VR menu: a 2D UI in a SubViewport, shown on a floating panel.
##
## Five tabs: Connect (PCs found on the network, an address keypad, USB,
## PIN pairing), Screens (which monitors, arrangement, curvature), Space
## (surroundings, passthrough, snapping and locking screens), Quality (codec, resolution,
## frame rate, bitrate) and Input (pointing hand, ray angle, how screens turn
## while moved, vibration). A status line in the header says what is going on.
## Stays where it was opened; move it by the bar under it or with the grip.
##
## Holds no settings of its own: main.gd owns and saves them and pushes them
## in with the set_* functions; the menu only reports what the user did.

extends Node3D

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## ip == "" means disconnect.
signal connect_requested(ip: String, tcp_port: int, udp_port: int)
signal pin_entered(pin: int)
signal pin_cancelled
signal monitor_selected(monitor_id: int)
signal arrange_requested
signal recenter_requested
signal keyboard_toggle_requested
signal screen_curvature_changed(enabled: bool, amount: float)
## "night" / "dusk" / "void" / "passthrough"
signal look_changed(look: String)
## codec: 0xFF auto, 0 H.264, 1 HEVC, 2 MJPEG, 3 AV1 · res_percent: 100/75/50, -1 auto · fps: 0 auto
signal stream_settings_changed(codec: int, bitrate_kbps: int, jpeg_quality: int, res_percent: int, fps: int)
signal auto_quality_requested
signal virtual_screen_requested(width: int, height: int)
signal virtual_screen_remove_requested(monitor_id: int)
## Replace a virtual screen by one of this many pixels, in the same place.
signal virtual_screen_match_requested(monitor_id: int, width: int, height: int)
## The size page for a virtual screen (-1: a new one); main.gd answers with
## open_virtual_page().
signal virtual_page_requested(monitor_id: int)
## Pointer and keyboards drive the PC (off = look only).
signal control_toggled(enabled: bool)
signal haptics_toggled(enabled: bool)
signal screen_link_changed(monitor_id: int, linked: bool)
signal snap_toggled(enabled: bool)
signal lock_toggled(enabled: bool)
## hand: "left" / "right" (the bare hand that points) · ray_angle: controller
## ray tilt in degrees · face_me: grabbed screens turn to the head.
signal pointer_settings_changed(hand: String, ray_angle: float, face_me: bool)
signal compositor_layers_toggled(enabled: bool)

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

const VIEW_SIZE := Vector2i(1000, 680)
@export var panel_distance: float = 0.85  ## Metres in front of the head when opened
@export var panel_width: float = 0.80
var panel_height: float = panel_width * VIEW_SIZE.y / VIEW_SIZE.x

const AUTO_APPLY_DELAY := 0.45
const TAB_NAMES := ["Connect", "Screens", "Space", "Quality", "Input"]
const LOOKS := [["Night", "night"], ["Dusk", "dusk"], ["Void", "void"], ["Passthrough", "passthrough"]]

enum ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, STREAMING }

# ---------------------------------------------------------------------------
# State (mirrors main.gd)
# ---------------------------------------------------------------------------

var _state: ConnectionState = ConnectionState.DISCONNECTED
var _visible_overlay := false
var _host_label := ""
var _link := ""
var _host_ip := ""
var _tcp_port := 19800
var _udp_port := 19801
var _ping_ms := 0.0
var _stats := {"fps": 0.0, "mbps": 0.0}
var _notice := ""
var _discovered: Array = []
var _available_monitors: Array = []
var _active_monitor_ids: Array = []
var _linked_ids: Array = []  ## screens that move together
var _snap_enabled := true
var _lock_enabled := false
var _curved_enabled := true
var _curvature_amount := 0.5
var _look := "night"
var _passthrough_supported := false
var _stream_codec := 0xFF
var _bitrate_kbps := 20000
var _jpeg_quality := 70
var _res_percent := 100
var _fps_value := 0
var _pin_digits := ""
var _host_view_only := false
var _host_virtual := false
var _control_enabled := true
var _haptics_enabled := true
var _pointer_hand := "right"
var _ray_angle := 40.0
var _face_me := false
var _layers_enabled := false
var _pin_visible := false
var _last_pointer_uv := Vector2(0.5, 0.5)
var _tab := 0
var _drag: LaserDrag = null
## The bar under the menu; main.gd::pick() tests it.
var grab_bar: GrabBar = null

# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------

var _viewport: SubViewport
var _canvas: CanvasLayer
var _panel_mesh: MeshInstance3D
var _status_dot: Panel
var _lbl_status: Label
var _lbl_notice: Label
var _tab_buttons: Array = []
var _tab_pages: Array = []
var _tab_indicator: Panel
var _tab_tween: Tween

# Connect tab
var _connect_main: Control
var _hosts_list: VBoxContainer
var _input_ip: LineEdit
var _lbl_ip_error: Label
var _btn_connect: Button
var _btn_usb: Button
var _connected_box: Control
var _lbl_connected: Label
var _details_grid: GridContainer
var _chk_control: CheckButton
var _lbl_control_note: Label
var _btn_disconnect: Button
var _manual_box: Control
var _pin_box: Control
var _lbl_pin_title: Label
var _lbl_pin_error: Label
var _pin_cells: Array = []

# Screens tab
var _monitor_list: VBoxContainer
var _btn_arrange: Button
var _btn_recenter: Button
var _btn_keyboard: Button
var _chk_snap: CheckButton
var _chk_lock: CheckButton
var _btn_add_virtual: Button
var _slider_curvature: HSlider
var _lbl_curvature_value: Label

# Virtual screen page (over the Screens tab)
var _vs_scroll: ScrollContainer
var _lbl_vs_title: Label
var _vs_shape_buttons: Dictionary = {}
var _vs_orient_buttons: Dictionary = {}
var _vs_size_buttons: Dictionary = {}
var _vs_cells: Array = []
var _btn_vs_less: Button
var _btn_vs_more: Button
var _vs_preview: Control
var _vs_rect: Panel
var _vs_old_rect: Panel
var _lbl_vs_caption: Label
var _lbl_vs_sharp: Label
var _btn_vs_go: Button
var _vs_id := -1             ## the virtual screen changed; -1: a new one
var _vs_text := ["", ""]     ## width and height as typed
var _vs_field := 0           ## the cell the keypad types into
var _vs_fresh := true        ## the next digit replaces that cell
var _vs_shape := 0           ## shape of the sizes offered (VirtualSize.SHAPES)
var _vs_aspect := 16.0 / 9.0 ## last valid width / height
var _vs_from := Vector2i.ZERO ## the changed screen's pixels now
var _vs_width_m := 0.0       ## and its width in metres
var _vs_distance := 1.25
var _vs_ppd := 20.0
var _vs_tween: Tween

# Space tab
var _look_buttons: Dictionary = {}
var _chk_layers: CheckButton

# Quality tab
var _codec_buttons: Dictionary = {}
var _res_buttons: Dictionary = {}
var _fps_buttons: Dictionary = {}
var _slider_bitrate: HSlider
var _lbl_bitrate_value: Label
var _slider_jpegq: HSlider
var _lbl_jpegq_value: Label
var _lbl_auto_info: Label
var _apply_debounce: Timer
var _slider_held := false  ## a Quality slider is being dragged

# Input tab
var _hand_buttons: Dictionary = {}
var _slider_ray: HSlider
var _lbl_ray_value: Label
var _chk_face_me: CheckButton
var _chk_haptics: CheckButton

# Styles
var _st_button: Dictionary
var _st_primary: Dictionary
var _st_selected: StyleBoxFlat

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_build_ui()
	hide()

func _process(delta: float) -> void:
	if _drag:
		_drag.update(delta)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func toggle_visibility() -> void:
	set_shown(not _visible_overlay)

func set_shown(show_it: bool) -> void:
	if show_it == _visible_overlay:
		return
	_visible_overlay = show_it
	if show_it:
		show()
		_reposition_in_front_of_camera()
	else:
		hide()
		_drag = null
	# A SubViewport is not a Node3D: hiding this node does not stop it
	# rendering, so switch it off explicitly while nobody looks at it.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if show_it \
		else SubViewport.UPDATE_DISABLED

func is_shown() -> bool:
	return _visible_overlay

func set_state(state: ConnectionState) -> void:
	# Just connected: the screens are what the user wants next.
	if _state == ConnectionState.CONNECTING and state == ConnectionState.CONNECTED:
		_select_tab(1)
	_state = state
	if state != ConnectionState.DISCONNECTED:
		_lbl_ip_error.hide()
	_refresh_connect_tab()
	_refresh_status()
	_rebuild_monitor_list()

## Name (or address) of the PC the headset talks to, for the status line.
func set_host_label(label: String) -> void:
	_host_label = label
	_refresh_status()
	_refresh_connect_tab()

## How the headset reaches the PC ("USB", "Wi-Fi", "" = don't say), for the
## status line.
func set_link(link: String) -> void:
	_link = link
	_refresh_status()
	_refresh_connect_tab()

## The address shown in the manual-entry field.
func set_host_address(ip: String, tcp_port: int = 19800, udp_port: int = 19801) -> void:
	_host_ip = ip
	_tcp_port = tcp_port
	_udp_port = udp_port
	if _input_ip and not ip.begins_with("127."):
		_input_ip.text = ip

func set_latency(ms: float) -> void:
	_ping_ms = ms
	_refresh_status()

func set_stream_stats(fps: float, mbps: float) -> void:
	_stats = {"fps": fps, "mbps": mbps}
	_refresh_status()

## Facts about the live connection, shown on the Connect tab: an array of
## [label, value] pairs (address, link, picture, sound…).
func set_connection_details(rows: Array) -> void:
	for c in _details_grid.get_children():
		c.queue_free()
	for r in rows:
		var k := _label(r[0], 19, UiTheme.INK_3)
		k.custom_minimum_size.x = 150
		_details_grid.add_child(k)
		_details_grid.add_child(_label(r[1], 19, UiTheme.INK))

## What the connected PC allows: view_only = it takes no input
## (--view-only); virtual = it can make extra, virtual screens.
func set_host_capabilities(view_only: bool, virtual: bool) -> void:
	_host_view_only = view_only
	_host_virtual = virtual
	_refresh_control()
	_rebuild_monitor_list()

func set_input_settings(control: bool, haptics: bool) -> void:
	_control_enabled = control
	_haptics_enabled = haptics
	_refresh_control()
	if _chk_haptics:
		_chk_haptics.set_pressed_no_signal(haptics)

func set_pointer_settings(hand: String, ray_angle: float, face_me: bool) -> void:
	_pointer_hand = hand
	_ray_angle = ray_angle
	_face_me = face_me
	_refresh_input_tab()

func set_compositor_layers(enabled: bool, _supported: bool = true) -> void:
	_layers_enabled = enabled
	if _chk_layers:
		_chk_layers.set_pressed_no_signal(enabled)

func _refresh_control() -> void:
	if not _chk_control:
		return
	_chk_control.set_pressed_no_signal(_control_enabled and not _host_view_only)
	_chk_control.disabled = _host_view_only
	_lbl_control_note.text = "This PC shares its screens but takes no input (started with --view-only)." \
		if _host_view_only else "Off: you can look and move screens, but nothing is clicked or typed on the PC."
	_lbl_control_note.visible = _host_view_only or not _control_enabled

## A one-line message under the header ("" hides it).
func set_notice(text: String) -> void:
	_notice = text
	_lbl_notice.text = text
	_lbl_notice.visible = not text.is_empty()

func set_discovered_hosts(hosts: Array) -> void:
	_discovered = hosts
	_rebuild_hosts_list()

## Ask for the host's PIN. reason: 1 = first time, 2 = the last one was wrong.
func show_pin_prompt(reason: int, host_label: String) -> void:
	_pin_visible = true
	_pin_digits = ""
	_lbl_pin_title.text = "Pair with %s" % host_label
	_lbl_pin_error.visible = reason == 2
	_select_tab(0)
	_refresh_pin_cells()
	_refresh_connect_tab()
	set_shown(true)

func hide_pin_prompt() -> void:
	_pin_visible = false
	_refresh_connect_tab()

func set_monitor_list(monitors: Array) -> void:
	_available_monitors = monitors
	_rebuild_monitor_list()

func set_active_monitors(ids: Array) -> void:
	_active_monitor_ids = ids.duplicate()
	_rebuild_monitor_list()

func set_linked_monitors(ids: Array) -> void:
	_linked_ids = ids.duplicate()
	_rebuild_monitor_list()

func set_layout_options(snap: bool, lock: bool) -> void:
	_snap_enabled = snap
	_lock_enabled = lock
	if _chk_snap:
		_chk_snap.set_pressed_no_signal(snap)
		_chk_lock.set_pressed_no_signal(lock)

func set_screen_curvature(enabled: bool, amount: float) -> void:
	_curved_enabled = enabled
	_curvature_amount = clampf(amount, 0.0, 1.0)
	if _slider_curvature:
		_slider_curvature.set_value_no_signal(_curvature_amount * 100.0 if enabled else 0.0)
		_lbl_curvature_value.text = _curve_text()

func set_look(look: String, passthrough_supported: bool) -> void:
	_look = look
	_passthrough_supported = passthrough_supported
	_refresh_segmented(_look_buttons, _look)
	if _look_buttons.has("passthrough"):
		(_look_buttons["passthrough"] as Button).disabled = not passthrough_supported
		(_look_buttons["passthrough"] as Button).tooltip_text = "" if passthrough_supported \
			else "This headset's OpenXR runtime has no passthrough"

## Kept for older callers: passthrough is one of the Space looks now.
func set_passthrough_settings(enabled: bool, supported: bool = true) -> void:
	set_look("passthrough" if enabled else (_look if _look != "passthrough" else "night"), supported)

func set_stream_settings(codec: int, bitrate_kbps: int, jpeg_quality: int,
		res_percent: int, fps: int) -> void:
	_stream_codec = codec
	_bitrate_kbps = bitrate_kbps
	_jpeg_quality = jpeg_quality
	_res_percent = res_percent
	_fps_value = fps
	_refresh_quality_ui()

func set_auto_quality_result(width: int, height: int, fps: int,
		ppd: float, angle_deg: float, distance: float) -> void:
	_lbl_auto_info.text = "Auto picked %d×%d at %d fps: the screen spans %.0f° at %.1f m and this headset shows about %.0f px per degree." % [
		width, height, fps, angle_deg, distance, ppd]
	_lbl_auto_info.show()

# ---------------------------------------------------------------------------
# Pointer injection (vr_input.gd / hand_input.gd via main.gd)
# ---------------------------------------------------------------------------

## Ray against the menu plane. Returns { valid, uv, distance }.
func ray_to_overlay_hit(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	if not visible or not _panel_mesh:
		return {"valid": false}
	var local_o := _panel_mesh.global_transform.affine_inverse() * ray_origin
	var local_d := _panel_mesh.global_basis.inverse() * ray_direction
	if absf(local_d.z) < 0.0001:
		return {"valid": false}
	var t := -local_o.z / local_d.z
	if t < 0.0:
		return {"valid": false}
	var hit := local_o + local_d * t
	var uv := Vector2(hit.x / panel_width + 0.5, 0.5 - hit.y / panel_height)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return {"valid": false}
	return {"valid": true, "uv": uv, "distance": t}

func inject_pointer_move(uv: Vector2) -> void:
	_last_pointer_uv = uv
	var px := uv * Vector2(VIEW_SIZE)
	var ev := InputEventMouseMotion.new()
	ev.position = px
	ev.global_position = px
	_viewport.push_input(ev)

func inject_pointer_button(pressed: bool, button_index: int = MOUSE_BUTTON_LEFT) -> void:
	var px := _last_pointer_uv * Vector2(VIEW_SIZE)
	var ev := InputEventMouseButton.new()
	ev.button_index = button_index
	ev.pressed = pressed
	ev.position = px
	ev.global_position = px
	_viewport.push_input(ev)

func inject_pointer_scroll(delta_y: float) -> void:
	var px := _last_pointer_uv * Vector2(VIEW_SIZE)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_UP if delta_y > 0 else MOUSE_BUTTON_WHEEL_DOWN
		ev.pressed = pressed
		ev.factor = absf(delta_y)
		ev.position = px
		ev.global_position = px
		_viewport.push_input(ev)

# ---------------------------------------------------------------------------
# Grab to move
# ---------------------------------------------------------------------------

func start_drag(pointer: Node3D, hit_distance: float = -1.0) -> void:
	if pointer:
		_drag = LaserDrag.new(self, pointer, hit_distance)

func stop_drag() -> void:
	_drag = null

func is_dragging() -> bool:
	return _drag != null

func push_pull(delta_m: float) -> void:
	if _drag:
		_drag.push_pull(delta_m)

func get_drag_distance() -> float:
	return _drag.distance if _drag else 0.0

func _reposition_in_front_of_camera() -> void:
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return
	var fwd := -camera.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 0.0001 else Vector3.FORWARD
	var pos := camera.global_position + fwd * panel_distance + Vector3(0.0, -0.1, 0.0)
	global_transform = Transform3D(LaserDrag.facing_basis(pos, camera.global_position), pos)

# ---------------------------------------------------------------------------
# Building blocks
# ---------------------------------------------------------------------------

func _label(text: String, size: int = 20, color: Color = UiTheme.INK, display := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if display:
		l.add_theme_font_override("font", UiTheme.display_font())
	return l

func _button(text: String, primary := false) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	_style_button(b, _st_primary if primary else _st_button)
	return b

func _style_button(b: Button, st: Dictionary) -> void:
	for k in ["normal", "hover", "pressed", "disabled"]:
		b.add_theme_stylebox_override(k, st[k])
	b.add_theme_stylebox_override("hover_pressed", st["pressed"])
	b.add_theme_stylebox_override("focus", UiTheme.empty())
	b.add_theme_color_override("font_color", st["font"])
	b.add_theme_color_override("font_hover_color", st["font"])
	b.add_theme_color_override("font_pressed_color", UiTheme.GROUND)
	b.add_theme_color_override("font_hover_pressed_color", UiTheme.GROUND)
	b.add_theme_color_override("font_disabled_color", UiTheme.INK_3)
	b.add_theme_font_size_override("font_size", 20)

func _hbox(sep: int = 10) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h

func _vbox(sep: int = 10) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v

func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c

## Heading that opens a group of settings: plain sentence case. The display
## face is kept for the wordmark and big titles; at this size its squared
## letters read worse in a headset than the neutral face.
func _heading(parent: Control, text: String) -> void:
	parent.add_child(_label(text, 22, UiTheme.INK))

## Mutually-exclusive options in a sunken well. options = [[label, value], …].
func _segmented(parent: Control, options: Array, on_chosen: Callable) -> Dictionary:
	var well := PanelContainer.new()
	well.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.WELL, 12, 4, 4))
	well.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(well)
	var row := _hbox(4)
	well.add_child(row)
	var buttons := {}
	for opt in options:
		var b := Button.new()
		b.text = opt[0]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 19)
		var plain := UiTheme.box(Color(0, 0, 0, 0), 9, 10, 8)
		var hover := UiTheme.box(UiTheme.SURFACE_HI, 9, 10, 8)
		b.add_theme_stylebox_override("normal", plain)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_stylebox_override("pressed", _st_selected)
		b.add_theme_stylebox_override("hover_pressed", _st_selected)
		b.add_theme_stylebox_override("disabled", plain)
		b.add_theme_stylebox_override("focus", UiTheme.empty())
		b.add_theme_color_override("font_color", UiTheme.INK_2)
		b.add_theme_color_override("font_hover_color", UiTheme.INK)
		b.add_theme_color_override("font_pressed_color", UiTheme.GROUND)
		b.add_theme_color_override("font_hover_pressed_color", UiTheme.GROUND)
		b.add_theme_color_override("font_disabled_color", Color(UiTheme.INK_3, 0.6))
		var value = opt[1]
		b.pressed.connect(func(): on_chosen.call(value))
		row.add_child(b)
		buttons[value] = b
	return buttons

func _refresh_segmented(buttons: Dictionary, selected) -> void:
	for value in buttons:
		(buttons[value] as Button).set_pressed_no_signal(value == selected)

## A labelled slider row; the value label is returned in [slider, label].
func _slider_row(parent: Control, title: String, min_v: float, max_v: float,
		step: float, on_change: Callable) -> Array:
	var row := _hbox(16)
	parent.add_child(row)
	var t := _label(title, 20, UiTheme.INK_2)
	t.custom_minimum_size.x = 170
	row.add_child(t)
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.focus_mode = Control.FOCUS_NONE
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.value_changed.connect(on_change)
	row.add_child(s)
	var v := _label("", 20, UiTheme.INK)
	v.custom_minimum_size.x = 110
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	return [s, v]

func _set_slider_active(slider: HSlider, active: bool) -> void:
	slider.editable = active
	slider.modulate.a = 1.0 if active else 0.35

## Round knob / switch textures drawn once, so no stock Godot art shows up.
static func _disc(diameter: int, color: Color) -> ImageTexture:
	var img := Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	var r := diameter / 2.0
	for y in diameter:
		for x in diameter:
			var d := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			img.set_pixel(x, y, Color(color, color.a * clampf(r - d, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)

static func _switch(on: bool) -> ImageTexture:
	var w := 52
	var h := 30
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var track := UiTheme.INK if on else UiTheme.SURFACE_HOVER
	var knob := UiTheme.GROUND if on else UiTheme.INK_2
	var r := h / 2.0
	var kx := w - r if on else r
	for y in h:
		for x in w:
			var p := Vector2(x + 0.5, y + 0.5)
			var cx := clampf(p.x, r, w - r)
			var dt := p.distance_to(Vector2(cx, r))
			var c := Color(track, clampf(r - dt, 0.0, 1.0))
			var dk := p.distance_to(Vector2(kx, r))
			var ka := clampf(r - 4.0 - dk, 0.0, 1.0)
			if ka > 0.0:
				c = c.lerp(Color(knob, 1.0), ka)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

func _make_theme() -> Theme:
	var t := Theme.new()
	t.set_font_size("font_size", "Label", 20)
	t.set_color("font_color", "Label", UiTheme.INK)
	# Sliders: a sunken track, the filled part in bone, a round bone knob.
	var track := UiTheme.box(UiTheme.WELL, 4, 0, 4)
	var fill := UiTheme.box(UiTheme.INK_2, 4, 0, 4)
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", UiTheme.box(UiTheme.INK, 4, 0, 4))
	var knob := _disc(30, UiTheme.INK)
	t.set_icon("grabber", "HSlider", knob)
	t.set_icon("grabber_highlight", "HSlider", knob)
	t.set_icon("grabber_disabled", "HSlider", _disc(30, UiTheme.INK_3))
	# Switches.
	t.set_icon("checked", "CheckButton", _switch(true))
	t.set_icon("unchecked", "CheckButton", _switch(false))
	t.set_icon("checked_disabled", "CheckButton", _switch(false))
	t.set_icon("unchecked_disabled", "CheckButton", _switch(false))
	for k in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		t.set_stylebox(k, "CheckButton", UiTheme.box(Color(0, 0, 0, 0), 8, 0, 6))
	t.set_font_size("font_size", "CheckButton", 20)
	t.set_color("font_color", "CheckButton", UiTheme.INK)
	t.set_color("font_hover_color", "CheckButton", UiTheme.INK)
	t.set_color("font_pressed_color", "CheckButton", UiTheme.INK)
	t.set_color("font_hover_pressed_color", "CheckButton", UiTheme.INK)
	t.set_color("font_disabled_color", "CheckButton", UiTheme.INK_3)
	# Text field.
	t.set_stylebox("normal", "LineEdit", UiTheme.box(UiTheme.WELL, 10, 14, 10))
	t.set_stylebox("focus", "LineEdit", UiTheme.box(UiTheme.WELL, 10, 14, 10, UiTheme.EDGE_HI))
	t.set_stylebox("read_only", "LineEdit", UiTheme.box(UiTheme.WELL, 10, 14, 10))
	t.set_font_size("font_size", "LineEdit", 24)
	t.set_color("font_color", "LineEdit", UiTheme.INK)
	t.set_color("font_uneditable_color", "LineEdit", UiTheme.INK_2)
	t.set_color("font_placeholder_color", "LineEdit", UiTheme.INK_3)
	t.set_color("caret_color", "LineEdit", UiTheme.INK)
	t.set_color("selection_color", "LineEdit", Color(UiTheme.INK, 0.25))
	# Scrolling: a thin bone bar, no track.
	t.set_stylebox("scroll", "VScrollBar", UiTheme.empty())
	t.set_stylebox("grabber", "VScrollBar", UiTheme.box(Color(UiTheme.INK, 0.25), 3, 3, 0))
	t.set_stylebox("grabber_highlight", "VScrollBar", UiTheme.box(Color(UiTheme.INK, 0.45), 3, 3, 0))
	t.set_stylebox("grabber_pressed", "VScrollBar", UiTheme.box(Color(UiTheme.INK, 0.6), 3, 3, 0))
	return t

# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_st_button = {
		"normal": UiTheme.box(UiTheme.SURFACE_HI, 10, 18, 11),
		"hover": UiTheme.box(UiTheme.SURFACE_HOVER, 10, 18, 11),
		"pressed": UiTheme.box(UiTheme.INK, 10, 18, 11),
		"disabled": UiTheme.box(UiTheme.SURFACE, 10, 18, 11),
		"font": UiTheme.INK,
	}
	_st_primary = {
		"normal": UiTheme.box(UiTheme.INK, 10, 18, 11),
		"hover": UiTheme.box(Color("d8d0c3"), 10, 18, 11),
		"pressed": UiTheme.box(UiTheme.INK_2, 10, 18, 11),
		"disabled": UiTheme.box(UiTheme.SURFACE, 10, 18, 11),
		"font": UiTheme.GROUND,
	}
	_st_selected = UiTheme.box(UiTheme.INK, 9, 10, 8)

	_viewport = SubViewport.new()
	_viewport.size = VIEW_SIZE
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_canvas = CanvasLayer.new()
	_viewport.add_child(_canvas)

	var root := PanelContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = _make_theme()
	root.add_theme_stylebox_override("panel",
		UiTheme.box(Color(UiTheme.GROUND, 0.97), 28, 34, 26, UiTheme.EDGE))
	_canvas.add_child(root)

	var column := _vbox(0)
	root.add_child(column)

	# Header: wordmark, live status, close.
	var header := _hbox(18)
	column.add_child(header)
	header.add_child(_label("Immersive", 34, UiTheme.INK, true))
	var status := _hbox(10)
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.alignment = BoxContainer.ALIGNMENT_BEGIN
	header.add_child(status)
	_status_dot = Panel.new()
	_status_dot.custom_minimum_size = Vector2(12, 12)
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status.add_child(_status_dot)
	_lbl_status = _label("", 19, UiTheme.INK_2)
	_lbl_status.clip_text = true
	_lbl_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.add_child(_lbl_status)
	var close := _button("Close")
	close.pressed.connect(func(): set_shown(false))
	header.add_child(close)

	_lbl_notice = _label("", 18, UiTheme.CLAY)
	_lbl_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_notice.hide()
	column.add_child(_lbl_notice)

	# Tabs with a sliding indicator.
	var tabs_wrap := _vbox(0)
	tabs_wrap.add_theme_constant_override("separation", 2)
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 14
	column.add_child(spacer)
	column.add_child(tabs_wrap)
	var tab_row := _hbox(6)
	tabs_wrap.add_child(tab_row)
	for i in TAB_NAMES.size():
		var b := Button.new()
		b.text = TAB_NAMES[i]
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 23)
		for k in ["normal", "pressed", "hover_pressed", "focus", "disabled"]:
			b.add_theme_stylebox_override(k, UiTheme.box(Color(0, 0, 0, 0), 8, 14, 8))
		b.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.SURFACE, 8, 14, 8))
		b.pressed.connect(_select_tab.bind(i))
		tab_row.add_child(b)
		_tab_buttons.append(b)
	var rail := Control.new()
	rail.custom_minimum_size.y = 4
	tabs_wrap.add_child(rail)
	# A short bar with round ends under the active tab (slides between tabs).
	_tab_indicator = Panel.new()
	var bar := StyleBoxFlat.new()
	bar.bg_color = UiTheme.INK
	bar.set_corner_radius_all(2)
	bar.anti_aliasing = true
	_tab_indicator.add_theme_stylebox_override("panel", bar)
	_tab_indicator.size = Vector2(60, 4)
	rail.add_child(_tab_indicator)
	tab_row.resized.connect(func(): _move_tab_indicator(false))

	var gap := Control.new()
	gap.custom_minimum_size.y = 18
	column.add_child(gap)

	var pages := Control.new()
	pages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(pages)
	for builder in [_build_connect_tab, _build_screens_tab, _build_space_tab, _build_quality_tab, _build_input_tab]:
		var page := ScrollContainer.new()
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		pages.add_child(page)
		var body := _vbox(14)
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.add_child(body)
		builder.call(body)
		_tab_pages.append(page)
	# The virtual screen size page shows over the Screens tab.
	_vs_scroll = ScrollContainer.new()
	_vs_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vs_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_vs_scroll.hide()
	pages.add_child(_vs_scroll)
	var vs_body := _vbox(12)
	vs_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vs_scroll.add_child(vs_body)
	_build_virtual_page(vs_body)

	_apply_debounce = Timer.new()
	_apply_debounce.one_shot = true
	_apply_debounce.timeout.connect(_emit_stream_settings)
	add_child(_apply_debounce)

	_panel_mesh = MeshInstance3D.new()
	var plane := QuadMesh.new()
	plane.size = Vector2(panel_width, panel_height)
	_panel_mesh.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _viewport.get_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	_panel_mesh.material_override = mat
	_panel_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_panel_mesh)
	grab_bar = GrabBar.new()
	grab_bar.always_shown = true
	grab_bar.position = Vector3(0.0, -panel_height / 2.0 - 0.045, 0.0)
	add_child(grab_bar)

	_select_tab(0)
	_refresh_status()
	_refresh_connect_tab()
	_rebuild_hosts_list()
	_rebuild_monitor_list()
	_refresh_quality_ui()
	_refresh_input_tab()
	set_screen_curvature(_curved_enabled, _curvature_amount)
	set_look(_look, _passthrough_supported)
	_refresh_control()

func _select_tab(i: int) -> void:
	_tab = i
	if _vs_scroll:
		_vs_scroll.hide()
	for j in _tab_pages.size():
		_tab_pages[j].visible = j == i
		var b: Button = _tab_buttons[j]
		var c := UiTheme.INK if j == i else UiTheme.INK_3
		for k in ["font_color", "font_pressed_color", "font_hover_pressed_color"]:
			b.add_theme_color_override(k, c)
		b.add_theme_color_override("font_hover_color", UiTheme.INK)
	_move_tab_indicator(true)

## Slide the bar under the active tab (snap when the layout itself moved).
func _move_tab_indicator(animate: bool) -> void:
	if _tab_buttons.is_empty():
		return
	var b: Button = _tab_buttons[_tab]
	var target := Vector2(b.position.x + 14, 0)
	var width := maxf(b.size.x - 28, 20)
	if _tab_tween:
		_tab_tween.kill()
	if animate and is_inside_tree() and _visible_overlay:
		_tab_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_tab_tween.tween_property(_tab_indicator, "position", target, 0.18)
		_tab_tween.tween_property(_tab_indicator, "size:x", width, 0.18)
	else:
		_tab_indicator.position = target
		_tab_indicator.size.x = width

# ---------------------------------------------------------------------------
# Connect tab
# ---------------------------------------------------------------------------

func _build_connect_tab(body: VBoxContainer) -> void:
	# Connected / connecting summary.
	_connected_box = _vbox(14)
	body.add_child(_connected_box)
	_lbl_connected = _label("", 26, UiTheme.INK, true)
	_lbl_connected.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_connected_box.add_child(_lbl_connected)
	_details_grid = GridContainer.new()
	_details_grid.columns = 2
	_details_grid.add_theme_constant_override("h_separation", 24)
	_details_grid.add_theme_constant_override("v_separation", 10)
	_connected_box.add_child(_details_grid)
	_chk_control = CheckButton.new()
	_chk_control.text = "Control this PC with the pointer and keyboards"
	_chk_control.focus_mode = Control.FOCUS_NONE
	_chk_control.toggled.connect(func(on):
		_control_enabled = on
		_refresh_control()
		control_toggled.emit(on))
	_connected_box.add_child(_chk_control)
	_lbl_control_note = _label("", 17, UiTheme.INK_3)
	_lbl_control_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_connected_box.add_child(_lbl_control_note)
	var crow := _hbox(10)
	_connected_box.add_child(crow)
	_btn_disconnect = _button("Disconnect")
	_btn_disconnect.pressed.connect(func(): connect_requested.emit("", 0, 0))
	crow.add_child(_btn_disconnect)

	# Two columns: PCs found on the network | an address by hand.
	_connect_main = _hbox(28)
	_connect_main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_connect_main)

	var found := _vbox(12)
	found.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	found.size_flags_stretch_ratio = 1.35
	_connect_main.add_child(found)
	_heading(found, "PCs on this network")
	_hosts_list = _vbox(10)
	found.add_child(_hosts_list)

	_manual_box = _vbox(12)
	_manual_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_connect_main.add_child(_manual_box)
	_heading(_manual_box, "Or type its address")
	_input_ip = LineEdit.new()
	_input_ip.placeholder_text = "192.168.1.20"
	_input_ip.max_length = 15
	_input_ip.virtual_keyboard_enabled = false  # never the Android system keyboard
	_input_ip.text = _host_ip
	_input_ip.text_changed.connect(func(_t): _lbl_ip_error.hide())
	_input_ip.text_submitted.connect(func(_t): _on_connect_pressed())
	_manual_box.add_child(_input_ip)
	_lbl_ip_error = _label("Four numbers with dots, like 192.168.1.20", 17, UiTheme.CLAY)
	_lbl_ip_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_ip_error.hide()
	_manual_box.add_child(_lbl_ip_error)
	_manual_box.add_child(_keypad(["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "⌫"],
		_on_ip_key))
	_btn_connect = _button("Connect", true)
	_btn_connect.pressed.connect(_on_connect_pressed)
	_manual_box.add_child(_btn_connect)
	# Another way in rather than a second button: a quiet line of text.
	_btn_usb = Button.new()
	_btn_usb.text = "Plugged in with a USB cable? Connect over USB"
	_btn_usb.flat = true
	_btn_usb.focus_mode = Control.FOCUS_NONE
	_btn_usb.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_btn_usb.tooltip_text = "Needs adb on the PC"
	_btn_usb.add_theme_font_size_override("font_size", 17)
	for k in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		_btn_usb.add_theme_stylebox_override(k, UiTheme.box(Color(0, 0, 0, 0), 6, 0, 4))
	_btn_usb.add_theme_color_override("font_color", UiTheme.INK_2)
	_btn_usb.add_theme_color_override("font_hover_color", UiTheme.INK)
	_btn_usb.add_theme_color_override("font_pressed_color", UiTheme.INK)
	_btn_usb.add_theme_color_override("font_hover_pressed_color", UiTheme.INK)
	_btn_usb.add_theme_color_override("font_disabled_color", UiTheme.INK_3)
	_btn_usb.pressed.connect(_on_usb_pressed)
	_manual_box.add_child(_btn_usb)

	# PIN pairing card.
	_pin_box = _vbox(16)
	_pin_box.hide()
	body.add_child(_pin_box)
	_lbl_pin_title = _label("Pair with this PC", 30, UiTheme.INK, true)
	_pin_box.add_child(_lbl_pin_title)
	var hint := _label("Your PC just showed a notification with a six-digit PIN. Type it here. You only do this once.", 19, UiTheme.INK_2)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pin_box.add_child(hint)
	var pin_row := _hbox(26)
	_pin_box.add_child(pin_row)
	var cells := _hbox(10)
	pin_row.add_child(cells)
	for i in 6:
		var cell := Label.new()
		cell.custom_minimum_size = Vector2(56, 70)
		cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cell.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cell.add_theme_font_size_override("font_size", 36)
		cell.add_theme_color_override("font_color", UiTheme.INK)
		cell.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.WELL, 10, 0, 0))
		cells.add_child(cell)
		_pin_cells.append(cell)
	var pad_col := _vbox(10)
	pad_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pin_row.add_child(pad_col)
	pad_col.add_child(_keypad(["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "OK"], _on_pin_key))
	_lbl_pin_error = _label("That PIN did not match. Check the notification on the PC and try again.", 18, UiTheme.CLAY)
	_lbl_pin_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_pin_error.hide()
	_pin_box.add_child(_lbl_pin_error)
	var cancel := _button("Cancel")
	cancel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	cancel.pressed.connect(func():
		hide_pin_prompt()
		pin_cancelled.emit())
	_pin_box.add_child(cancel)

## A 3 × 4 grid of keys that never take focus (the field keeps its caret).
func _keypad(keys: Array, on_key: Callable) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	for k in keys:
		var b := _button(k, k == "OK")
		var st: Dictionary = (_st_primary if k == "OK" else _st_button).duplicate()
		for state in ["normal", "hover", "pressed", "disabled"]:
			var box: StyleBoxFlat = st[state].duplicate()
			box.content_margin_top = 4
			box.content_margin_bottom = 4
			st[state] = box
		_style_button(b, st)
		b.custom_minimum_size = Vector2(0, 50)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 26)
		b.pressed.connect(on_key.bind(k))
		grid.add_child(b)
	return grid

func _refresh_connect_tab() -> void:
	if not _connect_main:
		return
	var disconnected := _state == ConnectionState.DISCONNECTED
	_pin_box.visible = _pin_visible and disconnected
	_connect_main.visible = disconnected and not _pin_box.visible
	_connected_box.visible = not disconnected
	var who := _host_label if not _host_label.is_empty() else "the PC"
	if not _link.is_empty():
		who += " over " + _link
	match _state:
		ConnectionState.CONNECTING:
			_lbl_connected.text = "Connecting to %s…" % who
			_btn_disconnect.text = "Cancel"
		ConnectionState.CONNECTED, ConnectionState.STREAMING:
			_lbl_connected.text = "Connected to %s" % who
			_btn_disconnect.text = "Disconnect"
	_input_ip.editable = disconnected
	_btn_usb.disabled = not disconnected
	_btn_connect.disabled = not disconnected

func _rebuild_hosts_list() -> void:
	if not _hosts_list:
		return
	for c in _hosts_list.get_children():
		c.queue_free()
	if _discovered.is_empty():
		var l := _label("Looking for PCs running the Immersive-2 host… Start it on the PC and keep the headset on the same Wi-Fi.", 19, UiTheme.INK_3)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_hosts_list.add_child(l)
		return
	for h in _discovered:
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SURFACE, 14, 18, 14))
		_hosts_list.add_child(card)
		var row := _hbox(14)
		card.add_child(row)
		var text := _vbox(2)
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(text)
		var name_l := _label(h.name, 24, UiTheme.INK, true)
		name_l.clip_text = true
		text.add_child(name_l)
		var meta := "%s · %d %s" % [h.ip, h.monitors, "screen" if h.monitors == 1 else "screens"]
		if h.pin_required and not h.ip.begins_with("127."):
			meta += " · asks for a PIN"
		if h.get("view_only", false):
			meta += " · view only"
		text.add_child(_label(meta, 17, UiTheme.INK_3))
		var b := _button("Connect", true)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var ip: String = h.ip
		var port: int = h.port
		b.pressed.connect(func(): connect_requested.emit(ip, port, _udp_port))
		row.add_child(b)

func _refresh_pin_cells() -> void:
	for i in _pin_cells.size():
		(_pin_cells[i] as Label).text = _pin_digits[i] if i < _pin_digits.length() else ""

func _on_pin_key(k: String) -> void:
	match k:
		"⌫":
			_pin_digits = _pin_digits.left(-1)
		"OK":
			if _pin_digits.length() == 6:
				var pin := int(_pin_digits)
				hide_pin_prompt()
				pin_entered.emit(pin)
			return
		_:
			if _pin_digits.length() < 6:
				_pin_digits += k
	_lbl_pin_error.hide()
	_refresh_pin_cells()

func _on_ip_key(k: String) -> void:
	if not _input_ip.editable:
		return
	_lbl_ip_error.hide()
	if k == "⌫":
		_input_ip.text = _input_ip.text.left(-1)
	elif _input_ip.text.length() < _input_ip.max_length:
		_input_ip.text += k
	_input_ip.caret_column = _input_ip.text.length()

func _on_connect_pressed() -> void:
	if _state != ConnectionState.DISCONNECTED:
		connect_requested.emit("", 0, 0)
		return
	var ip := _input_ip.text.strip_edges()
	# A bad address would just fail and retry forever: say so here instead.
	if not ip.is_valid_ip_address():
		_lbl_ip_error.show()
		return
	_host_ip = ip
	connect_requested.emit(ip, _tcp_port, _udp_port)

## Headset on a USB cable: the host's `adb reverse` answers on the headset's
## own 127.0.0.1 (main.gd then streams over TCP).
func _on_usb_pressed() -> void:
	connect_requested.emit("127.0.0.1", _tcp_port, _udp_port)

# ---------------------------------------------------------------------------
# Screens tab
# ---------------------------------------------------------------------------

func _build_screens_tab(body: VBoxContainer) -> void:
	_heading(body, "Screens to show")
	_monitor_list = _vbox(8)
	body.add_child(_monitor_list)

	var actions := _hbox(10)
	body.add_child(actions)
	_btn_arrange = _button("Arrange around me")
	_btn_arrange.pressed.connect(func(): arrange_requested.emit())
	actions.add_child(_btn_arrange)
	_btn_recenter = _button("Bring in front")
	_btn_recenter.pressed.connect(func(): recenter_requested.emit())
	actions.add_child(_btn_recenter)
	_btn_keyboard = _button("Keyboard")
	_btn_keyboard.pressed.connect(func(): keyboard_toggle_requested.emit())
	actions.add_child(_btn_keyboard)
	# An extra screen that exists only in the headset (the PC makes it).
	_btn_add_virtual = _button("New virtual screen")
	_btn_add_virtual.pressed.connect(func(): virtual_page_requested.emit(-1))
	actions.add_child(_btn_add_virtual)

	var tip := _label("Move a screen by the bar under it, or hold the grip on it. While held, the stick sets its distance and size.", 17, UiTheme.INK_3)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(tip)

	var sp := Control.new()
	sp.custom_minimum_size.y = 4
	body.add_child(sp)
	var r := _slider_row(body, "Curvature", 0, 100, 1, _on_curvature_changed)
	_slider_curvature = r[0]
	_lbl_curvature_value = r[1]

func _curve_text() -> String:
	var amount := _curvature_amount if _curved_enabled else 0.0
	return "Flat" if amount <= 0.001 else "%d%%" % int(round(amount * 100.0))

func _rebuild_monitor_list() -> void:
	if not _monitor_list:
		return
	for c in _monitor_list.get_children():
		c.queue_free()
	var connected := _state == ConnectionState.CONNECTED or _state == ConnectionState.STREAMING
	for b in [_btn_arrange, _btn_recenter]:
		b.disabled = not connected
	_btn_add_virtual.visible = connected and _host_virtual
	if _vs_scroll.visible and (not _btn_add_virtual.visible or (_vs_id >= 0
			and not _available_monitors.any(func(m): return m.get("id", -1) == _vs_id))):
		_show_virtual_page(false)
	if not connected or _available_monitors.is_empty():
		var l := _label("Connect to a PC to see its screens." if not connected \
			else "This PC reported no screens.", 19, UiTheme.INK_3)
		_monitor_list.add_child(l)
		return
	var any_virtual := _available_monitors.any(func(m): return m.get("virtual", false))
	for mon in _available_monitors:
		var mid: int = mon.get("id", 0)
		var on: bool = _active_monitor_ids.has(mid)
		var row := CheckButton.new()
		row.text = "%s    %d × %d · %d Hz" % [mon.get("name", "Monitor"),
			mon.get("width", 0), mon.get("height", 0), mon.get("refresh_rate", 60)]
		row.button_pressed = on
		row.focus_mode = Control.FOCUS_NONE
		row.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.SURFACE_HI if on else UiTheme.SURFACE, 12, 18, 12))
		row.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.SURFACE_HOVER, 12, 18, 12))
		row.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.SURFACE_HI, 12, 18, 12))
		row.add_theme_stylebox_override("hover_pressed", UiTheme.box(UiTheme.SURFACE_HOVER, 12, 18, 12))
		row.add_theme_color_override("font_color", UiTheme.INK_2)
		row.toggled.connect(func(_on): monitor_selected.emit(mid))
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var line := _hbox(8)
		line.add_child(row)
		_monitor_list.add_child(line)
		# "Together": linked screens move as one block when grabbed.
		var together := CheckButton.new()
		together.text = "Move together"
		together.focus_mode = Control.FOCUS_NONE
		together.custom_minimum_size.x = 220
		together.button_pressed = _linked_ids.has(mid)
		together.disabled = not on
		together.modulate.a = 1.0 if on else 0.35
		together.toggled.connect(func(l):
			if l:
				_linked_ids.append(mid)
			else:
				_linked_ids.erase(mid)
			screen_link_changed.emit(mid, l))
		line.add_child(together)
		if not any_virtual:
			continue
		# Every row keeps the same trailing slot, so the switches line up;
		# a virtual screen fills it with its Size and Remove buttons.
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(204, 0)
		line.add_child(slot)
		if mon.get("virtual", false):
			var btns := _hbox(6)
			btns.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			slot.add_child(btns)
			var size_btn := _button("Size")
			size_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			size_btn.disabled = not on  # its spot and width set the 1:1 size
			size_btn.pressed.connect(func(): virtual_page_requested.emit(mid))
			btns.add_child(size_btn)
			var remove := _button("Remove")
			remove.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			remove.pressed.connect(func(): virtual_screen_remove_requested.emit(mid))
			btns.add_child(remove)

func _on_curvature_changed(value: float) -> void:
	_curvature_amount = value / 100.0
	_curved_enabled = value > 0.0
	_lbl_curvature_value.text = _curve_text()
	screen_curvature_changed.emit(_curved_enabled, maxf(_curvature_amount, 0.0))

# ---------------------------------------------------------------------------
# Virtual screen size page
# ---------------------------------------------------------------------------

## Open the size page. monitor_id -1: a new screen, `size` the last one
## chosen; else that virtual screen, `size` its pixels now and `width_m` its
## width. distance_m: how far it hangs; ppd: what the headset resolves.
func open_virtual_page(monitor_id: int, size: Vector2i, width_m: float,
		distance_m: float, ppd: float) -> void:
	_vs_id = monitor_id
	_vs_from = size
	_vs_width_m = width_m
	_vs_distance = distance_m
	_vs_ppd = maxf(ppd, 1.0)
	_vs_aspect = float(size.x) / maxf(size.y, 1)
	_vs_shape = maxi(VirtualSize.shape_of(size.x, size.y), 0)
	var title := "New virtual screen"
	for m in _available_monitors:
		if m.get("id", -1) == monitor_id:
			title = m.get("name", "Virtual screen")
	_lbl_vs_title.text = title
	_vs_field = 0
	_vs_set(size)
	_show_virtual_page(true)

func _show_virtual_page(on: bool) -> void:
	_vs_scroll.visible = on
	_tab_pages[1].visible = not on and _tab == 1

func _build_virtual_page(body: VBoxContainer) -> void:
	var top := _hbox(18)
	body.add_child(top)
	var back := _button("Back")
	back.pressed.connect(func(): _show_virtual_page(false))
	top.add_child(back)
	_lbl_vs_title = _label("", 28, UiTheme.INK, true)
	_lbl_vs_title.clip_text = true
	_lbl_vs_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_lbl_vs_title)

	var shape_row := _vs_row(body, "Shape")
	var shapes := []
	for i in VirtualSize.SHAPES.size():
		shapes.append([VirtualSize.SHAPES[i][0], i])
	_vs_shape_buttons = _segmented(shape_row, shapes, _on_vs_shape)
	shape_row.get_child(1).size_flags_stretch_ratio = 2.6
	_vs_orient_buttons = _segmented(shape_row, [["Landscape", false], ["Portrait", true]], func(portrait):
		var d := _vs_dims()
		if (d.y > d.x) != portrait:
			_vs_text = [_vs_text[1], _vs_text[0]]
			_vs_fresh = true
		_vs_refresh())
	_vs_size_buttons = _segmented(_vs_row(body, "Size"), [["", 0], ["", 1], ["", 2], ["", 3]],
		func(i): _vs_set(_vs_offers()[i]))

	var cols := _hbox(26)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(cols)
	# Left: the screen to scale, how sharp it will be, the action.
	var left := _vbox(12)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(left)
	var well := PanelContainer.new()
	well.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.WELL, 14, 16, 12))
	well.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(well)
	var stage := _vbox(8)
	well.add_child(stage)
	_vs_preview = Control.new()
	_vs_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vs_preview.custom_minimum_size.y = 96
	stage.add_child(_vs_preview)
	# The screen as it hangs now (when changing one), then as it will be.
	_vs_old_rect = Panel.new()
	var old_st := UiTheme.box(Color(0, 0, 0, 0), 4, 0, 0, Color(UiTheme.INK_3, 0.8))
	old_st.set_border_width_all(2)
	_vs_old_rect.add_theme_stylebox_override("panel", old_st)
	_vs_preview.add_child(_vs_old_rect)
	_vs_rect = Panel.new()
	_vs_rect.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SURFACE_HOVER, 4, 0, 0, UiTheme.EDGE_HI))
	_vs_preview.add_child(_vs_rect)
	_vs_preview.resized.connect(_vs_place_preview)
	_lbl_vs_caption = _label("", 17, UiTheme.INK_3)
	_lbl_vs_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stage.add_child(_lbl_vs_caption)
	_lbl_vs_sharp = _label("", 18, UiTheme.INK_2)
	_lbl_vs_sharp.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_lbl_vs_sharp)
	_btn_vs_go = _button("", true)
	_btn_vs_go.pressed.connect(_on_vs_go)
	left.add_child(_btn_vs_go)

	# Right: the pixels, a step finer or coarser, a keypad for any size.
	var right := _vbox(10)
	right.custom_minimum_size.x = 340
	cols.add_child(right)
	var readout := _hbox(8)
	right.add_child(readout)
	_btn_vs_less = _button("−")
	_btn_vs_less.pressed.connect(func(): _vs_set(_vs_stepped(-1)))
	readout.add_child(_btn_vs_less)
	for i in 2:
		if i == 1:
			var x := _label("×", 24, UiTheme.INK_3)
			x.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			readout.add_child(x)
		var cell := Button.new()
		cell.focus_mode = Control.FOCUS_NONE
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_font_size_override("font_size", 26)
		for k in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
			cell.add_theme_color_override(k, UiTheme.INK)
		cell.add_theme_stylebox_override("focus", UiTheme.empty())
		cell.pressed.connect(_vs_pick_cell.bind(i))
		readout.add_child(cell)
		_vs_cells.append(cell)
	_btn_vs_more = _button("+")
	_btn_vs_more.pressed.connect(func(): _vs_set(_vs_stepped(1)))
	readout.add_child(_btn_vs_more)
	for b: Button in [_btn_vs_less, _btn_vs_more]:
		b.custom_minimum_size.x = 52
		b.add_theme_font_size_override("font_size", 26)
	var pad := _keypad(["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "×"], _on_vs_key)
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for key: Control in pad.get_children():
		key.size_flags_vertical = Control.SIZE_EXPAND_FILL  # ends level with the action
	right.add_child(pad)

## A titled row like the Quality tab's, with a narrower title.
func _vs_row(body: VBoxContainer, title: String) -> HBoxContainer:
	var row := _quality_row(body, title)
	row.get_child(0).custom_minimum_size.x = 96
	return row

func _vs_dims() -> Vector2i:
	return Vector2i(int(_vs_text[0]), int(_vs_text[1]))

func _vs_valid(d: Vector2i) -> bool:
	return d.x >= VirtualSize.MIN.x and d.x <= VirtualSize.MAX.x \
		and d.y >= VirtualSize.MIN.y and d.y <= VirtualSize.MAX.y

func _vs_set(d: Vector2i) -> void:
	_vs_text = [str(d.x), str(d.y)]
	_vs_fresh = true
	_vs_refresh()

## Metres wide the screen hangs at this aspect: a new one's default, or the
## changed one's width, rescaled for a new shape (main.gd does the same).
func _vs_width_for(aspect: float) -> float:
	if _vs_id < 0 or _vs_from.y <= 0:
		return VirtualSize.default_width_m(aspect)
	return VirtualSize.replaced_width_m(_vs_width_m, float(_vs_from.x) / _vs_from.y, aspect)

## The four sizes offered: the shape's three common ones, then the 1:1 one
## for the proportions on screen, either way up.
func _vs_offers() -> Array:
	var portrait := _vs_aspect < 1.0
	var out := []
	for p: Vector2i in VirtualSize.SHAPES[_vs_shape][2]:
		out.append(Vector2i(p.y, p.x) if portrait else p)
	out.append(VirtualSize.one_to_one(_vs_width_for(_vs_aspect), _vs_distance, _vs_aspect, _vs_ppd))
	return out

## What the action sends: even sizes, as the host makes them.
func _vs_go_size() -> Vector2i:
	var d := _vs_dims()
	return Vector2i(d.x & ~1, d.y & ~1)

func _on_vs_shape(i: int) -> void:
	var at := _vs_offers().find(_vs_dims())
	_vs_shape = i
	var a: float = VirtualSize.SHAPES[i][1]
	_vs_aspect = a if _vs_aspect >= 1.0 else 1.0 / a
	# The same place in the row for the new shape: big stays big, 1:1 stays 1:1.
	_vs_set(_vs_offers()[at if at >= 0 else 1])

## A step finer or coarser, the proportions kept: 128 px on the long side
## (ZERO past what the host makes).
func _vs_stepped(dir: int) -> Vector2i:
	var d := _vs_dims()
	if not _vs_valid(d):
		return Vector2i.ZERO
	var i := VirtualSize.shape_of(d.x, d.y)
	var a: float = VirtualSize.SHAPES[i][1] if i >= 0 else float(maxi(d.x, d.y)) / mini(d.x, d.y)
	var long := maxi(d.x, d.y) + dir * 128
	var short := roundi(long / a / 2.0) * 2
	var n := Vector2i(long, short) if d.x >= d.y else Vector2i(short, long)
	return n if _vs_valid(n) else Vector2i.ZERO

func _vs_pick_cell(i: int) -> void:
	_vs_field = i
	_vs_fresh = true
	_vs_refresh()

func _on_vs_key(k: String) -> void:
	if k == "×":
		_vs_pick_cell(1 - _vs_field)
		return
	var t: String = _vs_text[_vs_field]
	if k == "⌫":
		t = t.left(-1)
	elif _vs_fresh:
		t = k
	elif t.length() < 4:
		t += k
	_vs_text[_vs_field] = t
	_vs_fresh = false
	_vs_refresh()

func _on_vs_go() -> void:
	var d := _vs_go_size()
	if _vs_id < 0:
		virtual_screen_requested.emit(d.x, d.y)
	else:
		virtual_screen_match_requested.emit(_vs_id, d.x, d.y)
	_show_virtual_page(false)

func _vs_refresh() -> void:
	var d := _vs_dims()
	var ok := _vs_valid(d)
	var shape := VirtualSize.shape_of(d.x, d.y) if ok else -1
	if ok:
		_vs_aspect = float(d.x) / d.y
		_vs_shape = shape if shape >= 0 else _vs_shape
	_refresh_segmented(_vs_shape_buttons, shape)
	_refresh_segmented(_vs_orient_buttons, _vs_aspect < 1.0)
	var offers := _vs_offers()
	for i in offers.size():
		var b: Button = _vs_size_buttons[i]
		b.text = ("Sharp · %d × %d" if i == 3 else "%d × %d") % [offers[i].x, offers[i].y]
		b.set_pressed_no_signal(offers[i] == d)
	for i in 2:
		var cell: Button = _vs_cells[i]
		cell.text = _vs_text[i]
		var st := UiTheme.box(UiTheme.WELL, 10, 8, 6)
		if i == _vs_field:
			st.border_color = Color(UiTheme.INK, 0.55)
			st.set_border_width_all(2)
		for k in ["normal", "hover", "pressed", "hover_pressed"]:
			cell.add_theme_stylebox_override(k, st)
	_btn_vs_less.disabled = _vs_stepped(-1) == Vector2i.ZERO
	_btn_vs_more.disabled = _vs_stepped(1) == Vector2i.ZERO

	var go := _vs_go_size()
	var verb := "Add" if _vs_id < 0 else "Change to"
	_btn_vs_go.disabled = not ok or (_vs_id >= 0 and go == _vs_from)
	if not ok:
		_btn_vs_go.text = verb
	elif _btn_vs_go.disabled:
		_btn_vs_go.text = "Already %d × %d" % [go.x, go.y]
	else:
		_btn_vs_go.text = "%s %d × %d" % [verb, go.x, go.y]
	_lbl_vs_caption.visible = ok
	# Room for two lines always, so the action never moves.
	_lbl_vs_sharp.custom_minimum_size.y = _lbl_vs_sharp.get_line_height() * 2 \
		+ _lbl_vs_sharp.get_theme_constant("line_spacing")
	_lbl_vs_sharp.add_theme_color_override("font_color", UiTheme.INK_2 if ok else UiTheme.CLAY)
	_vs_place_preview(_vs_scroll.visible and _visible_overlay)
	if not ok:
		_lbl_vs_sharp.text = "Width %d to %d, height %d to %d." % [VirtualSize.MIN.x,
			VirtualSize.MAX.x, VirtualSize.MIN.y, VirtualSize.MAX.y]
		return
	var w_m := _vs_width_for(_vs_aspect)
	_lbl_vs_caption.text = "%.2f × %.2f m, %.2f m away" % [w_m, w_m / _vs_aspect, _vs_distance]
	# What the headset gets: H.264 carries at most Level 5.2 (the host scales).
	var sent := VirtualSize.h264_size(go.x, go.y) if _stream_codec == 0 else go
	var ppd := roundi(sent.x / VirtualSize.angle_deg(w_m, _vs_distance))
	var eye := roundi(_vs_ppd)
	var lines := []
	if sent != go:
		lines.append("H.264 sends it as %d × %d, HEVC whole." % [sent.x, sent.y])
	if ppd < 0.8 * eye:
		lines.append("%d px per degree, the headset resolves %d: pixels will show." % [ppd, eye])
	elif ppd <= 1.25 * eye:
		lines.append("%d px per degree, as sharp as the headset resolves." % ppd)
	else:
		lines.append("%d px per degree, the headset resolves %d: fine text will blur." % [ppd, eye])
	_lbl_vs_sharp.text = "\n".join(lines)

## The screen to scale in the well: one scale (px per metre) for every shape,
## so a 32:9 screen shows wider and a portrait one taller. `morph`: glide to
## the new shape, as the tab bar slides.
func _vs_place_preview(morph := false) -> void:
	var d := _vs_dims()
	var ok := _vs_valid(d)
	var area := _vs_preview.size
	if _vs_tween:
		_vs_tween.kill()
	morph = morph and _vs_rect.visible and is_inside_tree()
	_vs_rect.visible = ok
	_vs_old_rect.visible = false
	if not ok or area.x < 10.0:
		return
	var w_m := _vs_width_for(_vs_aspect)
	var size_m := Vector2(w_m, w_m / _vs_aspect)
	var old_m := Vector2.ZERO
	if _vs_id >= 0 and _vs_from.x > 0:
		old_m = Vector2(_vs_width_m, _vs_width_m * _vs_from.y / _vs_from.x)
	var span := Vector2(VirtualSize.MAX_W_M, VirtualSize.MAX_H_M).max(size_m).max(old_m)
	var px_per_m := minf(area.x / span.x, (area.y - 16.0) / span.y)  # air above and below
	var rect_size := (size_m * px_per_m).round()
	var rect_pos := ((area - rect_size) / 2.0).round()
	if morph:
		_vs_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_vs_tween.tween_property(_vs_rect, "size", rect_size, 0.18)
		_vs_tween.tween_property(_vs_rect, "position", rect_pos, 0.18)
	else:
		_vs_rect.size = rect_size
		_vs_rect.position = rect_pos
	_vs_old_rect.visible = old_m != Vector2.ZERO and not old_m.is_equal_approx(size_m)
	_vs_old_rect.size = (old_m * px_per_m).round()
	_vs_old_rect.position = ((area - _vs_old_rect.size) / 2.0).round()

# ---------------------------------------------------------------------------
# Space tab
# ---------------------------------------------------------------------------

func _build_space_tab(body: VBoxContainer) -> void:
	_heading(body, "Surroundings")
	_look_buttons = _segmented(body, LOOKS, func(v):
		_look = v
		_refresh_segmented(_look_buttons, _look)
		look_changed.emit(v))
	var note := _label("Passthrough shows your room around the screens, on headsets that allow it.", 17, UiTheme.INK_3)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(note)

	var sp := Control.new()
	sp.custom_minimum_size.y = 6
	body.add_child(sp)
	_heading(body, "Headset")
	_chk_layers = CheckButton.new()
	_chk_layers.text = "Sharper text: let the headset draw the screens itself"
	_chk_layers.focus_mode = Control.FOCUS_NONE
	_chk_layers.button_pressed = _layers_enabled
	_chk_layers.toggled.connect(func(on):
		_layers_enabled = on
		compositor_layers_toggled.emit(on))
	body.add_child(_chk_layers)
	var sp3 := Control.new()
	sp3.custom_minimum_size.y = 6
	body.add_child(sp3)
	_heading(body, "Moving screens")
	_chk_snap = CheckButton.new()
	_chk_snap.text = "Snap screens together"
	_chk_snap.focus_mode = Control.FOCUS_NONE
	_chk_snap.button_pressed = _snap_enabled
	_chk_snap.toggled.connect(func(on):
		_snap_enabled = on
		snap_toggled.emit(on))
	body.add_child(_chk_snap)
	_chk_lock = CheckButton.new()
	_chk_lock.text = "Lock screens in place"
	_chk_lock.focus_mode = Control.FOCUS_NONE
	_chk_lock.button_pressed = _lock_enabled
	_chk_lock.toggled.connect(func(on):
		_lock_enabled = on
		lock_toggled.emit(on))
	body.add_child(_chk_lock)

# ---------------------------------------------------------------------------
# Input tab
# ---------------------------------------------------------------------------

func _build_input_tab(body: VBoxContainer) -> void:
	_heading(body, "Pointer")
	_hand_buttons = _segmented(_quality_row(body, "Point with"),
		[["Left hand", "left"], ["Right hand", "right"]], func(v):
			_pointer_hand = v
			_refresh_input_tab()
			_emit_pointer_settings())
	var r := _slider_row(body, "Ray angle", 0, 60, 1, func(v):
		_ray_angle = v
		_lbl_ray_value.text = "%d°" % int(v)
		_emit_pointer_settings())
	_slider_ray = r[0]
	_lbl_ray_value = r[1]
	var note := _label("Bare hands: put the controllers down and point. Look at the palm of your other hand and pinch to open this menu. Controller ray: 40° suits the Pico 4.", 17, UiTheme.INK_3)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(note)

	var sp := Control.new()
	sp.custom_minimum_size.y = 6
	body.add_child(sp)
	_heading(body, "Moving and feedback")
	_chk_face_me = CheckButton.new()
	_chk_face_me.text = "Screens face me while moving (off: follow the controller)"
	_chk_face_me.focus_mode = Control.FOCUS_NONE
	_chk_face_me.toggled.connect(func(on):
		_face_me = on
		_emit_pointer_settings())
	body.add_child(_chk_face_me)
	_chk_haptics = CheckButton.new()
	_chk_haptics.text = "Vibrate the controllers on clicks and grabs"
	_chk_haptics.focus_mode = Control.FOCUS_NONE
	_chk_haptics.button_pressed = _haptics_enabled
	_chk_haptics.toggled.connect(func(on):
		_haptics_enabled = on
		haptics_toggled.emit(on))
	body.add_child(_chk_haptics)

func _emit_pointer_settings() -> void:
	pointer_settings_changed.emit(_pointer_hand, _ray_angle, _face_me)

func _refresh_input_tab() -> void:
	if not _slider_ray:
		return
	_refresh_segmented(_hand_buttons, _pointer_hand)
	_slider_ray.set_value_no_signal(_ray_angle)
	_lbl_ray_value.text = "%d°" % int(_ray_angle)
	_chk_face_me.set_pressed_no_signal(_face_me)

# ---------------------------------------------------------------------------
# Quality tab
# ---------------------------------------------------------------------------

func _quality_row(body: VBoxContainer, title: String) -> HBoxContainer:
	var row := _hbox(16)
	body.add_child(row)
	var t := _label(title, 20, UiTheme.INK_2)
	t.custom_minimum_size.x = 170
	row.add_child(t)
	return row

func _build_quality_tab(body: VBoxContainer) -> void:
	# MJPEG belongs here: it is the decode path on PC / iOS / web (no
	# MediaCodec plugin), and main.gd resolves hardware codecs down to it there.
	_codec_buttons = _segmented(_quality_row(body, "Codec"),
		[["Auto", 0xFF], ["H.264", 0], ["HEVC", 1], ["AV1", 3], ["MJPEG", 2]], _on_codec_chosen)
	_res_buttons = _segmented(_quality_row(body, "Resolution"),
		[["Native", 100], ["75%", 75], ["50%", 50], ["Auto", -1]], _on_res_chosen)
	_fps_buttons = _segmented(_quality_row(body, "Frame rate"),
		[["Auto", 0], ["30", 30], ["60", 60], ["72", 72], ["90", 90]], _on_fps_chosen)
	var r := _slider_row(body, "Bitrate", 5, 100, 1, _on_bitrate_changed)
	_slider_bitrate = r[0]
	_lbl_bitrate_value = r[1]
	r = _slider_row(body, "JPEG quality", 10, 95, 5, _on_jpegq_changed)
	_slider_jpegq = r[0]
	_lbl_jpegq_value = r[1]
	# A drag applies once, where it is let go, however long it pauses on the way.
	for s: HSlider in [_slider_bitrate, _slider_jpegq]:
		s.drag_started.connect(func():
			_slider_held = true
			_apply_debounce.stop())
		s.drag_ended.connect(func(_changed: bool):
			_slider_held = false
			_schedule_auto_apply())
	_lbl_auto_info = _label("", 17, UiTheme.INK_3)
	_lbl_auto_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_auto_info.hide()
	body.add_child(_lbl_auto_info)
	var note := _label("Changes apply a moment after you make them. Bitrate and JPEG quality are upper limits: the PC lowers them while the network is struggling.", 17, UiTheme.INK_3)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(note)

func _schedule_auto_apply() -> void:
	if _apply_debounce and _apply_debounce.is_inside_tree() and not _slider_held:
		_apply_debounce.start(AUTO_APPLY_DELAY)

func _emit_stream_settings() -> void:
	stream_settings_changed.emit(_stream_codec, _bitrate_kbps, _jpeg_quality, _res_percent, _fps_value)

func _refresh_quality_ui() -> void:
	if not _slider_bitrate:
		return
	_refresh_segmented(_codec_buttons, _stream_codec)
	_refresh_segmented(_res_buttons, _res_percent)
	_refresh_segmented(_fps_buttons, _fps_value)
	_slider_bitrate.set_value_no_signal(_bitrate_kbps / 1000.0)
	_lbl_bitrate_value.text = "%d Mbps" % int(_bitrate_kbps / 1000.0)
	_slider_jpegq.set_value_no_signal(_jpeg_quality)
	_lbl_jpegq_value.text = "%d" % _jpeg_quality
	_set_slider_active(_slider_bitrate, _stream_codec in [0, 1, 3])
	_set_slider_active(_slider_jpegq, _stream_codec == 2 or _stream_codec == 0xFF)

func _on_codec_chosen(value: int) -> void:
	_stream_codec = value
	_refresh_quality_ui()
	_schedule_auto_apply()

func _on_res_chosen(value: int) -> void:
	_res_percent = value
	_refresh_quality_ui()
	if value == -1:
		auto_quality_requested.emit()  # computes and applies on its own
	else:
		_lbl_auto_info.hide()
		_schedule_auto_apply()

func _on_fps_chosen(value: int) -> void:
	_fps_value = value
	_refresh_quality_ui()
	_schedule_auto_apply()

func _on_bitrate_changed(value: float) -> void:
	_bitrate_kbps = int(value) * 1000
	_lbl_bitrate_value.text = "%d Mbps" % int(value)
	_schedule_auto_apply()

func _on_jpegq_changed(value: float) -> void:
	_jpeg_quality = int(value)
	_lbl_jpegq_value.text = "%d" % int(value)
	_schedule_auto_apply()

# ---------------------------------------------------------------------------
# Status line
# ---------------------------------------------------------------------------

func _refresh_status() -> void:
	if not _lbl_status:
		return
	var who := _host_label if not _host_label.is_empty() else "the PC"
	if not _link.is_empty():
		who += " over " + _link
	var dot := UiTheme.INK_3
	var text := ""
	match _state:
		ConnectionState.DISCONNECTED:
			text = "Not connected"
		ConnectionState.CONNECTING:
			text = "Connecting to %s…" % who
			dot = UiTheme.OCHRE
		ConnectionState.CONNECTED:
			text = "Connected to %s" % who
			dot = UiTheme.SAGE
		ConnectionState.STREAMING:
			var parts := ["Live from %s" % who]
			if _ping_ms > 0.0:
				parts.append("%d ms" % int(round(_ping_ms)))
			if _stats.fps > 0.5:
				parts.append("%d fps" % int(round(_stats.fps)))
				# Whole Mbps from 10 up: room for a long PC name and the link.
				parts.append(("%d Mbps" if _stats.mbps >= 10.0 else "%.1f Mbps") % _stats.mbps)
			text = "  ·  ".join(parts)
			dot = UiTheme.TALLY
	_lbl_status.text = text
	var st := StyleBoxFlat.new()
	st.bg_color = dot
	st.set_corner_radius_all(6)
	st.anti_aliasing = true
	_status_dot.add_theme_stylebox_override("panel", st)
