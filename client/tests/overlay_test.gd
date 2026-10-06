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
	ov.virtual_screen_match_requested.connect(func(id, w, h): events.append(["match", id, w, h]))
	ov.virtual_page_requested.connect(func(id): events.append(["vpage", id]))
	ov.control_toggled.connect(func(on): events.append(["control", on]))
	ov.screen_off_toggled.connect(func(off): events.append(["screen_off", off]))
	ov.haptics_toggled.connect(func(on): events.append(["haptics", on]))
	ov.compositor_layers_toggled.connect(func(on): events.append(["layers", on]))
	ov.pointer_settings_changed.connect(func(h, a, f): events.append(["pointer", h, a, f]))
	ov.room_open_requested.connect(func(): events.append(["room_open"]))
	ov.room_join_requested.connect(func(ip, port, pin): events.append(["room_join", ip, port, pin]))
	ov.room_leave_requested.connect(func(): events.append(["room_leave"]))
	ov.room_mic_toggled.connect(func(on): events.append(["room_mic", on]))
	ov.room_share_toggled.connect(func(on): events.append(["room_share", on]))
	ov.room_permission_changed.connect(func(id, what, on): events.append(["perm", id, what, on]))
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

func _click_at(uv: Vector2) -> void:
	ov.inject_pointer_move(uv)
	await _frames(2)
	ov.inject_pointer_button(true)
	await _frames(2)
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

## Layout check (the open tab, or the virtual screen page over the Screens
## tab, fits without scrolling or spilling sideways) plus optional PNG.
func _step(name: String) -> void:
	await create_timer(0.25).timeout  # the tab bar and the size preview glide 0.18 s
	var page: ScrollContainer = ov._vs_scroll if ov._vs_scroll.visible else ov._tab_pages[ov._tab]
	var need: Vector2 = page.get_child(0).get_combined_minimum_size()
	check(need.y <= page.size.y and need.x <= page.size.x
		and ov._canvas.get_child(0).get_combined_minimum_size().y <= ov._viewport.size.y,
		"%s: fits the panel without scrolling (%d x %d of %d x %d px)" % [name, need.x, need.y, page.size.x, page.size.y])
	if out != "":
		await RenderingServer.frame_post_draw
		ov._viewport.get_texture().get_image().save_png("%s_%s.png" % [out, name])

## The Room tab: rooms found, joining by address and PIN, opening one, and
## the view inside a room.
func _room() -> void:
	await _click(ov._tab_buttons[ov.ROOM_TAB])
	var tab: Button = ov._tab_buttons[ov.ROOM_TAB]
	check(ov._tab == ov.ROOM_TAB and ov._room_out.visible and not ov._room_in.visible
		and tab.get_global_rect().end.x <= ov._viewport.size.x - 30, "Room: the sixth tab fits and shows the join form")
	ov.set_room_defaults("", 19820)
	ov.set_found_rooms([{"ip": "192.168.1.40", "port": 19830, "monitors": 2, "name": "Ana", "pin_required": true}])
	await _frames(2)
	await _step("room")
	await _click(_btn("Join", ov._rooms_list))
	check(ov._room_text == ["192.168.1.40", ""] and ov._room_field == 1 and ov._lbl_room_hint.text.contains("PIN"),
		"Room: a found room's Join fills its address and asks for its PIN -> %s" % [ov._room_text])
	for d in "13579":
		await _click(_btn(d, ov._room_out))
	await _click(ov._btn_room_join)
	check(events.back()[0] != "room_join" and ov._lbl_room_hint.text.contains("six"), "Room: Join needs all six digits")
	await _click(_btn("0", ov._room_out))
	await _step("room_pin")
	await _click(ov._btn_room_join)
	check(events.back() == ["room_join", "192.168.1.40", 19830, 135790], "Room: Join sends address, port, PIN -> %s" % [events.back()])
	# An address typed by hand joins on the usual port.
	await _click(ov._room_cells[0])
	for i in 12:
		await _click(_btn("⌫", ov._room_out))
	for ch in "10.0.0.9":
		await _click(_btn(ch, ov._room_out))
	await _click(ov._btn_room_join)
	check(events.back() == ["room_join", "10.0.0.9", 19820, 135790], "Room: a typed address -> %s" % [events.back()])
	ov.set_room({"state": 1})
	check(ov._btn_room_join.disabled and ov._btn_room_join.text.begins_with("Joining"), "Room: joining shows")
	ov.set_room({"state": 0})
	await _click(_btn("Open a room"))
	check(events.back() == ["room_open"], "Room: Open a room")

	ov.set_room({"state": 2, "host": true, "address": "192.168.1.37", "pin": 482913, "mic": true,
		"share": false, "pc": true, "people": [
		{"id": 1, "name": "Pablo", "me": true, "host": true, "tone": UiTheme.PEOPLE[0], "mic": true, "speaking": true, "screens": "", "count": 0},
		{"id": 501, "name": "Ana", "me": false, "host": false, "tone": UiTheme.PEOPLE[1], "mic": true, "speaking": false,
			"screens": "live", "count": 2, "see_board": true, "see_screens": true, "hear": true, "draw": false},
		{"id": 902, "name": "DESKTOP-8F3K2LQ-WORKSTATION", "me": false, "host": false, "tone": UiTheme.PEOPLE[2], "mic": false,
			"speaking": false, "screens": "hidden", "count": 0, "see_board": true, "see_screens": false, "hear": true, "draw": true}]})
	await _frames(2)
	check(ov._room_in.visible and not ov._room_out.visible and ov._lbl_room_pin.text == "482 913"
		and ov._people_list.get_child_count() == 3 and ov._lbl_room_title.text == "Your room",
		"Room: inside, its PIN and who is there")
	await _step("room_in")
	await _click(ov._chk_share)
	check(events.back() == ["room_share", true], "Room: share my screens -> %s" % [events.back()])
	await _click(ov._chk_mic)
	check(events.back() == ["room_mic", false], "Room: microphone off -> %s" % [events.back()])
	await _permissions()
	ov.set_room({"state": 2, "host": false, "address": "192.168.1.37", "pin": 482913, "mic": true,
		"share": true, "pc": false, "people": [{"name": "Pablo", "me": true, "host": false, "tone": UiTheme.PEOPLE[1],
		"mic": true, "speaking": false, "screens": "", "count": 0}, {"name": "Ana", "me": false, "host": true,
		"tone": UiTheme.PEOPLE[0], "mic": true, "speaking": true, "screens": "connecting", "count": 0}]})
	await _frames(2)
	check(ov._lbl_room_title.text == "Ana's room" and ov._chk_share.disabled, "Room: someone else's; no PC, no sharing")
	await _step("room_guest")
	await _click(_btn("Leave room"))
	check(events.back() == ["room_leave"], "Room: Leave room")

## The Permissions page over the Room tab: a row per person, a column per
## switch, every switch under its heading; each says who and what.
func _permissions() -> void:
	await _click(_btn("Permissions"))
	check(ov._perm_scroll.visible and not ov._tab_pages[ov.ROOM_TAB].visible, "Permissions opens over the Room tab")
	var grid: GridContainer = ov._perm_grid
	check(grid.get_child_count() == 3 * (1 + ov.PERMISSIONS.size()), "Permissions: a heading row and a row per other person")
	var ana_screens: CheckButton = ov._perm_switches[[501, "screens"]]
	var ben_screens: CheckButton = ov._perm_switches[[902, "screens"]]
	var heading: Label = grid.get_child(2)
	var centre := func(c: Control): return c.get_global_rect().get_center().x
	check(ana_screens.button_pressed and not ben_screens.button_pressed
		and absf(centre.call(ana_screens) - centre.call(ben_screens)) < 1.0
		and absf(centre.call(ana_screens) - centre.call(heading)) < 1.0,
		"Permissions: the switches show the room and line up under their heading")
	await _step("permissions")
	await _click(ov._perm_switches[[501, "draw"]])
	check(events.back() == ["perm", 501, "draw", true], "Permissions: let Ana draw on my board -> %s" % [events.back()])
	await _click(ben_screens)
	check(events.back() == ["perm", 902, "screens", true], "Permissions: show the other one's screens -> %s" % [events.back()])
	await _click(ov._perm_switches[[501, "watch"]])
	check(events.back() == ["perm", 501, "watch", false], "Permissions: Ana may not watch my screens -> %s" % [events.back()])
	var before: Node = ov._perm_switches[[501, "voice"]]
	ov.set_room(ov._room)  # the room refreshes as people talk
	await _frames(2)
	check(ov._perm_switches[[501, "voice"]] == before, "Permissions: a refresh keeps the switches (none swapped under a pointer)")
	await _click(_btn("Back", ov._perm_scroll))
	check(not ov._perm_scroll.visible and ov._tab_pages[ov.ROOM_TAB].visible, "Permissions: Back returns to the room")

## The virtual screen size page: a new screen, then changing one.
func _virtual_page() -> void:
	await _click(ov._btn_add_virtual)
	check(events.back() == ["vpage", -1], "New virtual screen asks for the page -> %s" % [events.back()])
	ov.set_stream_settings(0, 20000, 70, 100, 0)  # H.264, as on a Pico
	ov.open_virtual_page(-1, Vector2i(1920, 1080), 0.0, 1.25, 20.0)  # as main.gd answers
	await _frames(2)
	check(ov._vs_scroll.visible and not ov._tab_pages[1].visible and ov._tab == 1,
		"the page shows over the Screens tab")
	check(_btn("16:9").button_pressed and _btn("Landscape").button_pressed
		and _btn("1920 × 1080").button_pressed and _btn("Add 1920 × 1080") != null,
		"starts at the last size: 16:9, 1920 × 1080, one action")
	check(ov._lbl_vs_sharp.text == "29 px per degree, the headset resolves 20: fine text will blur.",
		"says how sharp, in real numbers -> '%s'" % ov._lbl_vs_sharp.text)
	var rect: Panel = ov._vs_rect
	var area: Vector2 = ov._vs_preview.size
	check(absf(rect.position.x * 2.0 + rect.size.x - area.x) <= 1.0
		and absf(rect.position.y * 2.0 + rect.size.y - area.y) <= 1.0
		and absf(rect.size.x / rect.size.y - 16.0 / 9.0) < 0.02, "the preview is 16:9 and centred")
	var wide_16_9: float = rect.size.x
	await _step("vpage")

	await _click(_btn("Sharp · 1304 × 736"))
	check(ov._vs_dims() == Vector2i(1304, 736) and ov._lbl_vs_sharp.text.contains("as sharp as the headset"),
		"Sharp picks the 1:1 size -> %s '%s'" % [ov._vs_dims(), ov._lbl_vs_sharp.text])
	await _click(_btn("2560 × 1440"))
	await _click(_btn("32:9"))
	check(_btn("32:9").button_pressed and ov._vs_dims() == Vector2i(5120, 1440),
		"a shape keeps the place in the row: 2560 × 1440 -> 5120 × 1440 (%s)" % [ov._vs_dims()])
	check(ov._lbl_vs_sharp.text.begins_with("H.264 sends it as 4096 × 1152, HEVC whole.\n49 px per degree"),
		"says what H.264 carries -> '%s'" % ov._lbl_vs_sharp.text)
	check(rect.size.x < wide_16_9 * 1.3, "the preview glides to the new shape")
	await create_timer(0.3).timeout
	check(rect.size.x > wide_16_9 and rect.size.x / rect.size.y > 3.4, "the preview grows to scale for 32:9")
	await _step("vpage_ultrawide")
	await _click(_btn("+"))
	check(ov._vs_dims() == Vector2i(5248, 1476), "+ is one step finer, 32:9 kept -> %s" % [ov._vs_dims()])
	await _click(_btn("−"))
	check(ov._vs_dims() == Vector2i(5120, 1440), "− steps back -> %s" % [ov._vs_dims()])
	await _click(_btn("7680 × 2160"))
	check(_btn("+").disabled and not _btn("−").disabled, "+ stops at 7680")

	await _click(_btn("16:10"))
	await _click(_btn("Portrait"))
	check(ov._vs_dims() == Vector2i(2400, 3840) and _btn("1200 × 1920") != null and _btn("Portrait").button_pressed,
		"Portrait stands the size and the offers up -> %s" % [ov._vs_dims()])
	await create_timer(0.3).timeout
	check(rect.size.y > rect.size.x and rect.size.y <= area.y, "the preview stands up, inside its well")
	await _step("vpage_portrait")
	await _click(_btn("Landscape"))
	check(ov._vs_dims() == Vector2i(3840, 2400), "Landscape lays it back down")

	# Any size: tap a cell, type; × (or the other cell) moves on.
	await _click(ov._vs_cells[0])
	for k in "3000":
		await _click(_btn(k))
	await _click(_btn("×", ov._vs_scroll))
	for k in "1250":
		await _click(_btn(k))
	check(ov._vs_dims() == Vector2i(3000, 1250) and ov._vs_field == 1, "the keypad types 3000 × 1250")
	check(ov._vs_shape_buttons.values().all(func(b): return not b.button_pressed),
		"a size of no listed shape lights no shape")
	await _step("vpage_custom")
	await _click(_btn("Add 3000 × 1250"))
	check(events.back() == ["virtual", 3000, 1250] and not ov._vs_scroll.visible and ov._tab_pages[1].visible,
		"Add asks for it and goes back to the list -> %s" % [events.back()])

	ov.open_virtual_page(-1, Vector2i(1920, 1080), 0.0, 1.25, 20.0)
	await _frames(2)
	await _click(ov._vs_cells[0])
	for k in "300":
		await _click(_btn(k))
	check(_btn("Add").disabled and ov._lbl_vs_sharp.text == "Width 640 to 7680, height 480 to 4320."
		and ov._vs_shape_buttons.values().all(func(b): return not b.button_pressed),
		"a size the PC can't make: no action, no shape, the range said")
	await _step("vpage_invalid")
	await _click(_btn("⌫", ov._vs_scroll))
	check(ov._vs_text[0] == "30", "⌫ deletes a digit -> '%s'" % ov._vs_text[0])
	await _click(_btn("Back"))
	check(not ov._vs_scroll.visible and ov._tab_pages[1].visible, "Back returns to the Screens list")

	# Changing virtual screen 100, which hangs 1.6 m wide 1.4 m away.
	ov.open_virtual_page(100, Vector2i(1920, 1080), 1.6, 1.4, 20.0)
	await _frames(2)
	check(ov._lbl_vs_title.text == "Virtual 1" and _btn("Already 1920 × 1080") != null
		and _btn("Already 1920 × 1080").disabled, "change mode: its name, its size, nothing to do yet")
	await _click(_btn("2560 × 1440"))
	check(_btn("Change to 2560 × 1440") != null and not ov._vs_old_rect.visible,
		"same shape: same width, one action")
	await _click(_btn("21:9"))
	await create_timer(0.3).timeout
	check(ov._vs_old_rect.visible and ov._vs_rect.size.x > ov._vs_old_rect.size.x,
		"a new shape shows the screen now against the new one")
	await _step("vpage_change")
	await _click(_btn("16:9"))
	await _click(_btn("Change to 2560 × 1440"))
	check(events.back() == ["match", 100, 2560, 1440], "Change asks to replace it in place -> %s" % [events.back()])
	ov.open_virtual_page(-1, Vector2i(1920, 1080), 0.0, 1.25, 20.0)
	await _frames(2)
	await _click(ov._tab_buttons[1])
	check(not ov._vs_scroll.visible and ov._tab_pages[1].visible, "the Screens tab closes the page")

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
	ov.show_pin_prompt(1, "desk-pc", "4F3C C877 7CC3 E350")
	await _frames(2)
	check(ov._pin_code_box.visible and ov._lbl_pin_code.text == "4F3C C877 7CC3 E350"
		and "also shows this code" in ov._lbl_pin_hint.text,
		"the prompt shows the PC's code to compare with the one on the PC")
	await _step("pin_code")
	ov.show_pin_prompt(1, "desk-pc", "E233 763A 57F4 80B9", true)
	await _frames(2)
	check("reinstalled" in ov._lbl_pin_hint.text and ov._lbl_pin_code.text == "E233 763A 57F4 80B9",
		"a PC whose identity changed: the prompt warns")
	await _step("pin_changed")
	ov.show_pin_prompt(1, "desk-pc")
	await _frames(2)
	check(not ov._pin_code_box.visible, "no code, no code line")
	await _click(_btn("Cancel", ov._pin_box))

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
	var slots: Array = ov._monitor_list.find_children("*", "Button", true, false).filter(
		func(b): return b.text == "Remove")
	check(slots.size() == 1 and slots[0].get_global_rect().end.x <= ov._monitor_list.get_global_rect().end.x + 0.5,
		"the virtual screen's buttons fit their row")
	var rows: Array = ov._monitor_list.find_children("*", "CheckButton", true, false).filter(
		func(b): return b.text != "Move together")
	check(rows.size() == 3 and rows[0].button_pressed and not rows[1].button_pressed,
		"monitor switches show what streams")
	await _click(rows[1])
	check(events.back() == ["monitor", 1], "a switch toggles that monitor")
	await _click(ov._btn_arrange)
	check(events.back() == ["arrange"], "Arrange around me")
	check(ov._btn_add_virtual.visible, "a PC that can make virtual screens offers them")
	await _click(_btn("Size", ov._monitor_list))
	check(events.back() == ["vpage", 100], "Size on the virtual screen asks for its page -> %s" % [events.back()])
	await _click(_btn("Remove", ov._monitor_list))
	check(events.back() == ["unvirtual", 100], "Remove on the virtual screen -> %s" % [events.back()])
	await _step("screens")
	await _virtual_page()
	ov.set_host_capabilities(false, false)
	check(not ov._btn_add_virtual.visible, "no virtual screens offered when the PC can't make them")

	await _click(ov._tab_buttons[0])
	check(ov._connected_box.visible and not ov._input_ip.editable, "connected: address locked")
	ov.set_connection_details([["Address", "192.168.1.34:19800"], ["Link", "Network"]])
	await _frames(3)  # the new rows move the switch down
	check(ov._chk_control.button_pressed and not ov._lbl_control_note.visible, "control is on by default")
	await _click(ov._chk_control)
	check(events.back() == ["control", false] and ov._lbl_control_note.visible,
		"the switch turns control off and says what that means -> %s" % [events.back()])
	await _step("connected")
	check(not ov._chk_screen_off.visible, "no screen-off switch when the PC can't do it")
	ov.set_host_capabilities(false, false, true)
	await _frames(3)  # the switch appears and takes its place
	check(ov._chk_screen_off.visible and not ov._chk_screen_off.button_pressed
		and not ov._lbl_screen_off_note.visible, "the PC's main screen starts on")
	await _click(ov._chk_screen_off)
	check(events.back() == ["screen_off", true] and ov._lbl_screen_off_note.visible,
		"the switch turns the main screen off and says when it comes back -> %s" % [events.back()])
	await _step("screen_off")
	ov.set_screen_off(false)  # the host lit it (lease ran out, refused)
	check(not ov._chk_screen_off.button_pressed and not ov._lbl_screen_off_note.visible,
		"the switch follows the host")
	ov.set_host_capabilities(true, false, true)
	check(not ov._chk_screen_off.visible, "a view-only PC: no screen-off switch")
	check(ov._chk_control.disabled and not ov._chk_control.button_pressed, "a view-only PC: control off and locked")
	await _step("viewonly")
	ov.set_host_capabilities(false, false)
	ov.set_input_settings(true, true)

	await _click(ov._tab_buttons[2])
	await _click(_btn("Dusk"))
	check(events.back() == ["look", "dusk"], "Space: pick Dusk")
	await _click(ov._chk_layers)
	check(events.back() == ["layers", true], "Space: sharper-text switch")
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

	ov.set_pointer_settings("right", 40.0, true)
	await _click(ov._tab_buttons[4])
	check(ov._tab == 4 and _btn("Right hand").button_pressed and ov._lbl_ray_value.text == "40°"
		and ov._chk_face_me.button_pressed, "Input: shows what main.gd pushed in")
	await _click(_btn("Left hand"))
	check(events.back() == ["pointer", "left", 40.0, true], "Input: point with the left hand -> %s" % [events.back()])
	var rr: Rect2 = ov._slider_ray.get_global_rect()
	await _click_at((rr.position + Vector2(2.0, rr.size.y / 2.0)) / Vector2(ov._viewport.size))
	check(events.back()[0] == "pointer" and events.back()[2] < 5.0 and ov._lbl_ray_value.text == "%d°" % int(events.back()[2]),
		"Input: the ray angle slider -> %s" % [events.back()])
	await _click(ov._chk_face_me)
	check(events.back()[0] == "pointer" and events.back()[3] == false, "Input: face-me switch")
	await _click(ov._chk_haptics)
	check(events.back() == ["haptics", false], "Input: vibration switch")
	var ind: Panel = ov._tab_indicator
	var tab: Button = ov._tab_buttons[4]
	check(tab.get_global_rect().end.x <= ov._viewport.size.x - 30 and absf(ind.position.x - tab.position.x - 14) < 1.0,
		"the tabs fit the bar and the indicator sits under Input")
	await _step("input")
	await _room()

	await _click(_btn("Close"))
	check(not ov.visible, "Close hides the menu")
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
