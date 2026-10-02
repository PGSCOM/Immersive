extends SceneTree
## The real client scene streaming from a host, driven by a scripted pointer
## through the same calls the controllers use (main.gd::pick(), LaserDrag
## grab/drop): move a screen, pull it closer, resize it by a corner, snap
## another one above it, open the menu and move it. Meant to be recorded:
##
##   ./host/build/immersive2_host --stub --no-ui --no-usb --no-audio --pin 246810 &
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
##       --xr-mode off --audio-driver Dummy --resolution 1280x720 \
##       --path client/project --write-movie /tmp/demo.avi --fixed-fps 30 \
##       -s "$PWD/client/tests/demo_video_test.gd" -- --im2-host=127.0.0.1 --im2-monitors=0,1,2
##
## Prints one ok/FAIL line per check and "RESULT fails=N"; the exit code is N.

var fails := 0
var main: Node3D
var cam: Camera3D
var pointer: Node3D
var beam: MeshInstance3D

func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	cam = main.get_node("XROrigin3D/XRCamera3D")
	cam.fov = 55.0
	_build_pointer()
	_run()

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _frames(n: int) -> void:
	for i in n:
		await process_frame

## A right hand below and in front of the eyes, with a white laser along -Z.
func _build_pointer() -> void:
	pointer = Node3D.new()
	root.add_child(pointer)
	beam = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.006, 0.006, 1.0)
	beam.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.93, 0.92, 0.88)
	beam.material_override = mat
	pointer.add_child(beam)

func _hand() -> Vector3:
	return cam.global_position + cam.global_basis * Vector3(0.18, -0.3, -0.25)

## Every frame: the laser ends where it hits, and what it is on lights up.
func _update_beam() -> void:
	var hit: Dictionary = main.pick(pointer.global_position, -pointer.global_basis.z)
	var length: float = hit.get("distance", 3.0)
	beam.scale = Vector3(1, 1, length)
	beam.position = Vector3(0, 0, -length / 2.0)
	if hit.has("bar"):
		hit.bar.mark_hovered()

## Turn the pointer from where it aims now to aim at `at`, over `n` frames.
func _sweep_to(at: Vector3, n: int) -> void:
	pointer.global_position = _hand()
	var from := pointer.global_basis.get_rotation_quaternion()
	var to := Basis.looking_at(at - pointer.global_position).get_rotation_quaternion()
	for i in n:
		var t := smoothstep(0.0, 1.0, float(i + 1) / n)
		pointer.global_basis = Basis(from.slerp(to, t))
		_update_beam()
		await process_frame

## Aim at `at`, then grab what pick() returns there (a bar or a handle).
func _grab_at(at: Vector3) -> Node:
	await _sweep_to(at, 25)
	await _frames(8)
	var hit: Dictionary = main.pick(pointer.global_position, -pointer.global_basis.z)
	if hit.get("kind") != "bar" or not LaserDrag.grab(hit.target, pointer, hit.distance, main):
		return null
	return hit.target

func _drop(thing: Node) -> void:
	LaserDrag.drop(thing, main)

## Rotate the held pointer about its origin so a point it holds at `from`
## swings towards `to` (the held thing turns along, like a real wrist).
func _swing(from: Vector3, to: Vector3, n: int) -> void:
	var o := pointer.global_position
	var r := Quaternion((from - o).normalized(), (to - o).normalized())
	var q0 := pointer.global_basis.get_rotation_quaternion()
	for i in n:
		var t := smoothstep(0.0, 1.0, float(i + 1) / n)
		pointer.global_basis = Basis(Quaternion.IDENTITY.slerp(r, t) * q0)
		_update_beam()
		await process_frame

func _run() -> void:
	pointer.global_position = _hand()
	pointer.global_basis = Basis.looking_at(-cam.global_basis.z)
	var panels: Array = []
	for i in 30 * 30:
		_update_beam()
		panels = main._live_panels().filter(func(p): return p.is_active)
		if panels.size() == 3:
			break
		await process_frame
	check(panels.size() == 3, "three screens streaming")
	if panels.size() != 3:
		_finish()
		return
	# Step back once the screens are placed, so the whole scene fits the video.
	main.get_node("XROrigin3D").position += Vector3(0, 0.25, 1.4)
	panels.sort_custom(func(a, b): return int(a.get_meta("monitor_id")) < int(b.get_meta("monitor_id")))
	var centre: Node3D = panels[1]
	var right: Node3D = panels[2]
	await _frames(30)

	# --- Move the middle screen up and to the left by its bar ---------------
	var bar_at: Vector3 = centre.grab_bar.global_position
	var grabbed := await _grab_at(bar_at)
	check(grabbed == centre, "the bar grabs its screen")
	var start: Vector3 = centre.global_position
	await _swing(bar_at, bar_at + cam.global_basis * Vector3(-0.3, 0.2, 0), 45)
	await _frames(10)
	check(centre.global_position.distance_to(start) > 0.25, "the screen follows the pointer")
	# Pull it closer, then push it back a little.
	var d0: float = cam.global_position.distance_to(centre.global_position)
	for i in 30:
		centre.push_pull(-0.01)
		_update_beam()
		await process_frame
	for i in 15:
		centre.push_pull(0.01)
		_update_beam()
		await process_frame
	await _frames(10)
	check(cam.global_position.distance_to(centre.global_position) < d0 - 0.08, "push/pull moves it along the ray")
	_drop(centre)
	await _frames(15)

	# --- Resize it by its bottom-right corner --------------------------------
	var w0: float = centre.panel_width
	var corner: Node3D = centre.resize_handles.filter(func(h): return h.corner == Vector2(1, -1))[0]
	var corner_at: Vector3 = corner.to_global(Vector3(1, -1, 0) * ResizeHandle.ZONE_OUT_M)
	grabbed = await _grab_at(corner_at)
	check(grabbed == corner, "the corner handle is picked")
	await _swing(corner_at, corner_at + centre.global_basis * Vector3(0.45, -0.25, 0), 45)
	await _frames(10)
	check(centre.panel_width > w0 + 0.2, "dragging the corner makes it bigger")
	var w1: float = centre.panel_width
	await _swing(pointer.global_position - pointer.global_basis.z, \
		pointer.global_position - pointer.global_basis.z + centre.global_basis * Vector3(-0.2, 0.1, 0), 30)
	await _frames(10)
	check(centre.panel_width < w1, "and back smaller")
	_drop(corner)
	await _frames(15)

	# --- Snap the right screen above the middle one ---------------------------
	var land: Transform3D = centre.landing_beside(load("res://scripts/screen_panel.gd").Side.TOP, right.panel_width,
		right.panel_height, main.SNAP_GAP_M)
	var rbar: Vector3 = right.grab_bar.global_position
	grabbed = await _grab_at(rbar)
	check(grabbed == right, "the right screen is grabbed")
	var o: Vector3 = pointer.global_position
	var reach: float = o.distance_to(land.origin) - o.distance_to(right.global_position)
	await _swing(right.global_position, land.origin, 50)
	for i in 20:
		right.push_pull(reach / 20.0)
		_update_beam()
		await process_frame
	await _frames(15)
	check(not main.snap_target_for(right).is_empty(), "the snap frame shows above the middle screen")
	_drop(right)
	await _frames(5)
	check(right.global_position.distance_to(land.origin) < 0.05, "releasing lands it in the frame")
	await _frames(20)

	# --- Open the menu and move it --------------------------------------------
	main.toggle_ui_overlay()
	await _frames(20)
	var ui: Node3D = main.ui_overlay
	check(ui.visible, "the menu opens")
	var ui_bar: Vector3 = ui.grab_bar.global_position
	var ui_start: Vector3 = ui.global_position
	grabbed = await _grab_at(ui_bar)
	check(grabbed == ui, "the menu bar grabs the menu")
	await _swing(ui_bar, ui_bar + cam.global_basis * Vector3(0.3, -0.1, 0), 40)
	await _frames(10)
	check(ui.global_position.distance_to(ui_start) > 0.15, "the menu follows the pointer")
	_drop(ui)
	await _sweep_to(cam.global_position - cam.global_basis.z * 2.0, 25)
	await _frames(30)
	_finish()

func _finish() -> void:
	print("RESULT fails=%d" % fails)
	quit(fails)
