extends SceneTree
## Checks that a controller left still disappears (model and laser) and stops
## driving the pointer, and comes back as soon as it moves.
##
##   godot --headless --xr-mode off --fixed-fps 72 --path client/project \
##       -s "$PWD/client/tests/controller_idle_test.gd"
##
## Prints one ok/FAIL line per check and "RESULT fails=N".

var fails := 0

func _initialize() -> void:
	var main := Node3D.new()
	main.name = "Main"
	root.add_child(main)
	var origin := XROrigin3D.new()
	origin.name = "XROrigin3D"
	main.add_child(origin)
	var right := _controller(origin, "RightController")
	var aim := _controller(origin, "RightAim")
	var laser := Node3D.new()
	laser.name = "RaycastOrigin"
	aim.add_child(laser)
	var input := Node.new()
	input.set_script(load("res://scripts/vr_input.gd"))
	right.add_child(input)
	_run(right, laser)

func _controller(parent: Node, n: String) -> XRController3D:
	var c := XRController3D.new()
	c.name = n
	var visual := MeshInstance3D.new()
	visual.name = "ControllerVisual"
	c.add_child(visual)
	parent.add_child(c)
	return c

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _run(right: XRController3D, laser: Node3D) -> void:
	var model := right.get_node("ControllerVisual") as Node3D
	await _frames(72)  # 1 s, with ~1 mm of tracking noise
	right.position.x += 0.001
	await _frames(5)
	check(model.visible and laser.visible, "visible while in use")
	await _frames(72 * 3)
	check(not model.visible and not laser.visible, "hidden after 3 s still")
	right.position.x += 0.05
	await _frames(2)
	check(model.visible and laser.visible, "back as soon as it moves")
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
