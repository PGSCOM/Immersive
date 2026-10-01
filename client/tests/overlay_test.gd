extends SceneTree
## Drives the real in-VR menu (ui_overlay.gd) offscreen with pointer clicks,
## the same events the controller and hand pointers inject.
##
##   xvfb-run -a godot --rendering-driver opengl3 --xr-mode off \
##       --path client/project -s "$PWD/client/tests/overlay_test.gd" [-- /tmp/shot]
##
## Prints one ok/FAIL line per check and "RESULT fails=N". With an output
## prefix it also saves a PNG of the menu at each step, to eyeball the layout.
## Kept outside client/project so it never ships in an export.

var ov
var out := ""
var fails := 0
var events: Array = []

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	root.add_child(Camera3D.new())
	ov = load("res://scripts/ui_overlay.gd").new()
	root.add_child(ov)
	ov.connect_requested.connect(func(ip, t, _u): events.append(["connect", ip, t]))
	ov.pin_entered.connect(func(pin): events.append(["pin", pin]))
	ov.monitor_selected.connect(func(id): events.append(["monitor", id]))
	ov.look_changed.connect(func(l): events.append(["look", l]))
	ov.arrange_requested.connect(func(): events.append(["arrange"]))
	ov.stream_settings_changed.connect(func(c, _b, _j, _r, _f): events.append(["stream", c]))
	ov.virtual_screen_requested.connect(func(w, h): events.append(["virtual", w, h]))
	ov.virtual_screen_remove_requested.connect(func(id): events.append(["unvirtual", id]))
	ov.control_toggled.connect(func(on): events.append(["control", on]))
	ov.haptics_toggled.connect(func(on): events.append(["haptics", on]))
	ov.compositor_layers_toggled.connect(func(on): events.append(["layers", on]))
	_run()

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _click(ctrl: Control) -> void:
	if ctrl == null:
		check(false, "control to click exists")
		return
	var r := ctrl.get_global_rect()
	var uv := (r.position + r.size / 2.0) / Vector2(ov._viewport.size)
	ov.inject_pointer_move(uv)
	await _frames(2)
	ov.inject_pointer_button(true)
	await _frames(2)
	ov.inject_pointer_move(uv + Vector2(0.002, 0.001))  # pointers jitter
	await _frames(1)
	ov.inject_pointer_button(false)
	await _frames(3)

## The visible button labelled `text` (optionally inside `under`).
func _btn(text: String, under: Node = null) -> Button:
	for n in (under if under else ov._viewport).find_children("*", "Button", true, false):
		if n.text.strip_edges() == text and n.is_visible_in_tree():
			return n
	return null

func _type(s: String) -> void:
	for ch in s:
		await _click(_btn(ch, ov._manual_box))

## Layout check (the open tab fits without scrolling) plus optional PNG.
func _step(name: String) -> void:
	await _frames(4)
	var page: ScrollContainer = ov._tab_pages[ov._tab]
	var need: float = page.get_child(0).get_combined_minimum_size().y
	check(need <= page.size.y and ov._canvas.get_child(0).get_combined_minimum_size().y <= ov._viewport.size.y,
		"%s: fits the panel without scrolling (%d of %d px)" % [name, need, page.size.y])
	if out != "":
		await RenderingServer.frame_post_draw
		ov._viewport.get_texture().get_image().save_png("%s_%s.png" % [out, name])

func _run() -> void:
	await _frames(2)
	ov.toggle_visibility()
	await _step("connect")
	check(not ov._input_ip.virtual_keyboard_enabled, "IP field never raises the system keyboard")

	# --- Address by hand ----------------------------------------------------
	ov._input_ip.text = ""
	await _type("192.168.33.181")
	check(ov._input_ip.text == "192.168.33.181", "keypad types -> '%s'" % ov._input_ip.text)
	await _click(_btn("⌫", ov._manual_box))
	check(ov._input_ip.text == "192.168.33.18", "backspace -> '%s'" % ov._input_ip.text)
	ov._input_ip.text = ""
	await _type("1.2")
	await _click(ov._btn_connect)
	check(events.is_empty(), "an invalid address does not connect")
	check(ov._lbl_ip_error.visible, "an invalid address says why")
	await _step("invalid")
	await _type("5")
	check(not ov._lbl_ip_error.visible, "typing clears the error")
	ov._input_ip.text = ""
	await _type("10.0.0.7")
	await _click(ov._btn_connect)
	check(events.back() == ["connect", "10.0.0.7", 19800], "valid address connects -> %s" % [events.back()])
	await _click(ov._btn_usb)
	check(events.back() == ["connect", "127.0.0.1", 19800], "USB connects to loopback")

	# --- PCs found on the network -------------------------------------------
	ov.set_discovered_hosts([
		{"ip": "192.168.1.34", "port": 19800, "monitors": 3, "pin_required": true, "name": "desk-pc"},
		{"ip": "192.168.1.52", "port": 19850, "monitors": 1, "pin_required": false, "name": "studio"}])
	await _frames(2)
	var cards: Array = ov._hosts_list.get_children()
	check(cards.size() == 2, "both PCs listed")
	await _click(_btn("Connect", cards[1]))
	check(events.back() == ["connect", "192.168.1.52", 19850], "a PC's button connects to it -> %s" % [events.back()])
	await _step("hosts")

	# --- PIN pairing --------------------------------------------------------
	ov.show_pin_prompt(1, "desk-pc")
	await _frames(2)
	check(ov._pin_box.visible and not ov._connect_main.visible, "PIN prompt replaces the connect view")
	for d in "24681":
		await _click(_btn(d, ov._pin_box))
	await _click(_btn("OK", ov._pin_box))
	check(events.back()[0] != "pin", "OK needs all six digits")
	await _click(_btn("0", ov._pin_box))
	await _step("pin")
	await _click(_btn("OK", ov._pin_box))
	check(events.back() == ["pin", 246810], "six digits + OK sends the PIN -> %s" % [events.back()])
	check(not ov._pin_box.visible, "prompt closes after OK")
	ov.show_pin_prompt(2, "desk-pc")
	await _frames(2)
	check(ov._lbl_pin_error.visible, "a wrong PIN says so")
	await _click(_btn("Cancel", ov._pin_box))
	check(not ov._pin_box.visible, "Cancel closes the prompt")

	# --- Connected: status, screens -----------------------------------------
	ov.set_state(ov.ConnectionState.CONNECTING)
	ov.set_host_label("desk-pc")
	ov.set_state(ov.ConnectionState.CONNECTED)
	check(ov._tab == 1, "connecting opens the Screens tab")
	ov.set_state(ov.ConnectionState.STREAMING)
	ov.set_latency(12.4)
	ov.set_stream_stats(59.8, 31.2)
	ov.set_host_capabilities(false, true)
	ov.set_monitor_list([
		{"id": 0, "name": "Monitor A", "width": 3840, "height": 2160, "refresh_rate": 60},
		{"id": 1, "name": "Monitor B", "width": 2560, "height": 1440, "refresh_rate": 144},
		{"id": 100, "name": "Virtual 1", "width": 1920, "height": 1080, "refresh_rate": 60, "virtual": true}])
	ov.set_active_monitors([0, 100])
	await _frames(2)
	check(ov._lbl_status.text.contains("12 ms") and ov._lbl_status.text.contains("60 fps"),
		"status line shows delay and frame rate -> '%s'" % ov._lbl_status.text)
	ov.set_link("USB")
	check(ov._lbl_status.text.begins_with("Live from desk-pc over USB")
		and ov._lbl_connected.text == "Connected to desk-pc over USB",
		"status says the link in use -> '%s'" % ov._lbl_status.text)
	# A Windows-style PC name over Wi-Fi still fits the header unclipped.
	ov.set_host_label("DESKTOP-4F2K9QX")
	ov.set_link("Wi-Fi")
	await _frames(2)
	var st: Label = ov._lbl_status
	var text_w := st.get_theme_font("font").get_string_size(st.text, HORIZONTAL_ALIGNMENT_LEFT,
		-1, st.get_theme_font_size("font_size")).x
	check(text_w <= st.size.x, "status line fits (%d <= %d px) -> '%s'" % [text_w, st.size.x, st.text])
	ov.set_host_label("desk-pc")
	ov.set_link("USB")
	var rows: Array = ov._monitor_list.find_children("*", "CheckButton", true, false).filter(
		func(b): return b.text != "Move together")
	check(rows.size() == 3 and rows[0].button_pressed and not rows[1].button_pressed,
		"monitor switches show what streams")
	await _click(rows[1])
	check(events.back() == ["monitor", 1], "a switch toggles that monitor")
	await _click(ov._btn_arrange)
	check(events.back() == ["arrange"], "Arrange around me")
	check(ov._virtual_row.visible, "a PC that can make virtual screens offers them")
	await _click(_btn("2560 × 1440", ov._virtual_row))
	check(events.back() == ["virtual", 2560, 1440], "asks for a 2560x1440 virtual screen -> %s" % [events.back()])
	await _click(_btn("Remove", ov._monitor_list))
	check(events.back() == ["unvirtual", 100], "Remove on the virtual screen -> %s" % [events.back()])
	await _step("screens")
	ov.set_host_capabilities(false, false)
	check(not ov._virtual_row.visible, "no virtual screens offered when the PC can't make them")

	await _click(ov._tab_buttons[0])
	check(ov._connected_box.visible and not ov._input_ip.editable, "connected: address locked")
	ov.set_connection_details([["Address", "192.168.1.34:19800"], ["Link", "Network"]])
	await _frames(3)  # the new rows move the switch down
	check(ov._chk_control.button_pressed and not ov._lbl_control_note.visible, "control is on by default")
	await _click(ov._chk_control)
	check(events.back() == ["control", false] and ov._lbl_control_note.visible,
		"the switch turns control off and says what that means -> %s" % [events.back()])
	await _step("connected")
	ov.set_host_capabilities(true, false)
	check(ov._chk_control.disabled and not ov._chk_control.button_pressed, "a view-only PC: control off and locked")
	await _step("viewonly")
	ov.set_host_capabilities(false, false)
	ov.set_input_settings(true, true)

	await _click(ov._tab_buttons[2])
	await _click(_btn("Dusk"))
	check(events.back() == ["look", "dusk"], "Space: pick Dusk")
	await _click(ov._chk_layers)
	check(events.back() == ["layers", true], "Space: sharper-text switch")
	await _click(ov._chk_haptics)
	check(events.back() == ["haptics", false], "Space: vibration switch")
	await _step("space")

	await _click(ov._tab_buttons[3])
	await _click(_btn("HEVC"))
	await create_timer(0.8).timeout  # the change applies after a short pause
	check(events.back() == ["stream", 1], "Quality: HEVC applies on its own -> %s" % [events.back()])
	# Dragging the bitrate slider, pausing on the way, applies once: on release.
	var bitrates: Array = []
	ov.stream_settings_changed.connect(func(_c, b, _j, _r, _f): bitrates.append(b))
	var r: Rect2 = ov._slider_bitrate.get_global_rect()
	var at := func(f: float) -> Vector2:
		return (r.position + Vector2(r.size.x * f, r.size.y / 2.0)) / Vector2(ov._viewport.size)
	ov.inject_pointer_move(at.call(0.2))
	await _frames(2)
	ov.inject_pointer_button(true)
	for f in [0.4, 0.6, 0.8]:
		ov.inject_pointer_move(at.call(f))
		await create_timer(0.6).timeout  # longer than the apply pause
	ov.inject_pointer_button(false)
	var during := bitrates.size()
	await create_timer(0.8).timeout
	check(during == 0 and bitrates.size() == 1 and bitrates[0] == ov._bitrate_kbps and bitrates[0] > 60000,
		"Quality: a bitrate drag applies once, on release -> %s (%d while held)" % [bitrates, during])
	await _step("quality")

	await _click(_btn("Close"))
	check(not ov.visible, "Close hides the menu")
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
