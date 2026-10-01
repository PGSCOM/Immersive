extends SceneTree
## Linked screens, snapping, locking and saving the links, headless:
##   - drag_group_for lists the other linked screens only for a linked one;
##   - releasing a screen next to a neighbour snaps it flush beside it,
##     same distance, facing the head; linked blocks move rigidly;
##   - a locked layout refuses moves; snap off leaves the screen alone;
##   - link flags survive a save and a load of the workspace file.
##
##   godot --headless --xr-mode off --path client/project \
##       -s "$PWD/client/tests/groups_test.gd"
##
## Prints one ok/FAIL line per check and "RESULT fails=N".

var fails := 0

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _initialize() -> void:
	_run()

func _panel(main: Node, mid: int, pos: Vector3) -> Node3D:
	var p := MeshInstance3D.new()
	p.set_script(load("res://scripts/screen_panel.gd"))
	root.add_child(p)
	p.set_meta("monitor_id", mid)
	p.set_resolution(1920, 1080)
	p.place_facing(pos, Vector3(0, 1.6, 0))
	main.screen_panels.append(p)
	return p

func _run() -> void:
	# main.gd is not added to the tree: _ready (XR, network) never runs and
	# _head() falls back to a head at (0, 1.6, 0) looking down -Z.
	var main: Node3D = load("res://scripts/main.gd").new()
	main._ephemeral = true
	await process_frame
	var head := Vector3(0, 1.6, 0)
	var a := _panel(main, 0, Vector3(0, 1.52, -1.25))
	var b := _panel(main, 1, Vector3(1.9, 1.52, -1.25))
	var c := _panel(main, 2, Vector3(-1.9, 1.52, -1.25))
	await process_frame

	check(main.drag_group_for(a).is_empty(), "unlinked screen: no group")
	main._linked = {0: true, 1: true}
	check(main.drag_group_for(a) == [b], "linked screen: the other linked one")
	check(main.drag_group_for(c).is_empty(), "an unlinked screen has no group")
	main._linked = {}

	# Snap: drop b a hand-width away from a's right edge.
	var want: float = a.panel_width / 2.0 + main.ARC_GAP_M + b.panel_width / 2.0
	var dist := Vector2(a.global_position.x - head.x, a.global_position.z - head.z).length()
	var drop := Vector3(sin(want / dist + 0.06) * dist, 1.55, -cos(want / dist + 0.06) * dist) + Vector3(0, 0.05, 0)
	b.place_facing(Vector3(drop.x, 1.55, drop.z - 0.3 * 0), head)
	main.on_panel_drag_ended(b)
	var gap: float = absf(Vector3(b.global_position.x - head.x, 0, b.global_position.z - head.z).signed_angle_to(
		Vector3(a.global_position.x - head.x, 0, a.global_position.z - head.z), Vector3.UP)) * dist
	check(absf(gap - want) < 0.005, "released screen snaps flush beside its neighbour (%.3f vs %.3f)" % [gap, want])
	check(absf(b.global_position.y - a.global_position.y) < 0.001, "same height")
	var dist_b := Vector2(b.global_position.x - head.x, b.global_position.z - head.z).length()
	check(absf(dist_b - dist) < 0.005, "same distance from the head")
	check(b.global_basis.z.normalized().dot((head - b.global_position).normalized()) > 0.99, "facing the head")
	check(b.global_position.x > a.global_position.x, "stays on its own side")

	# Far from everything: untouched.
	b.place_facing(Vector3(1.2, 1.5, -3.5), head)
	var before := b.global_transform
	main.on_panel_drag_ended(b)
	check(b.global_transform.is_equal_approx(before), "a screen far from the others stays put")

	# Rigid block: b and c linked, released near a: both move by the same transform.
	main._linked = {1: true, 2: true}
	b.place_facing(Vector3(drop.x, 1.55, drop.z), head)
	c.place_facing(b.global_position + Vector3(0, 0, -2.5), head)
	var rel_before: Transform3D = b.global_transform.affine_inverse() * c.global_transform
	main.on_panel_drag_ended(b)
	var rel_after: Transform3D = b.global_transform.affine_inverse() * c.global_transform
	check(rel_before.is_equal_approx(rel_after) and absf(b.global_position.distance_to(drop)) > 0.001,
		"linked block moves rigidly while snapping")
	main._linked = {}

	# Snap off, lock.
	main.snap_enabled = false
	b.place_facing(Vector3(drop.x, 1.55, drop.z), head)
	before = b.global_transform
	main.on_panel_drag_ended(b)
	check(b.global_transform.is_equal_approx(before), "snap off: nothing moves")
	check(main.can_move_panel(b), "unlocked: screens move")
	main.lock_layout = true
	check(not main.can_move_panel(b), "locked: screens refuse to move")

	# Link flags round-trip through the workspace file (the user's own is kept).
	var path: String = main.WORKSPACE_PATH
	var backup := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	main._ephemeral = false
	main._linked = {0: true, 2: true, 1: false}
	main.save_workspace_layout()
	main._linked = {}
	main._load_workspace()
	check(main._linked == {0: true, 2: true}, "link flags survive save and load -> %s" % [main._linked])
	var v2 := FileAccess.open(path, FileAccess.WRITE)
	v2.store_string('{"version": 2, "monitor_ids": [0], "panels": {"0": {}}}')
	v2.close()
	main._load_workspace()
	check(main._linked.is_empty() and main._workspace_monitor_ids == [0], "version 2 files still load")
	if backup.is_empty():
		DirAccess.remove_absolute(path)
	else:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(backup)
		f.close()
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
