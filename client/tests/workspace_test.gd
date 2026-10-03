extends SceneTree
## Screens, grabbing and the VR keyboard, headless:
##   - a ray at any point of a flat or curved screen hits it at that point's
##     UV (so the mouse lands under the laser), at the right distance;
##   - grabbing a screen locks it to the pointer (position and rotation, roll
##     included; near-level roll/pitch eases flat), push/pull and reaching
##     out move it along the ray, its group follows rigidly; with "face me" on
##     the grabbed point stays on the ray and the screen stays upright, facing
##     the head;
##   - a corner handle outside each screen corner is picked as a "bar", and
##     dragging it resizes the screen (aspect kept, opposite corner fixed,
##     size clamped) without stealing the desktop's own corner pixels;
##   - main.gd::pick() returns the NEAREST of menu, keyboard, screens and the
##     grab bars under them;
##   - the keyboard types with the pointer; Shift / Ctrl latch for one key only;
##     two index fingertips type on it in turn, and the ray waits meanwhile.
##
##   godot --headless --xr-mode off --fixed-fps 72 --path client/project \
##       -s "$PWD/client/tests/workspace_test.gd"
##
## Prints one ok/FAIL line per check and "RESULT fails=N".

const FAKE_MAIN := """
extends Node3D
var keys: Array = []
var group: Array = []
func drag_group_for(_p) -> Array: return group
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

	# --- Grabbing (face-me mode) --------------------------------------------
	LaserDrag.face_me = true
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
	await _frames(40)  # the drag is smoothed: let it settle
	var up_err: float = panel.global_basis.y.angle_to(Vector3.UP)
	var to_head: Vector3 = (head.position - panel.global_position).normalized()
	check(panel.global_basis.x.y < 0.001, "grabbed screen never rolls")
	check(panel.global_basis.z.normalized().dot(to_head) > 0.99, "grabbed screen faces the head")
	var hit1: Dictionary = panel.ray_to_screen_hit(pointer.global_position, -pointer.global_basis.z)
	check(hit1.get("valid", false) and absf(hit1.distance - hit0.distance) < 0.02 \
		and (hit1.uv - hit0.uv).length() < 0.01,
		"the grabbed point stays under the laser -> %s vs %s" % [hit1.get("uv"), hit0.uv])
	panel.push_pull(0.5)
	await _frames(40)
	var hit2: Dictionary = panel.ray_to_screen_hit(pointer.global_position, -pointer.global_basis.z)
	check(hit2.get("valid", false) and absf(hit2.distance - hit0.distance - 0.5) < 0.02,
		"push moves it 0.5 m along the ray")
	# Reaching 10 cm out from the (estimated right) shoulder pushes 3.5x that.
	var d_before: float = panel.get_drag_distance()
	var shoulder := head.position + Vector3(0.17, -0.18, 0.0)
	pointer.global_position += (pointer.global_position - shoulder).normalized() * 0.1
	await _frames(40)
	var hit3: Dictionary = panel.ray_to_screen_hit(pointer.global_position, -pointer.global_basis.z)
	check(absf(panel.get_drag_distance() - d_before - 0.35) < 0.02 and hit3.get("valid", false)
		and absf(hit3.distance - panel.get_drag_distance()) < 0.03,
		"reaching 10 cm out pushes it 0.35 m (%.2f -> %.2f m)" % [d_before, panel.get_drag_distance()])
	panel.stop_drag()
	check(up_err < 0.35, "stays upright (tilt %.2f rad)" % up_err)

	# --- Rigid: locked to the pointer, group follows ------------------------
	LaserDrag.face_me = false
	var other := MeshInstance3D.new()
	other.set_script(load("res://scripts/screen_panel.gd"))
	main.add_child(other)
	await _frames(1)
	other.set_resolution(1920, 1080)
	panel.place_facing(Vector3(0, 1.5, -1.3), head.position)
	other.place_facing(Vector3(1.6, 1.4, -0.9), head.position)
	var rel: Transform3D = panel.global_transform.affine_inverse() * other.global_transform
	main.group = [other]
	pointer.global_position = Vector3(0.2, 1.2, -0.3)
	pointer.look_at(panel.global_position)
	var held: Transform3D = pointer.global_transform.affine_inverse() * panel.global_transform
	var d_start: float = pointer.global_position.distance_to(panel.global_position)
	panel.start_drag(pointer, d_start)
	# Swing it up and sideways and roll the wrist well past the level assist.
	pointer.global_position += Vector3(0.3, 0.2, -0.1)
	pointer.rotate_y(deg_to_rad(35.0))
	pointer.rotate_object_local(Vector3.RIGHT, deg_to_rad(25.0))
	pointer.rotate_object_local(Vector3.FORWARD, deg_to_rad(30.0))
	await _frames(40)
	var held_now: Transform3D = pointer.global_transform.affine_inverse() * panel.global_transform
	# (moving the hand away from the shoulder also pushed it along the ray)
	held.origin.z -= panel.get_drag_distance() - d_start
	check(held_now.origin.distance_to(held.origin) < 0.002 and held_now.basis.get_rotation_quaternion().angle_to(held.basis.get_rotation_quaternion()) < 0.01,
		"locked to the pointer: same place and rotation relative to it, roll too")
	check(absf(panel.global_basis.x.y) > 0.1, "it rolled with the wrist")
	var rel_now: Transform3D = panel.global_transform.affine_inverse() * other.global_transform
	check(rel_now.origin.distance_to(rel.origin) < 0.001 and rel_now.basis.is_equal_approx(rel.basis),
		"the rest of the group follows rigidly")
	var d_rigid: float = panel.get_drag_distance()
	var at_before: float = panel.global_position.distance_to(pointer.global_position)
	panel.push_pull(0.4)
	await _frames(40)
	check(absf(panel.global_position.distance_to(pointer.global_position) - at_before - 0.4) < 0.01
		and absf(panel.get_drag_distance() - d_rigid - 0.4) < 0.001,
		"push moves a locked screen 0.4 m along the ray")
	panel.stop_drag()
	main.group = []
	other.queue_free()

	# Near-level roll and pitch ease flat; a real tilt is left alone.
	var tilt := Basis(Vector3.UP, 0.7) * Basis(Vector3.FORWARD, deg_to_rad(2.0)) * Basis(Vector3.RIGHT, deg_to_rad(-2.5))
	var flat := LaserDrag.level_basis(tilt)
	check(absf(flat.x.y) < 0.0001 and absf(flat.z.y) < 0.0001 and flat.is_equal_approx(flat.orthonormalized()),
		"2 degrees of roll and pitch ease flat")
	var real_tilt := Basis(Vector3.UP, 0.7) * Basis(Vector3.FORWARD, deg_to_rad(15.0)) * Basis(Vector3.RIGHT, deg_to_rad(-12.0))
	check(LaserDrag.level_basis(real_tilt).is_equal_approx(real_tilt), "a 15 degree tilt is kept")

	# --- Picking: nearest wins, grab bars included --------------------------
	var ov = load("res://scripts/ui_overlay.gd").new()
	main.add_child(ov)
	var picker = load("res://scripts/main.gd").new()  # not in the tree: just its pick()
	picker.screen_panels = [panel]
	picker.ui_overlay = ov
	await _frames(1)
	ov.set_shown(true)
	panel.set_curvature(true, 0.5)
	panel.place_facing(Vector3(0, 1.5, -1.3), head.position)
	ov.global_transform = Transform3D(LaserDrag.facing_basis(Vector3(0, 1.5, -2.0), head.position), Vector3(0, 1.5, -2.0))
	var at_centre := (panel.global_position - head.position).normalized()
	check(picker.pick(head.position, at_centre).get("kind") == "panel",
		"a menu behind a screen does not steal the pointer")
	ov.global_transform = Transform3D(LaserDrag.facing_basis(Vector3(0, 1.5, -0.8), head.position), Vector3(0, 1.5, -0.8))
	check(picker.pick(head.position, at_centre).get("kind") == "overlay", "a menu in front of it does")
	ov.set_shown(false)
	var bar_at: Vector3 = panel.grab_bar.global_position + Vector3(0.12, 0.025, 0.0)
	var bar_hit: Dictionary = picker.pick(head.position, (bar_at - head.position).normalized())
	check(bar_hit.get("kind") == "bar" and bar_hit.get("target") == panel
		and absf(bar_hit.distance - head.position.distance_to(bar_at)) < 0.01,
		"the hit zone around the bar under a screen picks the bar -> %s" % [bar_hit.get("kind")])
	var just_above: Vector3 = panel.to_global(panel.local_point(0.5, 0.98))
	check(picker.pick(head.position, (just_above - head.position).normalized()).get("kind") == "panel",
		"just above the bottom edge is still the screen")
	var below_bar: Vector3 = panel.grab_bar.global_position + Vector3(0.0, -0.06, 0.0)
	check(picker.pick(head.position, (below_bar - head.position).normalized()).is_empty(),
		"below the bar's zone is nothing")
	ov.set_shown(true)
	var ov_bar: Dictionary = picker.pick(head.position, (ov.grab_bar.global_position - head.position).normalized())
	check(ov_bar.get("kind") == "bar" and ov_bar.get("target") == ov, "the menu has a grab bar too")
	ov.set_shown(false)
	picker.free()

	# --- Corner handles ------------------------------------------------------
	var picker2 = load("res://scripts/main.gd").new()
	picker2.screen_panels = [panel]
	for curve in [0.0, 0.5]:
		panel.set_curvature(curve > 0.0, curve)
		panel.set_panel_width(1.6)
		panel.place_facing(Vector3(0.2, 1.5, -1.3), head.position)
		await _frames(2)
		var t0: Transform3D = panel.global_transform
		var w0: float = panel.panel_width
		var h0: float = panel.panel_height
		var corner_w: Vector3 = panel.to_global(panel.local_point(1.0, 0.0))
		var anchor_w: Vector3 = panel.to_global(panel.local_point(0.0, 1.0))
		var handle: ResizeHandle = panel.resize_handles[1]
		var outside: Vector3 = corner_w + t0.basis * Vector3(0.05, 0.05, 0.0)
		var pk: Dictionary = picker2.pick(head.position, (outside - head.position).normalized())
		check(pk.get("kind") == "bar" and pk.get("target") == handle and pk.get("bar") == handle,
			"curve %.1f: outside the top-right corner picks its handle -> %s" % [curve, pk.get("kind")])
		var inside: Vector3 = panel.to_global(panel.local_point(0.985, 0.03))
		check(picker2.pick(head.position, (inside - head.position).normalized()).get("kind") == "panel",
			"curve %.1f: the screen's own corner pixels stay the screen's" % curve)
		var far: Vector3 = corner_w + t0.basis * Vector3(0.6, 0.6, 0.0)
		check(picker2.pick(head.position, (far - head.position).normalized()).is_empty(),
			"curve %.1f: far from every corner is nothing" % curve)
		await _frames(1)
		check(not panel.resize_handles[2].visible,
			"curve %.1f: a corner the pointer is far from shows no bracket" % curve)
		picker2.pick(head.position, (outside - head.position).normalized())
		await _frames(1)
		check(handle.visible, "curve %.1f: the corner it is near shows its bracket" % curve)
		# Grab it like the input scripts do and drag it out along the diagonal.
		var pointer2 := Node3D.new()
		main.add_child(pointer2)
		pointer2.global_position = head.position
		pointer2.look_at(outside)
		check(LaserDrag.grab(handle, pointer2, pk.distance, main) and handle.is_dragging(), "the handle can be grabbed")
		var ca: Vector3 = panel.local_point(0.0, 1.0)
		var diag: Vector3 = panel.local_point(1.0, 0.0) - ca
		for scale in [1.5, 0.5, 9.0, 0.01]:
			var want_local: Vector3 = ca + diag * scale + Vector3(0.05, 0.05, 0.0)
			want_local.z = panel.local_point(1.0, 0.0).z
			var aim: Vector3 = t0 * want_local
			pointer2.look_at(aim)
			await _frames(40)
			var expect: float = clampf(w0 * scale, panel.MIN_WIDTH, panel.MAX_WIDTH)
			check(absf(panel.panel_width - expect) < 0.02 * expect,
				"curve %.1f: x%.2f -> width %.3f m (wanted %.3f)" % [curve, scale, panel.panel_width, expect])
			check(absf(panel.panel_height / panel.panel_width - h0 / w0) < 0.0001, "aspect ratio kept")
			check(panel.to_global(panel.local_point(0.0, 1.0)).distance_to(anchor_w) < 0.002,
				"the opposite corner stays put")
			check(panel.global_basis.is_equal_approx(t0.basis), "resizing never turns it")
			check(handle.get_drag_distance() > 0.5, "the ray ends at the screen's plane")
		LaserDrag.drop(handle, main)
		check(not handle.is_dragging(), "dropped")
		check(absf(panel.get_layout_state().panel_width - panel.panel_width) < 0.0001, "the size is in the saved layout")
		pointer2.queue_free()
	picker2.free()
	panel.set_curvature(true, 0.5)
	panel.set_panel_width(1.6)
	panel.place_facing(Vector3(0.2, 1.5, -1.3), head.position)

	# The snap frame outlines a screen of the given size, flat or curved.
	var frame := SnapFrame.new()
	main.add_child(frame)
	frame.show_at(Transform3D(Basis(), Vector3(0, 1.5, -2.0)), 1.6, 0.9, 0.0)
	var box: AABB = frame.mesh.get_aabb()
	check(frame.visible and absf(box.size.x - 1.6) < 0.001 and absf(box.size.y - 0.9) < 0.001
		and frame.global_position.is_equal_approx(Vector3(0, 1.5, -2.0)), "snap frame: a white outline of the screen's size")
	frame.show_at(Transform3D.IDENTITY, 1.6, 0.9, 0.875)
	var curved: AABB = frame.mesh.get_aabb()
	check(curved.size.z > 0.05 and curved.size.x < 1.6, "snap frame: follows the arc of a curved screen")
	frame.clear()
	check(not frame.visible, "snap frame: cleared")
	frame.queue_free()

	# --- Compositor layer -------------------------------------------------
	var origin := Node3D.new()
	origin.name = "XROrigin3D"
	main.add_child(origin)
	panel.set_curvature(true, 0.5)
	panel.place_facing(Vector3(0.2, 1.5, -1.3), head.position)
	var mark := ShaderMaterial.new()  # main.gd's stencil mark for the passthrough hands
	panel.material_overlay = mark
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
		var stand_in: MeshInstance3D = panel._layer_mask
		check(stand_in != null and stand_in.layers != 0 and stand_in.mesh == panel.mesh
			and stand_in.material_overlay == mark and stand_in.is_in_group(&"covers_hands")
			and (stand_in.material_override as StandardMaterial3D).albedo_color.a == 0.0,
			"an invisible copy of the hidden mesh still carries the hands' stencil mark")
		panel.scale_panel(0.2)
		await _frames(1)
		check(stand_in.mesh == panel.mesh, "resized, the copy takes the new mesh")
		panel.scale_panel(-0.2)
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
	check(panel._layer == null and panel.layers == 1 and origin.get_child_count() == 0
		and panel.find_children("*", "MeshInstance3D", false, false).all(func(m): return not m.is_in_group(&"covers_hands")),
		"switching layers off gives the mesh back (and drops its invisible copy)")
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
	main.keys.clear()
	await _poke(kb, "x", 0)
	await _poke(kb, "y", 1)
	await _poke(kb, "z", 0)
	check(main.keys == [[0x58, 0], [0x59, 0], [0x5A, 0]],
		"two fingertips type in turn, without lifting away -> %s" % [main.keys])
	kb.pointer_ray(head.position, (_key_point(kb, "q") - head.position).normalized(), true)
	await _frames(1)
	kb.pointer_ray(head.position, (_key_point(kb, "q") - head.position).normalized(), false)
	check(main.keys.size() == 3, "a ray pressing a key while a fingertip hovers types nothing")
	kb.touch(0, _key_point(kb, "q") + kb._quad.global_basis.z * 0.2)
	kb.touch(1, _key_point(kb, "q") + kb._quad.global_basis.z * 0.2)
	var miss_d: float = kb.pointer_ray(head.position, Vector3.UP, false)
	check(miss_d < 0.0, "a ray above the keyboard misses it")
	var kb_bar: float = kb.grab_bar.hit(head.position, (kb.grab_bar.global_position - head.position).normalized())
	check(kb_bar > 0.0 and kb.grab_bar.visible, "the keyboard shows a grab bar under it")
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)

## The centre of the key labelled `label`, in the world.
func _key_point(kb: Node3D, label: String) -> Vector3:
	for k in kb._keys:
		if k.button.text == label or k.def[0] == label:
			var c: Vector2 = k.button.get_global_rect().get_center() / Vector2(kb.VIEW_SIZE)
			return kb._quad.to_global(Vector3((c.x - 0.5) * kb.WIDTH_M, (0.5 - c.y) * kb.HEIGHT_M, 0.0))
	return Vector3.ZERO

## Hand `who` hovers 3 cm over the key, taps it (4 mm) and lifts to 3 cm.
func _poke(kb: Node3D, label: String, who: int) -> void:
	var p := _key_point(kb, label)
	for depth in [0.03, 0.004, 0.03]:
		kb.touch(who, p + kb._quad.global_basis.z * depth)
		await _frames(1)

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
