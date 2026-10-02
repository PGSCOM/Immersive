extends SceneTree
## LAN discovery against a running host (started by host/tools/e2e_test.py
## with a PIN): HostDiscovery must list it, with its name, port, three stub
## monitors and the "asks for a PIN" flag.
##
##   godot --headless --xr-mode off --path client/project \
##       -s "$PWD/client/tests/discovery_test.gd"
##
## Prints one ok/FAIL line per check and "RESULT fails=N".

var fails := 0

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _initialize() -> void:
	var d = load("res://scripts/host_discovery.gd").new()
	var port := int(OS.get_environment("IM2_TCP_PORT")) if OS.has_environment("IM2_TCP_PORT") else 19800
	d.port = port
	root.add_child(d)
	d.start()
	var found: Array = []
	var deadline := Time.get_ticks_msec() + 8000
	while found.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
		found = d.get_hosts().filter(func(h): return h.port == port)
	check(not found.is_empty(), "the host answers the broadcast -> %s" % [d.get_hosts()])
	if not found.is_empty():
		var h: Dictionary = found[0]
		check(not h.name.is_empty() and h.monitors == 3, "name and screens -> %s, %d" % [h.name, h.monitors])
		check(h.pin_required, "it says it asks for a PIN")
	d.stop()
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
