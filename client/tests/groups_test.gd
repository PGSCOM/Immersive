extends SceneTree
## Linked screens, snapping, locking and saving the links, headless:
##   - drag_group_for lists the other linked screens only for a linked one;
##   - a screen dragged near any side of another (flat or curved) is offered
##     a frame there (snap_target_for), and released it lands exactly in it,
##     flush, with its neighbour's orientation; far, turned away or occupied
##     sides offer nothing; linked blocks move rigidly and snapping links
##     nothing;
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
	var c := _panel(main, 2, Vector3(-3.5, 1.52, -3.0))
	await process_frame

	check(main.drag_group_for(a).is_empty(), "unlinked screen: no group")
	main._linked = {0: true, 1: true}
	check(main.drag_group_for(a) == [b], "linked screen: the other linked one")
	check(main.drag_group_for(c).is_empty(), "an unlinked screen has no group")
	main._linked = {}

	# Snap: b dropped near each side of a lands exactly where the frame shows.
	for curve in [0.0, 0.5]:
		for pn in [a, b, c]:
			pn.set_curvature(curve > 0.0, curve)
		for side in 4:
			var land: Transform3D = a.landing_beside(side, b.panel_width, b.panel_height, main.SNAP_GAP_M)
			# 12 cm off and turned 10 degrees: well inside the capture zone.
			b.global_transform = Transform3D(land.basis * Basis(Vector3.UP, deg_to_rad(10.0)),
				land.origin + Vector3(0.08, 0.06, 0.05))
			var tgt: Dictionary = main.snap_target_for(b)
			check(tgt.get("panel") == a and tgt.get("side") == side,
				"curve %.1f side %d: the frame is offered on that side" % [curve, side])
			main.on_panel_drag_ended(b)
			check(b.global_transform.is_equal_approx(land), "curve %.1f side %d: released, it lands in the frame" % [curve, side])
		# Flush: the facing edges are a gap apart (curved: along the arc's chord).
		b.global_transform = a.landing_beside(1, b.panel_width, b.panel_height, main.SNAP_GAP_M)
		var edge: float = a.to_global(a.local_point(1.0, 0.5)).distance_to(b.to_global(b.local_point(0.0, 0.5)))
		check(edge > main.SNAP_GAP_M * 0.9 and edge < main.SNAP_GAP_M + 0.002,
			"curve %.1f: snapped screens are flush, %.3f m apart" % [curve, edge])
		check(b.global_basis.y.is_equal_approx(a.global_basis.y), "curve %.1f: same upright as its neighbour" % curve)
	for pn in [a, b, c]:
		pn.set_curvature(false, 0.0)

	# Far from everything, or turned away: no frame, nothing moves.
	b.place_facing(Vector3(1.2, 1.5, -3.5), head)
	var before: Transform3D = b.global_transform
	check(main.snap_target_for(b).is_empty(), "far from the others: no frame")
	main.on_panel_drag_ended(b)
	check(b.global_transform.is_equal_approx(before), "a screen far from the others stays put")
	var near: Transform3D = a.landing_beside(1, b.panel_width, b.panel_height, main.SNAP_GAP_M)
	b.global_transform = Transform3D(near.basis * Basis(Vector3.UP, deg_to_rad(120.0)), near.origin)
	check(main.snap_target_for(b).is_empty(), "turned right away from the neighbour: no frame")

	# A side that is taken is not offered.
	c.global_transform = a.landing_beside(1, c.panel_width, c.panel_height, main.SNAP_GAP_M)
	b.global_transform = Transform3D(near.basis, near.origin + Vector3(0.0, 0.1, 0.1))
	check(main.snap_target_for(b).get("side") != 1 or main.snap_target_for(b).get("panel") != a,
		"a side with a screen already on it is not offered")
	c.place_facing(Vector3(-3.5, 1.52, -3.0), head)

	# Rigid block: b and c linked, b released near a: both move by the same transform.
	main._linked = {1: true, 2: true}
	var land_r: Transform3D = a.landing_beside(1, b.panel_width, b.panel_height, main.SNAP_GAP_M)
	b.global_transform = Transform3D(land_r.basis, land_r.origin + Vector3(0.1, 0.05, 0.0))
	c.place_facing(b.global_position + Vector3(0, 0, -2.5), head)
	var rel_before: Transform3D = b.global_transform.affine_inverse() * c.global_transform
	main.on_panel_drag_ended(b)
	var rel_after: Transform3D = b.global_transform.affine_inverse() * c.global_transform
	check(rel_before.is_equal_approx(rel_after) and b.global_transform.is_equal_approx(land_r),
		"linked block moves rigidly while snapping")
	check(main._linked == {1: true, 2: true}, "snapping does not link or unlink screens")
	main._linked = {}

	# Snap off, lock.
	main.snap_enabled = false
	b.global_transform = Transform3D(near.basis, near.origin + Vector3(0.1, 0.05, 0.0))
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
