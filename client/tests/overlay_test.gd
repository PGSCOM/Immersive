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

const CONFIG := "user://immersive2_config.cfg"

var ov
var out := ""
var fails := 0
var connects: Array = []
var saved_config = null  # the test clicks Connect, which saves the IP

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	if FileAccess.file_exists(CONFIG):
		saved_config = FileAccess.get_file_as_string(CONFIG)
	root.add_child(Camera3D.new())
	ov = load("res://scripts/ui_overlay.gd").new()
	root.add_child(ov)
	ov.connect_requested.connect(func(ip, _t, _u): connects.append(ip))
	_run()

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _click(ctrl: Control) -> void:
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

func _key(text: String) -> Button:
	for n in ov._viewport.find_children("*", "Button", true, false):
		if n.text.strip_edges() == text and n.is_visible_in_tree():
			return n
	return null

func _type(s: String) -> void:
	for ch in s:
		await _click(_key(ch))

## Layout check (nothing pushed past the fixed-size panel) plus optional PNG.
func _step(name: String) -> void:
	await _frames(4)
	var need: float = ov._canvas.get_child(0).get_combined_minimum_size().y
	check(need <= ov._viewport.size.y,
		"%s: menu fits the panel (%d of %d px)" % [name, need, ov._viewport.size.y])
	if out != "":
		await RenderingServer.frame_post_draw
		ov._viewport.get_texture().get_image().save_png("%s_%s.png" % [out, name])

func _focus() -> Control:
	return ov._viewport.gui_get_focus_owner()

func _run() -> void:
	await _frames(2)
	ov.toggle_visibility()
	await _step("closed")
	check(not ov._input_ip.virtual_keyboard_enabled, "IP field never raises the system keyboard")

	await _click(ov._input_ip)
	check(ov._kbd_container.visible, "tapping the IP field opens the keypad")
	check(_focus() == ov._input_ip, "IP field focused")

	await _click(_key("✕  Clear"))
	await _type("192.168.33.181")
	check(ov._input_ip.text == "192.168.33.181", "typing -> '%s'" % ov._input_ip.text)
	check(_focus() == ov._input_ip, "IP field keeps focus while typing")
	await _step("typing")

	ov._input_ip.caret_column = 3
	await _click(_key("⌫  Back"))
	check(ov._input_ip.text == "19.168.33.181", "backspace at the caret -> '%s'" % ov._input_ip.text)
	await _type("2")
	check(ov._input_ip.text == "192.168.33.181", "digit at the caret -> '%s'" % ov._input_ip.text)

	await _click(_key("✕  Clear"))
	await _type("1.2")
	await _click(ov._btn_connect)
	check(connects.is_empty(), "invalid IP does not connect")
	check(ov._lbl_ip_error.visible, "invalid IP shows an error")
	check(ov._kbd_container.visible, "keypad stays open to fix it")
	await _step("invalid")
	await _type("5")
	check(not ov._lbl_ip_error.visible, "typing clears the error")

	await _click(_key("✓  Done"))
	check(not ov._kbd_container.visible, "Done closes the keypad")
	check(_focus() != ov._input_ip, "Done releases the field")
	await _click(ov._input_ip)
	check(ov._kbd_container.visible, "tapping again reopens it")

	await _click(_key("✕  Clear"))
	await _type("10.0.0.7")
	await _click(ov._btn_connect)
	check(connects == ["10.0.0.7"], "valid IP connects -> %s" % [connects])
	check(not ov._kbd_container.visible, "keypad closes on connect")

	ov.set_state(ov.ConnectionState.STREAMING)
	ov.set_monitor_list([
		{"id": 0, "name": "Monitor A", "width": 3840, "height": 2160, "refresh_rate": 60},
		{"id": 1, "name": "Monitor B", "width": 2560, "height": 1440, "refresh_rate": 144},
		{"id": 2, "name": "Monitor C", "width": 1920, "height": 1080, "refresh_rate": 60}])
	ov.set_active_monitors([0, 2])
	check(not ov._input_ip.editable, "IP read-only while connected")
	await _click(ov._input_ip)  # used to crash (focus released inside focus_entered)
	check(not ov._kbd_container.visible, "no keypad while connected")
	check(ov._mon_hdr.visible, "monitor controls shown while connected")
	await _step("streaming")

	ov.set_state(ov.ConnectionState.DISCONNECTED)
	check(not ov._mon_hdr.visible, "monitor controls hidden when disconnected")

	if saved_config == null:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CONFIG))
	else:
		FileAccess.open(CONFIG, FileAccess.WRITE).store_string(saved_config)
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
