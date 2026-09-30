extends SceneTree
## Screens, grabbing and the VR keyboard, headless:
##   - a ray at any point of a flat or curved screen hits it at that point's
##     UV (so the mouse lands under the laser), at the right distance;
##   - grabbing a screen keeps the grabbed point on the ray, the screen
##     upright and facing the head, and push/pull moves it along the ray;
##   - the keyboard types with the pointer; Shift / Ctrl latch for one key only.
##
##   godot --headless --xr-mode off --path client/project \
##       -s "$PWD/client/tests/workspace_test.gd"
##
## Prints one ok/FAIL line per check and "RESULT fails=N".

const FAKE_MAIN := """
extends Node3D
var keys: Array = []
func send_keyboard_input(_m, vk, pressed, mods):
	if pressed:
		keys.append([vk, mods])
"""

var fails := 0
var head: Camera3D

func _initialize() -> void:
	var script := GDScript.new()
	script.source_code = FAKE_MAIN
	script.reload()
	var main := Node3D.new()
	main.set_script(script)
	main.name = "Main"
	root.add_child(main)
	head = Camera3D.new()
	head.position = Vector3(0, 1.6, 0)
	main.add_child(head)
	head.current = true
	_run(main)

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _run(main: Node3D) -> void:
	var panel := MeshInstance3D.new()
	panel.set_script(load("res://scripts/screen_panel.gd"))
	main.add_child(panel)
	await _frames(1)
	panel.set_resolution(1920, 1080)

	# --- Ray hits land where the laser points -------------------------------
	for curve in [0.0, 0.35, 1.0]:
		panel.set_curvature(curve > 0.0, curve)
		panel.place_facing(Vector3(0.3, 1.5, -1.3), head.position)
		var worst := 0.0
		var worst_d := 0.0
		for uv in [Vector2(0.5, 0.5), Vector2(0.02, 0.1), Vector2(0.97, 0.9), Vector2(0.25, 0.75)]:
			var p: Vector3 = panel.to_global(panel.local_point(uv.x, uv.y))
			var hit: Dictionary = panel.ray_to_screen_hit(head.position, (p - head.position).normalized())
			if not hit.get("valid", false):
				worst = INF
				continue
			worst = maxf(worst, (hit.uv - uv).length())
			worst_d = maxf(worst_d, absf(hit.distance - head.position.distance_to(p)))
			var back: Vector2 = panel.world_to_screen_uv(p)
			worst = maxf(worst, (back - uv).length())
		check(worst < 0.002 and worst_d < 0.002,
			"curvature %.2f: ray hits map to the aimed UV (err %.4f, %.4f m)" % [curve, worst, worst_d])
	var miss: Dictionary = panel.ray_to_screen_hit(head.position, Vector3(0, 1, 0))
	check(not miss.get("valid", false), "a ray at the sky misses the screen")

	# --- Grabbing -----------------------------------------------------------
	panel.set_curvature(true, 0.5)
	panel.place_facing(Vector3(0, 1.5, -1.3), head.position)
	var pointer := Node3D.new()
	main.add_child(pointer)
	pointer.global_position = Vector3(0.2, 1.2, -0.3)
	pointer.look_at(panel.global_position + Vector3(0.1, 0.05, 0))
	var hit0: Dictionary = panel.ray_to_screen_hit(pointer.global_position, -pointer.global_basis.z)
	panel.start_drag(pointer, hit0.distance)
	pointer.rotate_y(deg_to_rad(-25.0))
	pointer.rotate_object_local(Vector3.FORWARD, deg_to_rad(30.0))  # a twist of the wrist
	await _frames(2)
	var up_err: float = panel.global_basis.y.angle_to(Vector3.UP)
	var to_head: Vector3 = (head.position - panel.global_position).normalized()
	check(panel.global_basis.x.y < 0.001, "grabbed screen never rolls")
	check(panel.global_basis.z.normalized().dot(to_head) > 0.99, "grabbed screen faces the head")
	var hit1: Dictionary = panel.ray_to_screen_hit(pointer.global_position, -pointer.global_basis.z)
	check(hit1.get("valid", false) and absf(hit1.distance - hit0.distance) < 0.02 \
		and (hit1.uv - hit0.uv).length() < 0.01,
		"the grabbed point stays under the laser -> %s vs %s" % [hit1.get("uv"), hit0.uv])
	panel.push_pull(0.5)
	await _frames(2)
	var hit2: Dictionary = panel.ray_to_screen_hit(pointer.global_position, -pointer.global_basis.z)
	check(hit2.get("valid", false) and absf(hit2.distance - hit0.distance - 0.5) < 0.02,
		"push moves it 0.5 m along the ray")
	panel.stop_drag()
	check(up_err < 0.35, "stays upright (tilt %.2f rad)" % up_err)

	# --- Compositor layer -------------------------------------------------
	var origin := Node3D.new()
	origin.name = "XROrigin3D"
	main.add_child(origin)
	panel.set_curvature(true, 0.5)
	panel.place_facing(Vector3(0.2, 1.5, -1.3), head.position)
	panel.set_compositor_layer(true, origin)
	await _frames(2)
	var layer: Node3D = panel._layer
	check(layer != null and layer.get_class() == "OpenXRCompositionLayerCylinder" and layer.get_parent() == origin,
		"curved screen -> a cylinder layer under the XR origin")
	if layer:
		var r: float = layer.get("radius")
		var surface_centre: Vector3 = layer.global_position - layer.global_basis.z.normalized() * r
		check(absf(r - panel._radius()) < 0.001 and absf(layer.get("central_angle") - panel._arc()) < 0.001
			and absf(layer.get("aspect_ratio") - panel.panel_width / panel.panel_height) < 0.001,
			"layer radius, angle and aspect match the screen")
		check(surface_centre.distance_to(panel.global_position) < 0.001,
			"the layer's arc is centred where the screen is")
		check(panel.layers == 0 and layer.get("enable_hole_punch") and layer.get("sort_order") < 0,
			"the mesh hides; a hole is punched so the menu still draws in front")
		check(panel._layer_viewport.size == Vector2i(1920, 1080)
			and (panel._layer_content as TextureRect).texture == panel.screen_texture,
			"the layer is fed the screen's picture at its size")
		panel.place_facing(Vector3(-0.4, 1.4, -1.1), head.position)
		await _frames(1)
		surface_centre = layer.global_position - layer.global_basis.z.normalized() * r
		check(surface_centre.distance_to(panel.global_position) < 0.001, "the layer follows the screen")
	panel.set_curvature(false, 0.0)
	await _frames(1)
	layer = panel._layer
	check(layer != null and layer.get_class() == "OpenXRCompositionLayerQuad"
		and (layer.get("quad_size") as Vector2).is_equal_approx(Vector2(panel.panel_width, panel.panel_height)),
		"flat screen -> a quad layer of its size")
	panel.set_compositor_layer(false, origin)
	await _frames(1)
	check(panel._layer == null and panel.layers == 1 and origin.get_child_count() == 0,
		"switching layers off gives the mesh back")
	panel.set_compositor_layer(true, origin)
	await _frames(1)
	panel.queue_free()
	await _frames(2)
	check(origin.get_child_count() == 0, "a closed screen takes its layer with it")

	# --- Keyboard -----------------------------------------------------------
	var kb = load("res://scripts/virtual_keyboard.gd").new()
	main.add_child(kb)
	await _frames(1)
	kb.set_shown(true)
	await _frames(2)
	await _type(kb, "Shift")
	await _type(kb, "a")
	await _type(kb, "b")
	await _type(kb, "Ctrl")
	await _type(kb, "c")
	await _type(kb, "v")
	await _type(kb, "Return")
	check(main.keys == [[0x41, 1], [0x42, 0], [0x43, 2], [0x56, 0], [0x0D, 0]],
		"Shift and Ctrl hold for one key only -> %s" % [main.keys])
	var miss_d: float = kb.pointer_ray(head.position, Vector3.UP, false)
	check(miss_d < 0.0, "a ray above the keyboard misses it")
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)

## Press and release the key labelled `label` with a ray from the head.
func _type(kb: Node3D, label: String) -> void:
	var target: Button = null
	for k in kb._keys:
		if k.button.text == label or (k.def[0] == label):
			target = k.button
			break
	var centre: Vector2 = target.get_global_rect().get_center() / Vector2(kb.VIEW_SIZE)
	var local := Vector3((centre.x - 0.5) * kb.WIDTH_M, (0.5 - centre.y) * kb.HEIGHT_M, 0.0)
	var p: Vector3 = kb._quad.to_global(local)
	var dir := (p - head.position).normalized()
	kb.pointer_ray(head.position, dir, false)
	await _frames(1)
	kb.pointer_ray(head.position, dir, true)
	await _frames(1)
	kb.pointer_ray(head.position, dir, false)
	await _frames(1)
